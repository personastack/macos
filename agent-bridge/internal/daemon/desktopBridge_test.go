package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/bridge"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/control"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
	"gopkg.in/yaml.v3"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDesktopAgentBridgeAssignedRunGenerationAndRevocation(t *testing.T) {
	t.Parallel()
	a := config.Binding{EnvironmentID: "https://a.example", ConnectionID: "same", ConnectionGeneration: 2, PersonaMCPToken: "keep", NativeMCPServer: "issued", RuntimeKind: runtime.AdapterKindHermes}
	b := a
	b.EnvironmentID = "https://b.example"
	store := config.NewMemoryStore(config.State{Bindings: []config.Binding{a, b}})
	runner := Runner{Store: &store}
	frame := externalagentprotocol.Frame{RunID: "run-a", AssignmentID: "assignment-a", RunStart: &externalagentprotocol.RunStartPayload{FullyComposedPrompt: "wake"}}
	if err := runner.activateRun(a, frame); err != nil {
		t.Fatal(err)
	}
	if err := runner.recordNativeRunID(a, "run-a", "native-a"); err != nil {
		t.Fatal(err)
	}
	stale := a
	stale.ConnectionGeneration = 1
	if err := runner.recordNativeRunID(stale, "run-a", "foreign"); err == nil {
		t.Fatal("stale callback admitted")
	}
	if err := runner.clearRunState(a, "foreign"); err != nil {
		t.Fatal(err)
	}
	active, _ := config.BindingFor(&store, a)
	if active.ActiveRunID != "run-a" || active.ActiveNativeRunID != "native-a" {
		t.Fatal("foreign completion cleared run")
	}
	if err := runner.revokeBinding(a, nil, "revoked"); err != nil {
		t.Fatal(err)
	}
	active, _ = config.BindingFor(&store, a)
	other, _ := config.BindingFor(&store, b)
	if !active.Quiesced || active.PersonaMCPToken != "keep" || active.ActiveRunID != "run-a" || other.Quiesced || other.ActiveRunID != "" {
		t.Fatalf("revocation crossed scope or removed custody %+v %+v", active, other)
	}
	if err := runner.activateRun(a, frame); err == nil {
		t.Fatal("quiesced admitted new assignment")
	}
	if err := runner.clearRunState(a, "run-a"); err != nil {
		t.Fatal(err)
	}
	active, _ = config.BindingFor(&store, a)
	if !active.Quiesced || active.ActiveRunID != "" {
		t.Fatal("terminal removed quiesce")
	}
}

func TestDesktopAgentBridgeWireGenerationAndTargetEpoch(t *testing.T) {
	t.Parallel()
	binding := config.Binding{EnvironmentID: "https://a.example", PersonaID: "persona", ConnectionID: "connection", ConnectionGeneration: 3, RuntimeKind: runtime.AdapterKindHermes, AccountCandidateID: "account", ProfileCandidateID: "profile"}
	frame := externalagentprotocol.Frame{PersonaID: "persona", ConnectionID: "connection", ConnectionGeneration: 3}
	if !matchesFrameScope(binding, frame) {
		t.Fatal("exact frame denied")
	}
	frame.ConnectionGeneration = 2
	if matchesFrameScope(binding, frame) {
		t.Fatal("stale frame admitted")
	}
	frame.ConnectionGeneration = 3
	frame.PersonaID = "other"
	if matchesFrameScope(binding, frame) {
		t.Fatal("foreign persona admitted")
	}
	store := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
	reconciler := newSessionReconciler(context.Background(), Runner{Store: &store, ResolveTarget: func(config.Binding, *externalagentprotocol.RuntimeTarget) (targetinventory.ResolvedTarget, error) {
		return targetinventory.ResolvedTarget{}, nil
	}}, binding, nil, runtime.Detection{})
	target := &externalagentprotocol.RuntimeTarget{AccountCandidateID: "account", ProfileCandidateID: "profile", RuntimeKind: externalagentprotocol.RuntimeKindHermes, SelectionRevision: 4}
	if !reconciler.setTarget(target, 2) {
		t.Fatal("target not selected")
	}
	first := reconciler.snapshotCopy()
	if reconciler.clearTarget(3, 3) || reconciler.clearTarget(4, 1) {
		t.Fatal("stale clear admitted")
	}
	if !reconciler.setTarget(target, 3) {
		t.Fatal("new epoch not applied")
	}
	reconciler.publish(first, reconcileResult{Detection: runtime.Detection{State: runtime.AdapterStateReady}})
	if reconciler.snapshotCopy().Detection.State == runtime.AdapterStateReady {
		t.Fatal("old epoch callback admitted")
	}
	if !reconciler.clearTarget(5, 4) {
		t.Fatal("current clear denied")
	}
	readback, _ := config.BindingFor(&store, binding)
	if readback.ReadinessState != runtime.AdapterStateTargetSelectionRequired || readback.TargetSelectionRevision != 0 {
		t.Fatal("clear status stale")
	}
}

