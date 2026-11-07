package daemon

import (
	"encoding/json"
	"os"
	"testing"

	protocol "github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
)

func TestNativeCustodyACKRequiresSentProofAndCurrentTransport(t *testing.T) {
	t.Parallel()
	raw, err := os.ReadFile("testdata/native-custody.json")
	if err != nil {
		t.Fatal(err)
	}
	var corpus struct {
		Observations []protocol.Frame `json:"observations"`
	}
	if err = json.Unmarshal(raw, &corpus); err != nil {
		t.Fatal(err)
	}
	frames := corpus.Observations
	for _, reconnect := range []bool{false, true} {
		t.Run(map[bool]string{false: "same connection", true: "reconnect after lost ACK"}[reconnect], func(t *testing.T) {
			t.Parallel()
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3, ActiveRunConnectionGeneration: 3, ActiveRunID: "run-1", ActiveAssignmentID: "run-1", ActiveNativeRunID: "native-1"}
			store := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			r := Runner{Store: &store}
			receipts := &nativeTerminalReceipts{}
			ack := func(f protocol.Frame) protocol.Frame {
				return protocol.Frame{MessageID: f.MessageID, MessageType: protocol.FrameTypeRunTerminalAck, ConnectionID: string(binding.ConnectionID), PersonaID: string(binding.PersonaID), ConnectionGeneration: binding.ConnectionGeneration, RunID: f.RunID, AssignmentID: f.AssignmentID, RunTerminalAck: &protocol.RunTerminalAckPayload{}}
			}
			receipts.record(r, binding, frames[0])
			released, err := r.acknowledgeNativeTerminal(binding, ack(frames[0]), receipts)
			if err != nil || released {
				t.Fatal("observational ACK cleared journal", err)
			}
			if reconnect {
				// The previous transport sent positive proof but its ACK was lost.
				receipts.record(r, binding, frames[1])
				oldACK := ack(frames[1])
				binding, err = r.advanceConnectionGeneration(binding)
				if err != nil {
					t.Fatal(err)
				}
				receipts = &nativeTerminalReceipts{}
				released, err = r.acknowledgeNativeTerminal(binding, oldACK, receipts)
				if err != nil || released {
					t.Fatal("old transport ACK cleared reconnect journal", err)
				}
				if binding.ActiveRunConnectionGeneration != 3 || binding.ConnectionGeneration != 4 {
					t.Fatal("reconnect changed assignment generation", binding)
				}
				_, send, prepareErr := r.prepareAssignedRunFrame(binding, frames[0])
				if prepareErr != nil || send {
					t.Fatal("retired unknown observation must not cross current transport", prepareErr)
				}
			}
			proof, send, err := r.prepareAssignedRunFrame(binding, frames[1])
			if err != nil || !send || proof.ConnectionGeneration != 3 {
				t.Fatal("exact native proof lost original assignment fence", err, proof)
			}
			receipts.record(r, binding, proof)
			released, err = r.acknowledgeNativeTerminal(binding, ack(frames[0]), receipts)
			if err != nil || released {
				t.Fatal("delayed observational ACK cleared later proof", err)
			}
			wrong := ack(proof)
			wrong.AssignmentID = "foreign"
			released, err = r.acknowledgeNativeTerminal(binding, wrong, receipts)
			if err != nil || released {
				t.Fatal("foreign assignment ACK cleared journal", err)
			}
			released, err = r.acknowledgeNativeTerminal(binding, ack(proof), receipts)
			if err != nil || !released {
				t.Fatal("exact ACK did not clear native journal", err)
			}
			next := protocol.Frame{RunID: "successor", AssignmentID: "next-assignment"}
			if err = r.activateRun(binding, next); err != nil {
				t.Fatal(err)
			}
			released, err = r.acknowledgeNativeTerminal(binding, ack(proof), receipts)
			if err != nil || released {
				t.Fatal("late predecessor ACK cleared successor", err)
			}
			current, _ := config.BindingFor(&store, binding)
			if current.ActiveRunID != "successor" || current.ActiveRunConnectionGeneration != binding.ConnectionGeneration {
				t.Fatal("successor journal changed", current)
			}
		})
	}
}

