package daemon

import (
	"context"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
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