func TestDesktopAgentBridgeCanonicalMCPRefreshScope(t *testing.T) {
	t.Parallel()
	b := config.Binding{EnvironmentID: "https://one.example", PersonaID: "p", ConnectionID: "same", ConnectionGeneration: 2, NativeMCPServer: "old", PersonaMCPToken: "durable"}
	other := b
	other.EnvironmentID = "https://two.example"
	store := config.NewMemoryStore(config.State{Bindings: []config.Binding{b, other}})
	runner := Runner{Store: &store}
	refresh := &externalagentprotocol.ConfigRefreshPayload{MCPURL: "https://mcp.example/v1/mcp", NativeMCPServerName: "new-issued", NativeMCPToolNamespace: "mcp_new"}
	if err := runner.applyMCPConfiguration(b, refresh); err != nil {
		t.Fatal(err)
	}
	current, _ := config.BindingFor(&store, b)
	sibling, _ := config.BindingFor(&store, other)
	if current.NativeMCPServer != "new-issued" || current.PersonaMCPToken != "durable" || sibling.NativeMCPServer != "old" {
		t.Fatal("canonical metadata crossed keyed scope or changed token")
	}
	stale := b
	stale.ConnectionGeneration = 1
	refresh.NativeMCPServerName = "foreign"
	if err := runner.applyMCPConfiguration(stale, refresh); err == nil {
		t.Fatal("stale metadata admitted")
	}
	readback, _ := config.BindingFor(&store, b)
	if readback.NativeMCPServer != "new-issued" {
		t.Fatal("failed metadata mutation had effects")
	}
}

type assignedCancelAdapter struct {
	runtime.ErrorAdapter
	cancel func(string) error
}

func (a assignedCancelAdapter) CancelRun(id string) error { return a.cancel(id) }

func TestDesktopAgentBridgeRunCancelUsesSelectedAdapterAndKeepsFailedObservation(t *testing.T) {
	t.Parallel()
	for _, kind := range []runtime.AdapterKind{runtime.AdapterKindHermes, runtime.AdapterKindOpenClaw} {
		t.Run(kind.String(), func(t *testing.T) {
			t.Parallel()
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona", ConnectionID: "connection", ConnectionGeneration: 3, RuntimeKind: kind, ActiveRunID: "assigned", ActiveNativeRunID: "native-selected"}
			store := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			runner := Runner{Store: &store}
			calls := 0
			fail := true
			selected := assignedCancelAdapter{cancel: func(id string) error {
				calls++
				if id != "native-selected" {
					t.Fatal("foreign native run stopped")
				}
				if fail {
					return fmt.Errorf("native stop refused")
				}
				return nil
			}}
			base := assignedCancelAdapter{cancel: func(string) error { t.Fatal("unselected base adapter used"); return nil }}
			reconciler := newSessionReconciler(context.Background(), runner, binding, base, runtime.Detection{})
			reconciler.snapshot.Adapter = selected
			registry := newRunObservationRegistry()
			observeCtx, cancel := context.WithCancel(context.Background())
			defer registry.track("assigned", cancel)()
			cache := newCommandFrameCache()
			frame := externalagentprotocol.Frame{MessageType: externalagentprotocol.FrameTypeRunCancel, MessageID: "cancel-message", PersonaID: string(binding.PersonaID), ConnectionID: string(binding.ConnectionID), ConnectionGeneration: 3, RunID: "assigned", RunCancel: &externalagentprotocol.RunCancelPayload{}}
			stale := frame
			stale.ConnectionGeneration = 2
			if err := runner.cancelAssignedRun(binding, stale, base, reconciler, cache); err != nil || calls != 0 {
				t.Fatal("stale cancel touched native runtime")
			}
			if err := runner.cancelAssignedRun(binding, frame, base, reconciler, cache); err == nil || observeCtx.Err() != nil || cache.seen(frame) {
				t.Fatal("failed cancellation abandoned observation or blocked retry")
			}
			fail = false
			if err := runner.cancelAssignedRun(binding, frame, base, reconciler, cache); err != nil || observeCtx.Err() != nil || calls != 2 {
				t.Fatalf("selected cancel failed: %v calls=%d", err, calls)
			}
			if err := runner.cancelAssignedRun(binding, frame, base, reconciler, cache); err != nil || calls != 2 {
				t.Fatal("successful cancel duplicate reached runtime")
			}
			current, _ := config.BindingFor(&store, binding)
			if current.ActiveRunID != "assigned" {
				t.Fatal("cancel cleared assigned state before terminal acknowledgement")
			}
			registry.cancel("assigned")
			if err := runner.clearRunState(binding, "assigned"); err != nil {
				t.Fatal(err)
			}
			current, _ = config.BindingFor(&store, binding)
			if observeCtx.Err() != context.Canceled || current.ActiveRunID != "" {
				t.Fatal("actual terminal acknowledgement did not settle assigned state")
			}
		})
	}
}

