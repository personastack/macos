package daemon

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	protocol "github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/bridge"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

type retryNativeObservationAdapter struct {
	runtime.ErrorAdapter
	t        *testing.T
	calls    atomic.Int32
	starts   atomic.Int32
	cancels  atomic.Int32
	deadline time.Time
}

func (a *retryNativeObservationAdapter) StartRun(runtime.RunRequest) (string, error) {
	a.starts.Add(1)
	a.t.Error("observer resubmitted native run")
	return "", errors.New("unplanned submit")
}
func (a *retryNativeObservationAdapter) CancelRun(id string) error {
	if id != "native-1" {
		a.t.Error("cancel escaped known native handle")
	}
	a.cancels.Add(1)
	return nil
}
func (a *retryNativeObservationAdapter) StreamOrPollRun(ctx context.Context, id string, handle runtime.RunEventHandler) (runtime.RunResult, error) {
	if id != "native-1" {
		a.t.Error("observer changed native handle")
	}
	if deadline, ok := ctx.Deadline(); ok && !deadline.Equal(a.deadline) {
		a.t.Errorf("deadline renewed: got %s want %s", deadline, a.deadline)
	}
	if a.calls.Add(1) == 1 {
		return runtime.RunResult{}, errors.New("temporary adapter read failure")
	}
	if handle != nil {
		for _, event := range []runtime.RunEvent{{Kind: runtime.RunEventOutputDelta, Delta: "late output after logical failure"}, {Kind: runtime.RunEventToolEvent, ToolName: "late tool", ToolPhase: "running"}, {Kind: runtime.RunEventStarted, StartedAt: time.Now()}} {
			if err := handle(event); err != nil {
				return runtime.RunResult{}, err
			}
		}
	}
	return runtime.RunResult{Status: runtime.RunStatusSucceeded, Output: "native success after logical failure"}, nil
}

type failNativeJournalOnceStore struct {
	*config.MemoryStore
	fail atomic.Bool
}

func (s *failNativeJournalOnceStore) UpdateBinding(key config.BindingKey, change func(*config.Binding) error) error {
	if s.fail.CompareAndSwap(true, false) {
		return errors.New("one-time journal write failure")
	}
	return s.MemoryStore.UpdateBinding(key, change)
}