func TestNativeCustodySharedGenerationCorpus(t *testing.T) {
	t.Parallel()
	raw, err := os.ReadFile("testdata/native-custody.json")
	if err != nil {
		t.Fatal(err)
	}
	var corpus struct {
		Cases []struct {
			Name                 string         `json:"name"`
			Generation           int64          `json:"transport_generation"`
			NeverStarted         bool           `json:"never_started_expiry"`
			AssignmentGeneration int64          `json:"assignment_generation"`
			Frame                protocol.Frame `json:"frame"`
			Forward              bool           `json:"forward"`
			ACK                  bool           `json:"ack"`
		} `json:"cases"`
	}
	if err = json.Unmarshal(raw, &corpus); err != nil {
		t.Fatal(err)
	}
	for _, tc := range corpus.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			t.Parallel()
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: tc.Generation, ActiveRunConnectionGeneration: tc.AssignmentGeneration, ActiveRunID: "run-1", ActiveAssignmentID: "run-1", ActiveNativeRunID: "native-1"}
			if tc.NeverStarted {
				binding.ActiveNativeRunID = ""
				binding.ActiveRunNotStarted = true
			}
			store := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			r := Runner{Store: &store}
			receipts := &nativeTerminalReceipts{}
			prepared, send, err := r.prepareAssignedRunFrame(binding, tc.Frame)
			if err != nil || send != tc.Forward {
				t.Fatal("wrong transport eligibility", send, err)
			}
			if send {
				receipts.record(r, binding, prepared)
			}
			ack := protocol.Frame{MessageID: tc.Frame.MessageID, MessageType: protocol.FrameTypeRunTerminalAck, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: tc.Generation, RunID: "run-1", AssignmentID: "run-1", RunTerminalAck: &protocol.RunTerminalAckPayload{}}
			released, err := r.acknowledgeNativeTerminal(binding, ack, receipts)
			if err != nil || released != tc.ACK {
				t.Fatal("observational/proof ACK changed journal incorrectly", released, err)
			}
		})
	}
}

func TestLegacyNativeJournalDoesNotInferAssignmentFromLastTransport(t *testing.T) {
	t.Parallel()
	binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 7, ActiveRunID: "run-1", ActiveAssignmentID: "run-1", ActiveNativeRunID: "native-1"}
	store := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
	r := Runner{Store: &store}
	current, err := r.advanceConnectionGeneration(binding)
	if err != nil {
		t.Fatal(err)
	}
	if current.ConnectionGeneration != 8 || current.ActiveRunConnectionGeneration != 0 {
		t.Fatal("last transport was invented as assignment fence", current)
	}
	raw, err := os.ReadFile("testdata/native-custody.json")
	if err != nil {
		t.Fatal(err)
	}
	var corpus struct {
		Observations []protocol.Frame `json:"observations"`
	}
	if err = json.Unmarshal(raw, &corpus); err != nil {
		t.Fatal(err)
	}
	unknown := corpus.Observations[0]
	unknown.ConnectionGeneration = 7
	_, send, err := r.prepareAssignedRunFrame(current, unknown)
	if err != nil || send {
		t.Fatal("unknown original assignment emitted ordinary uncertainty", send, err)
	}
	proof, send, err := r.prepareAssignedRunFrame(current, corpus.Observations[1])
	if err != nil || !send || proof.ConnectionGeneration != 8 {
		t.Fatal("known native proof did not use current authenticated transport", proof, err)
	}
	receipts := &nativeTerminalReceipts{}
	receipts.record(r, current, proof)
	ack := protocol.Frame{MessageID: unknown.MessageID, MessageType: protocol.FrameTypeRunTerminalAck, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 8, RunID: "run-1", AssignmentID: "run-1", RunTerminalAck: &protocol.RunTerminalAckPayload{}}
	released, err := r.acknowledgeNativeTerminal(current, ack, receipts)
	if err != nil || released {
		t.Fatal("legacy uncertainty ACK cleared journal", err)
	}
	ack.MessageID = proof.MessageID
	released, err = r.acknowledgeNativeTerminal(current, ack, receipts)
	if err != nil || !released {
		t.Fatal("legacy exact proof ACK did not release journal", err)
	}
}