type credentialTransport func(*http.Request) (*http.Response, error)

func (f credentialTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestDesktopAgentBridgeRepairRejectedMCPCredentialHasNoRuntimeMutation(t *testing.T) {
	t.Parallel()
	for _, fault := range []string{"missing", "rejected", "durable_rejection"} {
		t.Run(fault, func(t *testing.T) {
			t.Parallel()
			b := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona", ConnectionID: "connection", ConnectionGeneration: 2, RuntimeKind: runtime.AdapterKindHermes, TargetSelectionRevision: 3, PersonaMCPURL: "https://mcp.example/v1/mcp", PersonaMCPToken: "rejected", RuntimeLaunchAllowed: false}
			if fault == "missing" {
				b.PersonaMCPToken = ""
			}
			if fault == "durable_rejection" {
				b.ReadinessDiagnosticCode = "reconnect_required"
			}
			store := config.NewMemoryStore(config.State{Bindings: []config.Binding{b}})
			calls := 0
			runner := Runner{Store: &store, MCPHTTPClient: &http.Client{Transport: credentialTransport(func(req *http.Request) (*http.Response, error) {
				calls++
				if fault != "rejected" {
					t.Fatal("known custody fault performed HTTP read")
				}
				if req.Method != "POST" || req.URL.String() != "https://mcp.example/v1/mcp" || req.Header.Get("Authorization") != "Bearer rejected" || req.Header.Get("Content-Type") != "application/json" {
					t.Fatal("wrong credential probe scope")
				}
				raw, _ := io.ReadAll(req.Body)
				if !strings.Contains(string(raw), `"method":"initialize"`) {
					t.Fatal("wrong credential probe DTO")
				}
				return &http.Response{StatusCode: http.StatusUnauthorized, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("denied")), Request: req}, nil
			})}}
			err := runner.RepairBinding(context.Background(), b, true)
			if err == nil || !strings.HasPrefix(err.Error(), "reconnect_required:") {
				t.Fatalf("credential repair claimed success: %v", err)
			}
			current, _ := config.BindingFor(&store, b)
			if current.RuntimeLaunchAllowed || current.MCPOwnership.EntryKey != "" || current.PersonaMCPToken != b.PersonaMCPToken {
				t.Fatal("credential fault changed runtime/install/custody")
			}
			detection, err := runner.CheckBinding(context.Background(), current)
			if err != nil || detection.DiagnosticCode != "reconnect_required" {
				t.Fatalf("check lost explicit renewal boundary: %+v %v", detection, err)
			}
			wantCalls := 0
			if fault == "rejected" {
				wantCalls = 1
			}
			if calls != wantCalls {
				t.Fatalf("unplanned credential HTTP calls %d", calls)
			}
		})
	}
}

