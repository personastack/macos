package daemon

import (
	"context"
	"fmt"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"io"
	"net/http"
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
	binding := config.Binding{EnvironmentID: "https://a.example", PersonaID: "persona", ConnectionID: "connection", ConnectionGeneration: 3}
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
	reconciler := newSessionReconciler(context.Background(), Runner{Store: &store}, binding, nil, runtime.Detection{})
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
