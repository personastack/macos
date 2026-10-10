package mcp

import (
	"context"
	"encoding/json"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDesktopAgentBridgeHermesToolsetRepairPreservesProfileAndRequiresEffectiveCatalog(t *testing.T) {
	t.Parallel()
	for _, api := range []string{"[terminal, no_mcp, unrelated]", "[]", "\"['terminal', 'no_mcp', 'unrelated']\""} {
		t.Run(api, func(t *testing.T) {
			t.Parallel()
			b, store, path := installedFixture(t)
			raw, _ := os.ReadFile(path)
			raw = append(raw, []byte("platform_toolsets:\n  api_server: "+api+"\n  cli: [no_mcp, file]\n")...)
			if err := os.WriteFile(path, raw, 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := (Installer{Store: store}).InstallBinding(b); err != nil {
				t.Fatal(err)
			}
			before, _ := os.ReadFile(path)
			if strings.Contains(string(before), "- issued") {
				t.Fatal("ordinary install granted toolset consent")
			}
			nativeCalls, directCalls := 0, 0
			catalog := func(ctx context.Context, selected config.Binding, endpoint string) (bool, string) {
				nativeCalls++
				if selected.HermesHome != b.HermesHome || selected.NativeMCPServer != "issued" || endpoint != "http://127.0.0.1:25001" {
					t.Fatal("effective catalog queried another profile")
				}
				doc, err := readConfig(selected.NativeConfigPath)
				if err != nil {
					t.Fatal(err)
				}
				platforms, _ := entryAt(doc.Content[0], "platform_toolsets")
				tools, _ := entryAt(platforms, "api_server")
				allowed := false
				for _, tool := range tools.Content {
					if tool.Value == "no_mcp" {
						return false, "MCP disabled by selected API toolset"
					}
					allowed = allowed || tool.Value == "issued"
				}
				return allowed, "mocked selected effective catalog"
			}
			client := &http.Client{Transport: verifyContractRoundTripper(func(req *http.Request) (*http.Response, error) {
				directCalls++
				if req.Method != http.MethodPost || req.URL.String() != b.PersonaMCPURL || req.Header.Get("Authorization") != "Bearer secret" {
					t.Fatal("wrong direct MCP scope")
				}
				var request struct {
					Method string          `json:"method"`
					ID     json.RawMessage `json:"id"`
				}
				if err := json.NewDecoder(req.Body).Decode(&request); err != nil {
					t.Fatal(err)
				}
				want := []string{"initialize", "notifications/initialized", "tools/list"}
				if directCalls > len(want) || request.Method != want[directCalls-1] {
					t.Fatal("unplanned MCP call")
				}
				status, response := 200, `{"jsonrpc":"2.0","id":`+string(request.ID)+`,"result":{"tools":[]}}`
				if directCalls == 2 {
					status, response = http.StatusAccepted, ""
				}
				return &http.Response{StatusCode: status, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(response)), Request: req}, nil
			})}
			initial := verifyBindingWithNative(context.Background(), "", b, client, "http://127.0.0.1:25001", catalog)
			if initial.State == runtime.AdapterStateMCPVerified || directCalls != 0 || nativeCalls != 1 {
				t.Fatal("native toolset failure was bypassed")
			}
			err := config.UpdateBinding(store, b, func(current *config.Binding) error {
				_, err := ConfigureBinding(current, true)
				return err
			})
			if err != nil {
				t.Fatal(err)
			}
			b, _ = config.BindingFor(store, b)
			after, _ := os.ReadFile(path)
			if !strings.Contains(string(after), "user_key: keep") || !strings.Contains(string(after), "command: user-tool") || !strings.Contains(string(after), "cli: [no_mcp, file]") {
				t.Fatal("repair changed unrelated config or another platform")
			}
			repaired := verifyBindingWithNative(context.Background(), "", b, client, "http://127.0.0.1:25001", catalog)
			if repaired.State != runtime.AdapterStateMCPVerified || directCalls != 3 || nativeCalls != 2 {
				t.Fatalf("repaired effective catalog not verified: %+v", repaired)
			}
		})
	}
}

func TestDesktopAgentBridgeHermesToolsetMalformedRepairPreservesConfig(t *testing.T) {
	t.Parallel()
	for _, fragment := range []string{"platform_toolsets: []", "platform_toolsets: {api_server: terminal}", "platform_toolsets: {api_server: {terminal: true}}", "platform_toolsets: {api_server: [terminal, 123]}"} {
		t.Run(fragment, func(t *testing.T) {
			t.Parallel()
			b, store, path := installedFixture(t)
			raw, _ := os.ReadFile(path)
			raw = append(raw, []byte(fragment+"\n")...)
			if err := os.WriteFile(path, raw, 0600); err != nil {
				t.Fatal(err)
			}
			err := config.UpdateBinding(store, b, func(current *config.Binding) error {
				_, err := ConfigureBinding(current, true)
				return err
			})
			if err == nil || !strings.HasPrefix(err.Error(), "cleanup_required:") {
				t.Fatalf("malformed toolsets replaced: %v", err)
			}
			after, _ := os.ReadFile(path)
			current, _ := config.BindingFor(store, b)
			if string(raw) != string(after) || current.MCPOwnership != b.MCPOwnership {
				t.Fatal("failed repair changed config or ownership")
			}
		})
	}
}

func installedFixture(t *testing.T) (config.Binding, *config.MemoryStore, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte("user_key: keep\nmcp_servers:\n  unrelated:\n    command: user-tool\n"), 0600); err != nil {
		t.Fatal(err)
	}
	b := config.Binding{EnvironmentID: "https://app.example", ConnectionID: "c", RuntimeKind: runtime.AdapterKindHermes, NativeConfigPath: path, HermesHome: filepath.Dir(path), NativeStateRoot: filepath.Dir(path), NativeMCPServer: "issued", NativeMCPNamespace: "mcp_issued", PersonaMCPToken: "secret", PersonaMCPURL: "https://mcp.example/mcp", InventorySeed: "seed"}
	store := config.NewMemoryStore(config.State{Bindings: []config.Binding{b}})
	if _, err := (Installer{Store: &store}).InstallBinding(b); err != nil {
		t.Fatal(err)
	}
	b, _ = config.BindingFor(&store, b)
	return b, &store, path
}
func TestDesktopAgentBridgeMCPOwnership(t *testing.T) {
	t.Parallel()
	b, store, path := installedFixture(t)
	if _, err := (Installer{Store: store}).InstallBinding(b); err != nil {
		t.Fatal(err)
	}
	if err := RemoveOwned(b); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "issued:") || !strings.Contains(string(raw), "unrelated:") || !strings.Contains(string(raw), "user_key: keep") {
		t.Fatalf("unrelated config changed %s", raw)
	}
	if err := RemoveOwned(b); err != nil {
		t.Fatal(err)
	}
}
func TestDesktopAgentBridgeMCPUserEditRefusal(t *testing.T) {
	t.Parallel()
	b, store, path := installedFixture(t)
	raw, _ := os.ReadFile(path)
	raw = []byte(strings.ReplaceAll(string(raw), "Bearer secret", "Bearer user-edit"))
	os.WriteFile(path, raw, 0600)
	before := string(raw)
	if _, err := (Installer{Store: store}).InstallBinding(b); err == nil {
		t.Fatal("user edit replaced")
	}
	if err := RemoveOwned(b); err == nil {
		t.Fatal("user edit deleted")
	}
	after, _ := os.ReadFile(path)
	if string(after) != before {
		t.Fatal("failed ownership mutated config")
	}
}
func TestDesktopAgentBridgeNativeMCPFailureBlocksDirectProbe(t *testing.T) {
	t.Parallel()
	b, _, _ := installedFixture(t)
	calls := 0
	result := verifyBindingWithNative(context.Background(), "", b, &http.Client{Transport: verifyContractRoundTripper(func(r *http.Request) (*http.Response, error) {
		t.Fatal("direct probe bypassed native failure")
		return nil, nil
	})}, "http://127.0.0.1:25001", func(ctx context.Context, received config.Binding, endpoint string) (bool, string) {
		calls++
		if received.NativeMCPServer != "issued" || endpoint != "http://127.0.0.1:25001" {
			t.Fatal("wrong selected native catalog")
		}
		return false, "selected catalog rejected"
	})
	if calls != 1 || result.State == runtime.AdapterStateMCPVerified || result.DiagnosticCode != "native_mcp_unreachable" {
		t.Fatalf("false readiness %+v calls%d", result, calls)
	}
}
func TestDesktopAgentBridgeMCPConfigSymlink(t *testing.T) {
	t.Parallel()
	b, store, path := installedFixture(t)
	alias := filepath.Join(filepath.Dir(path), "alias.yaml")
	os.Symlink(path, alias)
	b.NativeConfigPath = alias
	b.MCPOwnership.ConfigPath = alias
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	if _, err := (Installer{Store: store}).InstallBinding(b); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Lstat(alias)
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("symlink replaced")
	}
	other := filepath.Join(filepath.Dir(path), "other.yaml")
	os.WriteFile(other, []byte("{}"), 0600)
	os.Remove(alias)
	os.Symlink(other, alias)
	if _, err := (Installer{Store: store}).InstallBinding(b); err == nil {
		t.Fatal("changed symlink adopted")
	}
}