func freshSelectedFixture(t *testing.T) (config.Binding, *config.MemoryStore, Runner) {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "config.yaml")
	if err := os.WriteFile(path, []byte("mcp_servers: {}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	b := config.Binding{EnvironmentID: "https://app.example", ConnectionID: "connection", PersonaID: "persona", ConnectionGeneration: 2, RuntimeKind: runtime.AdapterKindHermes, AccountCandidateID: "account", ProfileCandidateID: "profile", NativeStateRoot: root, NativeConfigPath: path, HermesHome: root, NativeMCPServer: "issued", NativeMCPNamespace: "mcp_issued", PersonaMCPURL: "https://mcp.example/v1/mcp", PersonaMCPToken: "token", InventorySeed: "seed"}
	store := config.NewMemoryStore(config.State{Bindings: []config.Binding{b}})
	runner := Runner{Store: &store, ResolveTarget: func(reference config.Binding, target *externalagentprotocol.RuntimeTarget) (targetinventory.ResolvedTarget, error) {
		if reference.Key() != b.Key() || target.AccountCandidateID != "account" || target.ProfileCandidateID != "profile" {
			t.Fatal("unplanned profile resolution")
		}
		return targetinventory.ResolvedTarget{HomeDir: root, HermesHome: root, StateRoot: root, ConfigPath: path, UID: os.Geteuid(), GID: os.Getegid()}, nil
	}, VerifyRuntimeEndpoint: func(context.Context, string, string, string, string) (bool, error) { return false, nil }}
	return b, &store, runner
}
func acceptedMCPCredentialClient(t *testing.T, firstRead func()) *http.Client {
	t.Helper()
	calls := 0
	return &http.Client{Transport: credentialTransport(func(req *http.Request) (*http.Response, error) {
		calls++
		if calls == 1 && firstRead != nil {
			firstRead()
		}
		if req.Method != "POST" || req.URL.String() != "https://mcp.example/v1/mcp" || req.Header.Get("Authorization") != "Bearer token" {
			t.Fatal("wrong MCP authorization scope")
		}
		var message struct {
			Method string          `json:"method"`
			ID     json.RawMessage `json:"id"`
		}
		if err := json.NewDecoder(req.Body).Decode(&message); err != nil {
			t.Fatal(err)
		}
		expected := []string{"initialize", "notifications/initialized", "tools/list"}
		if calls > 3 || message.Method != expected[calls-1] {
			t.Fatalf("unplanned MCP credential call %s", message.Method)
		}
		status := http.StatusOK
		body := `{"jsonrpc":"2.0","id":` + string(message.ID) + `,"result":{}}`
		if calls == 2 {
			status = http.StatusAccepted
			body = ""
		}
		return &http.Response{StatusCode: status, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body)), Request: req}, nil
	})}
}

