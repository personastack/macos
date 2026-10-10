package daemon

import (
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
	"github.com/personastack/macos/agent-bridge/internal/targetruntime"
)

func TestDesktopAgentBridgeHermesHostConsentAndScope(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"generic consent only", "stopped host consent", "eligible existing host", "ineligible existing host", "scope changes during owner proof"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			b, store, runner := freshSelectedFixture(t)
			b.TargetSelectionRevision = 3
			if err := store.SaveBinding(b); err != nil {
				t.Fatal(err)
			}
			before, _ := os.ReadFile(b.NativeConfigPath)
			runner.MCPHTTPClient = acceptedMCPCredentialClient(t, nil)
			owned := scenario == "eligible existing host"
			probes := 0
			runner.VerifyRuntimeEndpoint = func(_ context.Context, endpoint, root, path, kind string) (bool, error) {
				probes++
				if endpoint != "http://127.0.0.1:8642/p/default" || root != b.HermesHome || path != b.NativeConfigPath || kind != "hermes" {
					t.Fatal("wrong native shared-host proof scope")
				}
				if scenario == "ineligible existing host" {
					return false, targetruntime.ErrHermesHostConflict
				}
				if scenario == "scope changes during owner proof" {
					err := config.UpdateBinding(store, b, func(current *config.Binding) error { current.Quiesced = true; return nil })
					if err != nil {
						t.Fatal(err)
					}
				}
				return owned, nil
			}
			if owned {
				os.WriteFile(filepath.Join(b.HermesHome, ".env"), []byte("API_SERVER_KEY=existing-host-key-123\n"), 0600)
			}
			envBefore, _ := os.ReadFile(filepath.Join(b.HermesHome, ".env"))
			confirmed := scenario == "stopped host consent" || scenario == "scope changes during owner proof"
			err := runner.RepairBinding(context.Background(), b, true, false, confirmed)
			accepted := scenario == "stopped host consent" || owned
			if accepted && err != nil || !accepted && err == nil {
				t.Fatalf("host consent repair %v", err)
			}
			current, _ := config.BindingFor(store, b)
			after, _ := os.ReadFile(b.NativeConfigPath)
			envAfter, _ := os.ReadFile(filepath.Join(b.HermesHome, ".env"))
			if probes != 1 {
				t.Fatal("host ownership not proved exactly once")
			}
			if !accepted {
				if string(before) != string(after) || string(envBefore) != string(envAfter) || current.MCPOwnership.EntryKey != "" || current.RuntimeLaunchAllowed {
					t.Fatal("denied repair changed native config or host authority")
				}
				return
			}
			if current.RuntimeLaunchAllowed != confirmed || current.MCPOwnership.EntryKey != "issued" || current.ReadinessState == runtime.AdapterStateMCPVerified {
				t.Fatal("generic consent granted host startup or catalog readiness")
			}
			if owned && (string(envBefore) != string(envAfter) || strings.Contains(string(after), "enabled: true")) {
				t.Fatal("eligible attach changed shared-host API config")
			}
		})
	}
}

func TestDesktopAgentBridgeHermesStoppedCheckDoesNotGrantHostConsent(t *testing.T) {
	t.Parallel()
	b, store, runner := freshSelectedFixture(t)
	b.TargetSelectionRevision = 3
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(b.NativeConfigPath)
	runner.MCPHTTPClient = acceptedMCPCredentialClient(t, nil)
	detection, err := runner.CheckBinding(context.Background(), b)
	if err != nil || detection.DiagnosticCode != "hermes_host_consent_required" {
		t.Fatalf("stopped host check %+v %v", detection, err)
	}
	current, _ := config.BindingFor(store, b)
	after, _ := os.ReadFile(b.NativeConfigPath)
	if string(before) != string(after) || current.RuntimeLaunchAllowed || current.MCPOwnership.EntryKey != "" {
		t.Fatal("normal Check changed host/profile state")
	}
	if _, err := os.Stat(filepath.Join(b.HermesHome, ".env")); !os.IsNotExist(err) {
		t.Fatal("Check configured API environment")
	}
}

func TestDesktopAgentBridgeHermesCatalogFailureCannotBeReady(t *testing.T) {
	t.Parallel()
	check := runtime.VerifyHermesMCPServerLoadedWithHome(context.Background(), "issued", t.TempDir())
	if check.OK || !strings.Contains(check.Note, "supported live MCP catalog") {
		t.Fatal("configured server name became live catalog proof")
	}
}

