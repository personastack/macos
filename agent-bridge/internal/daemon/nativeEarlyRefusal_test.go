package daemon

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"

	protocol "github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/bridge"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

type earlyRefusalNativeAdapter struct {
	nativeDeadlineSubmissionAdapter
	t       *testing.T
	request runtime.RunRequest
}

func (a *earlyRefusalNativeAdapter) StartRun(request runtime.RunRequest) (string, error) {
	a.t.Helper()
	a.request = request
	if request.RunID != "successor" {
		a.t.Error("refusal dispatched native work")
	}
	return a.nativeDeadlineSubmissionAdapter.StartRun(request)
}

func TestNativeEarlyRefusalDispatchProofSurvivesLostFrameAndACK(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"quiesced", "target unavailable", "target mismatch", "adapter unavailable", "runtime not ready", "wake probe missing", "wake probe zero"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			now := time.Now().UTC()
			deadline := now.Add(time.Minute)
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3}
			if kind == "quiesced" {
				binding.Quiesced = true
			}
			memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			r := Runner{Store: &memory, Now: func() time.Time { return now }}
			session := bridge.Session{Binding: binding}
			adapter := &earlyRefusalNativeAdapter{t: t}
			target := &protocol.RuntimeTarget{AccountCandidateID: "account", ProfileCandidateID: "profile", RuntimeKind: protocol.RuntimeKindHermes, SelectionRevision: 3}
			snapshot := runtimeSnapshot{Target: target, Adapter: adapter, Detection: runtime.Detection{State: runtime.AdapterStateMCPVerified}}
			wake := &now
			request := protocol.Frame{MessageID: "lost-refusal", MessageType: protocol.FrameTypeRunStart, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "assignment-1", RunStart: &protocol.RunStartPayload{DeadlineAt: deadline, RuntimeTarget: target, FullyComposedPrompt: "prompt kept", Metadata: map[string]string{"origin": kind}}}
			expected := "external runtime is not ready: selected target is unavailable"
			switch kind {
			case "quiesced":
				expected = "background agent quiesced"
			case "target unavailable":
				snapshot.Target = nil
			case "target mismatch":
				wrong := *target
				wrong.ProfileCandidateID = "different-profile"
				snapshot.Target = &wrong
			case "adapter unavailable":
				snapshot.Adapter = nil
			case "runtime not ready":
				snapshot.Detection.State = runtime.AdapterStateMCPConfigMissing
				expected = "external runtime is not ready: mcp_config_missing"
			case "wake probe missing":
				wake = nil
				expected = "external runtime is not ready: mcp_verified"
			case "wake probe zero":
				zero := time.Time{}
				wake = &zero
				expected = "external runtime is not ready: mcp_verified"
			}
			_, native, failure, err := r.dispatchNativeRunStart(t.Context(), binding, session, adapter, request, protocol.ProtocolVersionV4, snapshot, wake)
			if err != nil || native != "" || failure == nil || failure.MessageID != request.MessageID || failure.RunTerminal == nil || failure.RunTerminal.ErrorCode != nativeNotStarted || failure.RunTerminal.FinalMessage != expected || failure.RunTerminal.NativeRunID != "" || adapter.starts.Load() != 0 {
				t.Fatal("actual refusal lost exact affirmative proof", native, failure, err)
			}
			original, _ := config.BindingFor(&memory, binding)
			if !original.ActiveRunNotStarted || original.ActiveRunID != "run-1" || !original.ActiveRunDeadlineAt.Equal(deadline) || original.Quiesced != binding.Quiesced {
				t.Fatal("empty-journal refusal did not retain scoped fact/permission/deadline", original)
			}
			// Drop the returned frame. Reload its durable representation and reconnect
			// without target/runtime readiness or a retained command cache.
			encoded, err := json.Marshal(memory.ListBindings())
			if err != nil {
				t.Fatal(err)
			}
			var saved []config.Binding
			if err = json.Unmarshal(encoded, &saved); err != nil {
				t.Fatal(err)
			}
			memory = config.NewMemoryStore(config.State{Bindings: saved})
			r.Store = &memory
			current, err := r.advanceConnectionGeneration(binding)
			if err != nil {
				t.Fatal(err)
			}
			replay := func(b config.Binding) (protocol.Frame, *nativeTerminalReceipts) {
				t.Helper()
				if !r.canReplayNeverStartedNative(b) {
					t.Fatal("proof replay depends on unavailable native runtime")
				}
				var proof protocol.Frame
				receipts := &nativeTerminalReceipts{}
				err := r.replayActiveRun(t.Context(), b, bridge.Session{Binding: b}, nil, newRunObservationRegistry(), func(f protocol.Frame) error {
					prepared, send, err := r.prepareAssignedRunFrame(b, f)
					if err == nil && send {
						proof = prepared
						receipts.record(r, b, prepared)
					}
					return err
				})
				if err != nil || proof.RunTerminal == nil || proof.RunTerminal.ErrorCode != nativeNotStarted || proof.RunTerminal.NativeRunID != "" || proof.RunID != "run-1" || proof.AssignmentID != "assignment-1" || proof.ConnectionGeneration != 3 {
					t.Fatal("reconnect did not resend original-generation no-start proof", proof, err)
				}
				return proof, receipts
			}
			oldProof, _ := replay(current) // Its correlated ACK is lost after API commit.
			current, err = r.advanceConnectionGeneration(current)
			if err != nil {
				t.Fatal(err)
			}
			proof, receipts := replay(current)
			oldACK := protocol.Frame{MessageID: oldProof.MessageID, MessageType: protocol.FrameTypeRunTerminalAck, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 4, RunID: "run-1", AssignmentID: "assignment-1", RunTerminalAck: &protocol.RunTerminalAckPayload{}}
			if released, err := r.acknowledgeNativeTerminal(current, oldACK, receipts); err != nil || released {
				t.Fatal("old transport ACK cleared current proof journal", err)
			}
			ack := oldACK
			ack.MessageID, ack.ConnectionGeneration = proof.MessageID, current.ConnectionGeneration
			if released, err := r.acknowledgeNativeTerminal(current, ack, receipts); err != nil || !released {
				t.Fatal("exact current correlated ACK did not settle no-start proof", err)
			}
			settled, _ := config.BindingFor(&memory, current)
			if settled.ActiveRunNotStarted || settled.ActiveRunID != "" || adapter.starts.Load() != 0 || adapter.polls.Load() != 0 || adapter.cancels.Load() != 0 {
				t.Fatal("refusal proof launched/polled native work or retained stale journal", settled)
			}
			// Quiescing remains in force. This models the existing explicit local resume
			// before new intent; proof settlement itself never changes permission.
			if settled.Quiesced {
				if err = config.UpdateBinding(&memory, current, func(b *config.Binding) error { b.Quiesced = false; return nil }); err != nil {
					t.Fatal(err)
				}
			}
			fresh := request
			fresh.MessageID = "fresh"
			fresh.ConnectionGeneration = current.ConnectionGeneration
			fresh.RunID = "successor"
			fresh.AssignmentID = "next"
			snapshot = runtimeSnapshot{Target: target, Adapter: adapter, Detection: runtime.Detection{State: runtime.AdapterStateMCPVerified}}
			selected, native, failure, err := r.dispatchNativeRunStart(t.Context(), current, bridge.Session{Binding: current}, nil, fresh, protocol.ProtocolVersionV4, snapshot, &now)
			if err != nil || failure != nil || native != "native-1" || selected != adapter || adapter.starts.Load() != 1 || adapter.request.RunID != "successor" || adapter.request.AssignmentID != "next" || adapter.request.FullyComposedPrompt != "prompt kept" || adapter.request.Metadata["origin"] != kind {
				t.Fatal("fresh intent failed or changed native request after safe proof", native, failure, err, adapter.request)
			}
			if released, err := r.acknowledgeNativeTerminal(current, ack, receipts); err != nil || released {
				t.Fatal("late predecessor ACK released fresh successor", err)
			}
		})
	}
}