func TestDesktopAgentBridgeFreshTargetStoppedRuntimeCanBeRepaired(t *testing.T) {
	t.Parallel()
	b, store, runner := freshSelectedFixture(t)
	if err := os.WriteFile(b.NativeConfigPath, []byte("user_key: keep\nplatform_toolsets:\n  api_server: [terminal, no_mcp]\n  cli: [no_mcp, file]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	runner.MCPHTTPClient = acceptedMCPCredentialClient(t, nil)
	reconciler := newSessionReconciler(context.Background(), runner, b, nil, runtime.Detection{})
	target := targetForBinding(b)
	target.SelectionRevision = 3
	foreign := *target
	foreign.ProfileCandidateID = "foreign"
	if reconciler.setTarget(&foreign, 1) {
		t.Fatal("foreign profile selection persisted")
	}
	before, _ := config.BindingFor(store, b)
	if before.TargetSelectionRevision != 0 {
		t.Fatal("rejected target mutation had side effects")
	}
	if !reconciler.setTarget(target, 1) {
		t.Fatal("fresh API target rejected")
	}
	selected, _ := config.BindingFor(store, b)
	if selected.TargetSelectionRevision != 3 || selected.ReadinessState == runtime.AdapterStateMCPVerified || selected.RuntimeLaunchAllowed {
		t.Fatal("selection was not durable or claimed readiness/consent")
	}
	snapshot := reconciler.snapshotCopy()
	result, err := runner.reconcileTarget(context.Background(), selected, snapshot)
	if err == nil || !strings.Contains(err.Error(), "native consent required") {
		t.Fatalf("stopped runtime did not require consent: %v", err)
	}
	result.Detection = detectionForReconcileError(b.RuntimeKind, err)
	reconciler.publish(snapshot, result)
	selected, _ = config.BindingFor(store, b)
	if err := runner.RepairBinding(context.Background(), selected, true); err != nil {
		t.Fatal(err)
	}
	repaired, _ := config.BindingFor(store, b)
	if repaired.TargetSelectionRevision != 3 || !repaired.RuntimeLaunchAllowed || repaired.MCPOwnership.EntryKey != "issued" || repaired.ReadinessState == runtime.AdapterStateMCPVerified {
		t.Fatal("explicit repair did not preserve unverified selection and scoped consent")
	}
	env, err := os.ReadFile(filepath.Join(b.HermesHome, ".env"))
	if err != nil || !strings.Contains(string(env), "API_SERVER_ENABLED=true") {
		t.Fatal("selected Hermes API setup missing")
	}
	raw, _ := os.ReadFile(b.NativeConfigPath)
	var toolsets struct {
		User      string `yaml:"user_key"`
		Platforms struct {
			API []string `yaml:"api_server"`
			CLI []string `yaml:"cli"`
		} `yaml:"platform_toolsets"`
	}
	if err := yaml.Unmarshal(raw, &toolsets); err != nil {
		t.Fatal(err)
	}
	if toolsets.User != "keep" || strings.Join(toolsets.Platforms.API, ",") != "terminal,issued" || strings.Join(toolsets.Platforms.CLI, ",") != "no_mcp,file" {
		t.Fatal("Repair did not enable only this profile's API MCP toolset")
	}
}

type reconnectMutationStore struct {
	*config.MemoryStore
	before func()
}

func (s *reconnectMutationStore) UpdateBinding(key config.BindingKey, change func(*config.Binding) error) error {
	if s.before != nil {
		before := s.before
		s.before = nil
		before()
	}
	return s.MemoryStore.UpdateBinding(key, change)
}

func TestDesktopAgentBridgeReconnectCapturesCurrentMutationAndDoesNotResurrect(t *testing.T) {
	t.Parallel()
	for _, mutation := range []string{"quiesce", "repair", "run_start", "disconnect"} {
		t.Run(mutation, func(t *testing.T) {
			t.Parallel()
			b := config.Binding{EnvironmentID: "https://app.example", ConnectionID: "same", ConnectionGeneration: 4}
			other := b
			other.EnvironmentID = "https://other.example"
			memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{b, other}})
			store := &reconnectMutationStore{MemoryStore: &memory}
			store.before = func() {
				if mutation == "disconnect" {
					if err := memory.DeleteBindingKey(b.Key()); err != nil {
						t.Fatal(err)
					}
					return
				}
				err := memory.UpdateBinding(b.Key(), func(current *config.Binding) error {
					switch mutation {
					case "quiesce":
						current.Quiesced = true
					case "repair":
						current.RuntimeLaunchAllowed = true
						current.TargetSelectionRevision = 7
						current.MCPOwnership.EntryKey = "current-owned"
					case "run_start":
						current.ActiveRunID, current.ActiveNativeRunID = "accepted", "native"
					}
					return nil
				})
				if err != nil {
					t.Fatal(err)
				}
			}
			captured, err := (Runner{Store: store}).advanceConnectionGeneration(b)
			persisted, exists := config.BindingFor(store, b)
			if mutation == "disconnect" {
				if err == nil || exists || captured.ConnectionID != "" {
					t.Fatal("reconnect recreated a removed binding")
				}
			} else {
				if err != nil || !exists || captured.ConnectionGeneration != 5 || persisted.ConnectionGeneration != 5 {
					t.Fatalf("reconnect did not capture incremented current state: %v", err)
				}
				if captured.Quiesced != persisted.Quiesced || captured.RuntimeLaunchAllowed != persisted.RuntimeLaunchAllowed || captured.MCPOwnership != persisted.MCPOwnership || captured.ActiveNativeRunID != persisted.ActiveNativeRunID {
					t.Fatal("session snapshot diverged from current mutation")
				}
				if mutation == "quiesce" && !captured.Quiesced || mutation == "repair" && (!captured.RuntimeLaunchAllowed || captured.TargetSelectionRevision != 7 || captured.MCPOwnership.EntryKey != "current-owned") || mutation == "run_start" && captured.ActiveRunID != "accepted" {
					t.Fatal("reconnect discarded concurrent admission or repair")
				}
			}
			foreign, _ := config.BindingFor(store, other)
			if foreign.ConnectionGeneration != 4 || foreign.Quiesced || foreign.RuntimeLaunchAllowed || foreign.ActiveRunID != "" {
				t.Fatal("reconnect crossed environment scope")
			}
		})
	}
}