func TestDesktopAgentBridgeHermesTwoNamedProfilesShareHostAndKeepKeys(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	host := filepath.Join(home, ".hermes")
	for _, name := range []string{"default", "writer", "reader"} {
		root := host
		if name != "default" {
			root = filepath.Join(host, "profiles", name)
		}
		if err := os.MkdirAll(root, 0700); err != nil {
			t.Fatal(err)
		}
		doc := "mcp_servers: {}\n"
		if name == "default" {
			doc += "platforms:\n  api_server:\n    port: 8643\n    extra:\n      key: shared-host-key-123\n"
		}
		if err := os.WriteFile(filepath.Join(root, "config.yaml"), []byte(doc), 0600); err != nil {
			t.Fatal(err)
		}
		if name != "default" {
			if err := os.WriteFile(filepath.Join(root, ".env"), []byte("API_SERVER_KEY="+name+"-profile-key-123\nAPI_SERVER_PORT=9999\n"), 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	profiles, warnings := targetinventory.DiscoverAt(home, "fixture", os.Geteuid(), os.Getegid(), runtime.AdapterKindHermes, "seed")
	if len(profiles) != 3 || len(warnings) != 0 {
		t.Fatalf("profile discovery %v %v", profiles, warnings)
	}
	store := config.NewMemoryStore(config.State{})
	runner := Runner{Store: &store, ResolveTarget: func(b config.Binding, target *externalagentprotocol.RuntimeTarget) (targetinventory.ResolvedTarget, error) {
		return targetinventory.ResolveProfiles(b.RuntimeKind, target, profiles, "")
	}}
	hostBefore, _ := os.ReadFile(filepath.Join(host, "config.yaml"))
	for _, profile := range profiles {
		name := profile.Resolved.ProfileName
		if name == "default" {
			continue
		}
		b := config.Binding{EnvironmentID: "https://app.example", ConnectionID: config.ConnectionID("connection-" + name), PersonaID: config.PersonaID("persona-" + name), ConnectionGeneration: 2, RuntimeKind: runtime.AdapterKindHermes, TargetSelectionRevision: 3, AccountCandidateID: profile.AccountCandidateID, ProfileCandidateID: profile.CandidateID, NativeStateRoot: profile.Resolved.StateRoot, NativeConfigPath: profile.Resolved.ConfigPath, NativeProfileName: name, HermesHome: profile.Resolved.HermesHome, NativeMCPServer: "issued-" + name, NativeMCPNamespace: "mcp_" + name, PersonaMCPURL: "https://mcp.example/v1/mcp", PersonaMCPToken: "token", InventorySeed: "seed"}
		if err := store.SaveBinding(b); err != nil {
			t.Fatal(err)
		}
		runner.VerifyRuntimeEndpoint = func(_ context.Context, endpoint, root, path, kind string) (bool, error) {
			if endpoint != "http://127.0.0.1:8643/p/"+name || root != host || path != filepath.Join(host, "config.yaml") || kind != "hermes" {
				t.Fatal("wrong shared host identity")
			}
			return true, nil
		}
		runner.MCPHTTPClient = acceptedMCPCredentialClient(t, nil)
		if err := runner.RepairBinding(context.Background(), b, true, false, false); err != nil {
			t.Fatal(err)
		}
		b, _ = config.BindingFor(&store, b)
		native, resolved, err := runner.targetAdapter(b, targetForBinding(b))
		if err != nil {
			t.Fatal(err)
		}
		adapter := native.(runtime.HermesAdapter)
		if resolved.HermesHome != profile.Resolved.HermesHome || adapter.ProfileHome != profile.Resolved.HermesHome || adapter.APIKey != name+"-profile-key-123" || adapter.BaseURL != "http://127.0.0.1:8643/p/"+name {
			t.Fatal("named profile borrowed host credentials or listener intent")
		}
		calls := 0
		adapter.Client = &http.Client{Transport: credentialTransport(func(req *http.Request) (*http.Response, error) {
			calls++
			if req.Method != http.MethodGet || !strings.HasPrefix(req.URL.Path, "/p/"+name+"/") {
				t.Fatal("unplanned native submission or foreign profile route")
			}
			if req.URL.Path != "/p/"+name+"/health" && req.Header.Get("Authorization") != "Bearer "+name+"-profile-key-123" {
				t.Fatal("profile authentication changed")
			}
			body := `{}`
			if strings.HasSuffix(req.URL.Path, "/v1/capabilities") {
				body = `{"features":{"run_submission":true,"run_status":true,"run_events_sse":true,"run_stop":true}}`
			}
			return &http.Response{StatusCode: http.StatusOK, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body)), Request: req}, nil
		})}
		detection := runner.bindingReadinessAtHomeContext(context.Background(), adapter, b, home, resolved.HermesHome, adapter.BaseURL)
		if calls != 4 || detection.State != runtime.AdapterStateCapabilityMissing || detection.DiagnosticCode != "capability_missing" || canStartRunWithReadiness(detection.State, nil) {
			t.Fatalf("configured profile bypassed actual gateway MCP proof %+v calls%d", detection, calls)
		}
		if b.RuntimeLaunchAllowed {
			t.Fatal("eligible attach granted shared host startup")
		}
	}
	hostAfter, _ := os.ReadFile(filepath.Join(host, "config.yaml"))
	if string(hostBefore) != string(hostAfter) || len(store.ListBindings()) != 2 {
		t.Fatal("profile attachment changed host or lost sibling")
	}
}

func TestDesktopAgentBridgeHermesHostStartupAdmissionFence(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"permission missing", "quiesced", "active", "generation changed", "selection changed", "already running"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			b, store, runner := freshSelectedFixture(t)
			b.RuntimeLaunchAllowed = true
			b.TargetSelectionRevision = 3
			current := b
			switch scenario {
			case "permission missing":
				current.RuntimeLaunchAllowed = false
			case "quiesced":
				current.Quiesced = true
			case "active":
				current.ActiveRunID = "assigned"
			case "generation changed":
				current.ConnectionGeneration++
			case "selection changed":
				current.TargetSelectionRevision++
			}
			if err := store.SaveBinding(current); err != nil {
				t.Fatal(err)
			}
			calls := 0
			runner.VerifyRuntimeEndpoint = func(context.Context, string, string, string, string) (bool, error) {
				calls++
				if scenario != "already running" {
					t.Fatal("denied host startup performed owner read")
				}
				return true, nil
			}
			resolved, err := runner.resolveTarget(b, targetForBinding(b))
			if err != nil {
				t.Fatal(err)
			}
			err = runner.startTargetRuntime(context.Background(), b, targetForBinding(b), resolved, "http://127.0.0.1:8642/p/default")
			if scenario == "already running" {
				if err != nil || calls != 1 {
					t.Fatal("running host should remain unchanged", err)
				}
			} else if err == nil || calls != 0 {
				t.Fatal("stale native host permission admitted startup")
			}
		})
	}
}