func TestDesktopAgentBridgeCapturedLegacyTransfer(t *testing.T) {
	t.Parallel()
	b, store, path := installedFixture(t)
	capture, err := CaptureLegacy(b, "migration", filepath.Join(filepath.Dir(path), "backup"))
	if err != nil {
		t.Fatal(err)
	}
	old, _ := os.ReadFile(path)
	b.Migration = &capture
	b.NativeMCPServer = "new-issued"
	b.NativeMCPNamespace = "mcp_new"
	b.PersonaMCPToken = "new-secret"
	b.MCPOwnership = config.MCPOwnership{}
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	if _, err = (Installer{Store: store}).InstallBinding(b); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "issued:") && !strings.Contains(string(raw), "new-issued:") {
		t.Fatal("new entry absent")
	}
	if strings.Contains(string(raw), "\n    issued:") || !strings.Contains(string(raw), "Bearer new-secret") || !strings.Contains(string(raw), "unrelated:") {
		t.Fatalf("transfer %s", raw)
	}
	backup, _ := os.ReadFile(capture.BackupPath)
	if string(backup) != string(old) {
		t.Fatal("exact backup changed")
	}
	saved, _ := config.BindingFor(store, b)
	if saved.Migration != nil || saved.MCPOwnership.EntryKey != "new-issued" {
		t.Fatal("migration not finalized")
	}
}
func TestDesktopAgentBridgeCapturedLegacyEditRefusal(t *testing.T) {
	t.Parallel()
	b, store, path := installedFixture(t)
	capture, err := CaptureLegacy(b, "migration", filepath.Join(filepath.Dir(path), "backup"))
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	raw = []byte(strings.ReplaceAll(string(raw), "Bearer secret", "Bearer edited"))
	os.WriteFile(path, raw, 0600)
	b.Migration = &capture
	b.NativeMCPServer = "new"
	b.MCPOwnership = config.MCPOwnership{}
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	if _, err = (Installer{Store: store}).InstallBinding(b); err == nil {
		t.Fatal("changed captured entry replaced")
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(raw) {
		t.Fatal("failed transfer changed config")
	}
}

func TestDesktopAgentBridgeMalformedNativeConfigPreserved(t *testing.T) {
	t.Parallel()
	b, store, path := installedFixture(t)
	raw := "mcp_servers:\n  issued: {}\n  issued: {}\n"
	os.WriteFile(path, []byte(raw), 0600)
	if _, err := (Installer{Store: store}).InstallBinding(b); err == nil {
		t.Fatal("duplicate mapping adopted")
	}
	after, _ := os.ReadFile(path)
	if string(after) != raw {
		t.Fatal("malformed config rewritten")
	}
}

func TestDesktopAgentBridgeOwnedCredentialAndKeyRotation(t *testing.T) {
	t.Parallel()
	b, store, path := installedFixture(t)
	b.PersonaMCPToken = "new-authorized-token"
	b.NativeMCPServer = "new-issued"
	b.NativeMCPNamespace = "mcp_new"
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	if _, err := (Installer{Store: store}).InstallBinding(b); err != nil {
		t.Fatal(err)
	}
	doc, err := readConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	entries, err := nativeEntries(doc, b.RuntimeKind, false)
	if err != nil {
		t.Fatal(err)
	}
	old, _ := entryAt(entries, "issued")
	current, _ := entryAt(entries, "new-issued")
	unrelated, _ := entryAt(entries, "unrelated")
	if old != nil || current == nil || unrelated == nil {
		t.Fatal("owned key rotation duplicated old key or removed unrelated entry")
	}
	saved, _ := config.BindingFor(store, b)
	if saved.PersonaMCPToken != "new-authorized-token" || saved.MCPOwnership.EntryKey != "new-issued" || saved.MCPOwnership.Fingerprint != fingerprint(current, b.InventorySeed) {
		t.Fatal("rotation custody/ownership readback incorrect")
	}
}

func TestDesktopAgentBridgeInstallerAdmissionGuardPreservesAssignedWork(t *testing.T) {
	t.Parallel()
	for _, guard := range []string{"active_run", "quiesced", "stale_generation", "stale_profile"} {
		t.Run(guard, func(t *testing.T) {
			t.Parallel()
			b, store, path := installedFixture(t)
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := config.UpdateBinding(store, b, func(latest *config.Binding) error {
				switch guard {
				case "active_run":
					latest.ActiveRunID = "assigned"
				case "quiesced":
					latest.Quiesced = true
				case "stale_generation":
					latest.ConnectionGeneration++
				case "stale_profile":
					latest.NativeConfigPath = path + ".foreign"
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			if _, err := (Installer{Store: store}).InstallBinding(b); err == nil {
				t.Fatal("native install ignored current admission guard")
			}
			after, _ := os.ReadFile(path)
			if string(before) != string(after) {
				t.Fatal("refused install changed native config")
			}
			latest, _ := config.BindingFor(store, b)
			if guard == "active_run" && latest.ActiveRunID != "assigned" {
				t.Fatal("installer changed accepted work")
			}
			if guard == "quiesced" && !latest.Quiesced {
				t.Fatal("installer resumed quiesced binding")
			}
		})
	}
}