func TestDesktopAgentBridgeRepairDeniedNativeConsentHasNoMutation(t *testing.T) {
	t.Parallel()
	b, store, runner := freshSelectedFixture(t)
	b.TargetSelectionRevision = 3
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	raw := "user_key: keep\nplatform_toolsets:\n  api_server: [terminal, no_mcp]\n"
	if err := os.WriteFile(b.NativeConfigPath, []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	runner.MCPHTTPClient = &http.Client{Transport: credentialTransport(func(*http.Request) (*http.Response, error) {
		t.Fatal("denied native consent performed protected credential read")
		return nil, nil
	})}
	err := runner.RepairBinding(context.Background(), b, false)
	if err == nil || !strings.HasPrefix(err.Error(), "runtime_conflict:") {
		t.Fatalf("denied native consent accepted: %v", err)
	}
	after, _ := os.ReadFile(b.NativeConfigPath)
	current, _ := config.BindingFor(store, b)
	if string(after) != raw || current.RuntimeLaunchAllowed || current.MCPOwnership.EntryKey != "" {
		t.Fatal("denied native consent changed profile or store")
	}
	if _, err = os.Stat(filepath.Join(b.HermesHome, ".env")); !os.IsNotExist(err) {
		t.Fatal("denied native consent created runtime environment")
	}
}

func TestDesktopAgentBridgeActualOpenClawProfileSelectedAgentDispatch(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	root := filepath.Join(home, ".openclaw-work")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "openclaw.json")
	raw := `{"agents":{"entries":{"main":{"name":"Other agent"},"research":{"name":"Chosen research"}}},"gateway":{"port":25907,"auth":{"mode":"token","token":"selected-profile-key"}}}`
	if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	profiles, warnings := targetinventory.DiscoverAt(home, "fixture", os.Getuid(), os.Getgid(), runtime.AdapterKindOpenClaw, "seed")
	if len(warnings) != 0 || len(profiles) != 1 {
		t.Fatalf("actual selected native profile not discovered: %v", warnings)
	}
	profile := profiles[0]
	candidate := ""
	for _, agent := range profile.OpenClawAgents {
		if strings.HasPrefix(agent.Label, "Chosen research") {
			candidate = agent.CandidateID
		}
	}
	profile, err := targetinventory.SelectOpenClawAgent(profile, candidate)
	if err != nil || candidate == "" {
		t.Fatalf("native opaque choice rejected: %v", err)
	}
	b := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona", ConnectionID: "connection", ConnectionGeneration: 3, RuntimeKind: runtime.AdapterKindOpenClaw, AccountCandidateID: profile.AccountCandidateID, ProfileCandidateID: profile.CandidateID, NativeStateRoot: profile.Resolved.StateRoot, NativeConfigPath: profile.Resolved.ConfigPath, SelectedOpenClawAgentID: profile.Resolved.OpenClawAgentID, InventorySeed: "seed"}
	store := config.NewMemoryStore(config.State{Bindings: []config.Binding{b}})
	runner := Runner{Store: &store, ResolveTarget: func(binding config.Binding, target *externalagentprotocol.RuntimeTarget) (targetinventory.ResolvedTarget, error) {
		return targetinventory.ResolveProfiles(binding.RuntimeKind, target, profiles, binding.SelectedOpenClawAgentID)
	}}
	adapter, resolved, err := runner.targetAdapter(b, targetForBinding(b))
	if err != nil || resolved.OpenClawAgentID != "research" {
		t.Fatalf("selected config did not construct actual chosen adapter: %v", err)
	}
	selected := adapter.(runtime.OpenClawAdapter)
	calls := 0
	selected.CallNative = func(ctx context.Context, request runtime.OpenClawRequest) (runtime.OpenClawResponse, error) {
		calls++
		if request.Method != "agent" || request.ID != "assignment" || selected.AgentID != "research" || selected.Token != "selected-profile-key" || selected.GatewayURL != "ws://127.0.0.1:25907" {
			t.Fatal("actual native dispatch selected another agent, profile, or credential")
		}
		raw, err := json.Marshal(request.Params)
		if err != nil {
			t.Fatal(err)
		}
		var submission struct {
			Agent      string `json:"agentId"`
			Assignment string `json:"idempotencyKey"`
			Message    string `json:"message"`
		}
		if err = json.Unmarshal(raw, &submission); err != nil {
			t.Fatal(err)
		}
		if submission.Agent != "research" || submission.Assignment != "assignment" || submission.Message != "assigned wake" {
			t.Fatal("native agent DTO lost explicitly selected non-main identity")
		}
		ok := true
		return runtime.OpenClawResponse{OK: &ok, Type: "res", ID: request.ID, Payload: json.RawMessage(`{"runId":"native-research","status":"accepted"}`)}, nil
	}
	frame := externalagentprotocol.Frame{PersonaID: "persona", ConnectionID: "connection", ConnectionGeneration: 3, RunID: "wake", AssignmentID: "assignment", RunStart: &externalagentprotocol.RunStartPayload{FullyComposedPrompt: "assigned wake"}}
	if err = runner.activateRun(b, frame); err != nil {
		t.Fatal(err)
	}
	native, err := selected.StartRun(runtime.RunRequest{RunID: frame.RunID, AssignmentID: frame.AssignmentID, FullyComposedPrompt: frame.RunStart.FullyComposedPrompt})
	if err != nil || calls != 1 || native != "native-research" {
		t.Fatalf("actual selected assignment dispatch failed: %s %v", native, err)
	}
}