func TestNativeObserverReadFailureKeepsExistingHandleUntilProof(t *testing.T) {
	t.Parallel()
	for _, owner := range []string{"live", "replay", "post-expiry", "native-ID journal write fails once"} {
		t.Run(owner, func(t *testing.T) {
			t.Parallel()
			deadline := time.Now().UTC().Add(time.Minute)
			if owner == "post-expiry" {
				deadline = time.Now().UTC().Add(-time.Minute)
			}
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3, ActiveRunConnectionGeneration: 3, ActiveRunID: "run-1", ActiveAssignmentID: "run-1", ActiveNativeRunID: "native-1", ActiveRunDeadlineAt: deadline}
			if owner == "native-ID journal write fails once" {
				binding.ActiveNativeRunID = ""
			}
			memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			store := &failNativeJournalOnceStore{MemoryStore: &memory}
			r := Runner{Store: store, ReconnectMin: time.Millisecond}
			session := bridge.Session{Binding: binding}
			adapter := &retryNativeObservationAdapter{t: t, deadline: deadline}
			receipts := &nativeTerminalReceipts{}
			observations := newRunObservationRegistry()
			frames := make(chan protocol.Frame, 8)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			request := protocol.Frame{MessageID: "initial-message", RunID: "run-1", AssignmentID: "run-1", ConnectionGeneration: 3, RunStart: &protocol.RunStartPayload{DeadlineAt: deadline}}
			write := func(frame protocol.Frame) error {
				prepared, send, err := r.prepareAssignedRunFrame(binding, frame)
				if err != nil {
					return err
				}
				if send {
					receipts.record(r, binding, prepared)
					frames <- prepared
				}
				return nil
			}
			switch owner {
			case "live":
				go r.observeAssignedNativeRun(ctx, binding, session, adapter, request, "native-1", deadline, observations, write, func(event runtime.RunEvent) error { return write(session.RunOutputDeltaFrame(request, event.Delta)) })
			case "replay", "post-expiry":
				if err := r.replayActiveRun(ctx, binding, session, adapter, observations, write); err != nil {
					t.Fatal(err)
				}
			default:
				store.fail.Store(true)
				recordErr := r.recordNativeRunID(binding, "run-1", "native-1")
				if recordErr == nil {
					t.Fatal("journal failure fixture did not fail")
				}
				if err := r.observeNativeRunAfterJournalFailure(ctx, binding, session, adapter, request, "native-1", recordErr, observations, newCommandFrameCache(), write); err != nil {
					t.Fatal(err)
				}
			}
			var proof protocol.Frame
			unknown := false
			for proof.RunTerminal == nil {
				select {
				case frame := <-frames:
					if frame.RunTerminal == nil {
						if unknown || frame.MessageType == protocol.FrameTypeRunOutputDelta || frame.MessageType == protocol.FrameTypeRunToolEvent {
							t.Fatal("physical readback published output after logical failure")
						}
						continue
					}
					if !nativeTerminalProof(frame) {
						unknown = true
						current, _ := config.BindingFor(store, binding)
						if current.ActiveRunID != "run-1" || !current.ActiveRunDeadlineAt.Equal(deadline) {
							t.Fatal("read failure discarded custody or changed deadline", current)
						}
						if _, busy := r.activeRunConflict(binding, protocol.Frame{RunID: "successor", AssignmentID: "next"}); !busy {
							t.Fatal("unknown observation admitted successor")
						}
						continue
					}
					proof = frame
				case <-time.After(2 * time.Second):
					t.Fatal("healthy session stopped observing after transient failure")
				}
			}
			expectedCause := "temporary adapter read failure"
			if owner == "post-expiry" {
				expectedCause = "external agent run deadline exceeded; native termination is not confirmed"
			}
			if owner == "native-ID journal write fails once" {
				expectedCause = "one-time journal write failure"
			}
			if proof.RunTerminal.FinalMessage != expectedCause {
				t.Fatal("terminal proof lost first logical failure cause", proof.RunTerminal.FinalMessage, expectedCause)
			}
			if proof.MessageType == protocol.FrameTypeRunCompleted || proof.RunTerminal.FinalMessage == "native success after logical failure" {
				t.Fatal("physical proof republished success after logical failure", proof)
			}
			if !unknown || adapter.calls.Load() < 2 || adapter.starts.Load() != 0 {
				t.Fatal("known-handle retry contract lost", unknown, adapter.calls.Load(), adapter.starts.Load())
			}
			current, _ := config.BindingFor(store, binding)
			if current.ActiveNativeRunID != "native-1" || !current.ActiveRunDeadlineAt.Equal(deadline) {
				t.Fatal("retry lost native journal/original deadline", current)
			}
			ack := protocol.Frame{MessageID: proof.MessageID, MessageType: protocol.FrameTypeRunTerminalAck, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "run-1", RunTerminalAck: &protocol.RunTerminalAckPayload{}}
			released, err := r.acknowledgeNativeTerminal(binding, ack, receipts)
			if err != nil || !released {
				t.Fatal("exact terminal proof ACK did not release journal", err)
			}
			observations.cancel("run-1")
			if _, busy := r.activeRunConflict(binding, protocol.Frame{RunID: "successor", AssignmentID: "next"}); busy {
				t.Fatal("terminal proof blocked fresh admission")
			}
			if err = r.activateRun(binding, protocol.Frame{RunID: "successor", AssignmentID: "next"}); err != nil {
				t.Fatal(err)
			}
			released, err = r.acknowledgeNativeTerminal(binding, ack, receipts)
			if err != nil || released {
				t.Fatal("late old ACK released successor", err)
			}
		})
	}
}