func TestNativeEarlyRefusalPreservesExistingCustodyAndScope(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"known handle", "legacy unknown", "active conflict", "orphan handle", "stale transport"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			now := time.Now().UTC()
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3, Quiesced: true, ActiveRunID: "run-1", ActiveAssignmentID: "assignment-1", ActiveRunConnectionGeneration: 3, ActiveNativeRunID: "native-existing"}
			switch kind {
			case "legacy unknown":
				binding.ActiveNativeRunID = ""
				binding.ActiveRunConnectionGeneration = 0
			case "active conflict":
				binding.ActiveRunID = "sibling"
			case "orphan handle":
				binding.ActiveRunID = ""
				binding.ActiveAssignmentID = ""
			}
			memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			r := Runner{Store: &memory}
			request := protocol.Frame{MessageID: "message", ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "assignment-1", RunStart: &protocol.RunStartPayload{DeadlineAt: now.Add(time.Minute)}}
			reference := binding
			if kind == "stale transport" {
				reference.ConnectionGeneration = 2
			}
			adapter := &earlyRefusalNativeAdapter{t: t}
			_, _, failure, err := r.dispatchNativeRunStart(t.Context(), reference, bridge.Session{Binding: reference}, adapter, request, protocol.ProtocolVersionV4, runtimeSnapshot{}, nil)
			current, _ := config.BindingFor(&memory, binding)
			if !reflect.DeepEqual(current, binding) || current.ActiveRunNotStarted || adapter.starts.Load() != 0 {
				t.Fatal("early refusal changed retained custody/authority", current, binding)
			}
			switch kind {
			case "legacy unknown":
				if err != nil || failure == nil || failure.RunTerminal == nil || failure.RunTerminal.ErrorCode != nativeTerminationUnconfirmed {
					t.Fatal("legacy unknown became affirmative no-start proof", failure, err)
				}
			case "active conflict":
				if err != nil || failure == nil || failure.RunID != request.RunID || failure.RunTerminal.ErrorCode != nativeNotStarted {
					t.Fatal("conflict lost incoming correlation or touched sibling", failure, err)
				}
			default:
				if err == nil || failure != nil {
					t.Fatal("known/stale journal was certified as empty-journal no-start", failure, err)
				}
			}
		})
	}
}