func TestDesktopAgentBridgeQuiescedAssignedRunRetainsControlAndReplays(t *testing.T) {
	t.Parallel()
	for _, kind := range []runtime.AdapterKind{runtime.AdapterKindHermes, runtime.AdapterKindOpenClaw} {
		t.Run(kind.String(), func(t *testing.T) {
			t.Parallel()
			b, store, runner := freshSelectedFixture(t)
			b.RuntimeKind = kind
			b.ActiveRunID = "assigned"
			b.ActiveAssignmentID = "assignment"
			b.ActiveNativeRunID = "native"
			b.TargetSelectionRevision = 3
			if err := store.SaveBinding(b); err != nil {
				t.Fatal(err)
			}
			key := b.Key()
			payload, _ := json.Marshal(control.BindingPayload{BindingKey: &key})
			encoded, _ := json.Marshal(control.Request{Version: 1, RequestID: uuid.NewString(), Operation: "quiesce", Payload: payload})
			response := (&control.Controller{Store: store}).Dispatch(context.Background(), encoded)
			if response.Error != nil || response.Result.Quiesced == nil || !*response.Result.Quiesced {
				t.Fatalf("scoped native quiesce failed: %+v", response)
			}
			b, _ = config.BindingFor(store, b)
			cancelled := 0
			adapter := assignedCancelAdapter{cancel: func(id string) error {
				if id != "native" {
					t.Fatal("foreign run stopped")
				}
				cancelled++
				return nil
			}}
			reconciler := newSessionReconciler(context.Background(), runner, b, nil, runtime.Detection{})
			reconciler.snapshot.Target = targetForBinding(b)
			reconciler.snapshot.TargetRevision = 3
			reconciler.snapshot.Adapter = adapter
			snapshot := reconciler.snapshotCopy()
			result, err := runner.reconcileTarget(context.Background(), b, snapshot)
			if err != nil {
				t.Fatal(err)
			}
			reconciler.publish(snapshot, result)
			if reconciler.snapshotCopy().Adapter == nil {
				t.Fatal("quiesce erased active execution adapter")
			}
			frame := externalagentprotocol.Frame{MessageType: externalagentprotocol.FrameTypeRunStart, MessageID: "redelivery", ConnectionID: string(b.ConnectionID), PersonaID: string(b.PersonaID), ConnectionGeneration: 2, RunID: "assigned", AssignmentID: "assignment", RunStart: &externalagentprotocol.RunStartPayload{RuntimeTarget: targetForBinding(b)}}
			session := bridge.Session{Binding: b}
			cache := newCommandFrameCache()
			replies, replayed := runner.runStartReplayReplies(b, frame, session, cache)
			if !replayed || len(replies) != 2 || replies[0].RunAccepted == nil || replies[1].RunStarted == nil {
				t.Fatal("quiesce rejected accepted assignment replay")
			}
			fresh := frame
			fresh.RunID = "new"
			fresh.AssignmentID = "new-assignment"
			fresh.MessageID = "new-message"
			if _, ok := runner.runStartReplayReplies(b, fresh, session, cache); ok {
				t.Fatal("new run reused accepted replay")
			}
			if err := runner.activateRun(b, fresh); err == nil {
				t.Fatal("quiesce admitted new run")
			}
			stop := frame
			stop.MessageType = externalagentprotocol.FrameTypeRunCancel
			stop.MessageID = "stop"
			stop.RunCancel = &externalagentprotocol.RunCancelPayload{}
			if err := runner.cancelAssignedRun(b, stop, nil, reconciler, cache); err != nil || cancelled != 1 {
				t.Fatalf("active Stop lost selected adapter: %v", err)
			}
			active, _ := config.BindingFor(store, b)
			if active.ActiveRunID != "assigned" {
				t.Fatal("Stop acceptance cleared unsettled run")
			}
			if err := runner.clearRunState(b, "assigned"); err != nil {
				t.Fatal(err)
			}
			settled, _ := config.BindingFor(store, b)
			if settled.ActiveRunID != "" || !settled.Quiesced {
				t.Fatal("terminal acknowledgement did not retain quiesce")
			}
			next := reconciler.snapshotCopy()
			idle, err := runner.reconcileTarget(context.Background(), settled, next)
			if err != nil {
				t.Fatal(err)
			}
			reconciler.publish(next, idle)
			if _, ok := runner.runStartReplayReplies(b, frame, session, newCommandFrameCache()); ok {
				t.Fatal("settled assignment replayed")
			}
		})
	}
}

func TestDesktopAgentBridgeRepairConcurrentAdmissionDoesNotOverwriteState(t *testing.T) {
	t.Parallel()
	for _, change := range []string{"run_start", "quiesce", "generation", "target_revision"} {
		t.Run(change, func(t *testing.T) {
			t.Parallel()
			b, store, runner := freshSelectedFixture(t)
			b.TargetSelectionRevision = 3
			if err := store.SaveBinding(b); err != nil {
				t.Fatal(err)
			}
			before, err := os.ReadFile(b.NativeConfigPath)
			if err != nil {
				t.Fatal(err)
			}
			runner.MCPHTTPClient = acceptedMCPCredentialClient(t, func() {
				if err := config.UpdateBinding(store, b, func(current *config.Binding) error {
					switch change {
					case "run_start":
						current.ActiveRunID = "accepted"
						current.ActiveAssignmentID = "accepted-assignment"
						current.ActiveNativeRunID = "native"
					case "quiesce":
						current.Quiesced = true
					case "generation":
						current.ConnectionGeneration++
					case "target_revision":
						current.TargetSelectionRevision++
					}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
			})
			if err := runner.RepairBinding(context.Background(), b, true); err == nil {
				t.Fatal("stale Repair admission accepted")
			}
			current, _ := config.BindingFor(store, b)
			if current.RuntimeLaunchAllowed || current.MCPOwnership.EntryKey != "" {
				t.Fatal("stale Repair mutated consent or MCP ownership")
			}
			switch change {
			case "run_start":
				if current.ActiveRunID != "accepted" || current.ActiveNativeRunID != "native" {
					t.Fatal("Repair clobbered accepted run")
				}
			case "quiesce":
				if !current.Quiesced {
					t.Fatal("Repair undid quiesce")
				}
			case "generation":
				if current.ConnectionGeneration != 3 {
					t.Fatal("Repair overwrote fresh generation")
				}
			case "target_revision":
				if current.TargetSelectionRevision != 4 {
					t.Fatal("Repair overwrote fresh target")
				}
			}
			after, _ := os.ReadFile(b.NativeConfigPath)
			if string(after) != string(before) {
				t.Fatal("stale Repair changed native config")
			}
			if _, err := os.Stat(filepath.Join(b.HermesHome, ".env")); !os.IsNotExist(err) {
				t.Fatal("stale Repair changed Hermes API setup")
			}
		})
	}
}

func TestDesktopAgentBridgeQuiescedAcceptedAssignmentRestoresSelectedControlAdapter(t *testing.T) {
	t.Parallel()
	b, store, runner := freshSelectedFixture(t)
	b.Quiesced = true
	b.ActiveRunID = "accepted"
	b.ActiveAssignmentID = "assignment"
	b.ActiveNativeRunID = "native"
	b.TargetSelectionRevision = 3
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	runner.VerifyRuntimeEndpoint = func(context.Context, string, string, string, string) (bool, error) {
		t.Fatal("quiesced accepted work probed or started runtime")
		return false, nil
	}
	snapshot := runtimeSnapshot{Generation: b.ConnectionGeneration, Target: targetForBinding(b), TargetRevision: 3}
	result, err := runner.reconcileTarget(context.Background(), b, snapshot)
	if err != nil || result.Adapter == nil || result.Adapter.Kind() != runtime.AdapterKindHermes {
		t.Fatalf("selected control adapter not restored: %+v %v", result, err)
	}
	current, _ := config.BindingFor(store, b)
	if current.ActiveRunID != "accepted" || !current.Quiesced || current.MCPOwnership.EntryKey != "" || current.RuntimeLaunchAllowed {
		t.Fatal("accepted control restoration changed admission/config")
	}
}
