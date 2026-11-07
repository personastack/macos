package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	protocol "github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/bridge"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

type nativeDeadlineSubmissionStore struct {
	*config.MemoryStore
	writes          atomic.Int32
	afterActivation func()
}

func (s *nativeDeadlineSubmissionStore) UpdateBinding(key config.BindingKey, change func(*config.Binding) error) error {
	activated := false
	err := s.MemoryStore.UpdateBinding(key, func(b *config.Binding) error {
		before := b.ActiveRunID
		if err := change(b); err != nil {
			return err
		}
		activated = before == "" && b.ActiveRunID != ""
		return nil
	})
	if err == nil {
		s.writes.Add(1)
		if activated && s.afterActivation != nil {
			s.afterActivation()
		}
	}
	return err
}

type nativeDeadlineSubmissionAdapter struct {
	runtime.ErrorAdapter
	starts  atomic.Int32
	polls   atomic.Int32
	cancels atomic.Int32
}

func (a *nativeDeadlineSubmissionAdapter) StartRun(runtime.RunRequest) (string, error) {
	a.starts.Add(1)
	return "native-1", nil
}
func (a *nativeDeadlineSubmissionAdapter) CancelRun(string) error { a.cancels.Add(1); return nil }
func (a *nativeDeadlineSubmissionAdapter) StreamOrPollRun(context.Context, string, runtime.RunEventHandler) (runtime.RunResult, error) {
	a.polls.Add(1)
	return runtime.RunResult{Status: runtime.RunStatusCancelled}, nil
}

func TestNativeRunStartCommandChecksOriginalDeadlineBeforeSubmission(t *testing.T) {
	t.Parallel()
	for _, phase := range []string{"first delivery", "activation crosses deadline"} {
		for _, offset := range []time.Duration{-time.Nanosecond, 0, time.Nanosecond} {
			t.Run(phase+"/"+offset.String(), func(t *testing.T) {
				t.Parallel()
				deadline := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
				now := deadline.Add(offset)
				if phase == "activation crosses deadline" {
					now = deadline.Add(-time.Second)
				}
				binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3}
				memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
				store := &nativeDeadlineSubmissionStore{MemoryStore: &memory}
				if phase == "activation crosses deadline" {
					store.afterActivation = func() { now = deadline.Add(offset) }
				}
				r := Runner{Store: store, Now: func() time.Time { return now }}
				session := bridge.Session{Binding: binding}
				adapter := &nativeDeadlineSubmissionAdapter{}
				cache := newCommandFrameCache()
				request := protocol.Frame{MessageID: "start-message", MessageType: protocol.FrameTypeRunStart, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "assignment-1", RunStart: &protocol.RunStartPayload{DeadlineAt: deadline, FullyComposedPrompt: "request"}}
				if _, replayed := r.runStartReplayReplies(binding, request, session, cache); replayed {
					t.Fatal("fresh command was treated as retained native work")
				}
				native, failure, submitErr := r.submitNativeRunCommand(t.Context(), binding, session, adapter, request)
				if submitErr != nil {
					t.Fatal(submitErr)
				}
				current, _ := config.BindingFor(store, binding)
				if offset < 0 {
					if failure != nil || native != "native-1" || adapter.starts.Load() != 1 || !current.ActiveRunDeadlineAt.Equal(deadline) {
						t.Fatal("before-boundary command lost original submission", failure, native, current)
					}
					return
				}
				if native != "" || failure == nil || adapter.starts.Load() != 0 {
					t.Fatal("expired first delivery entered native StartRun", native, failure, adapter.starts.Load())
				}
				if failure.MessageID != request.MessageID || failure.RunID != request.RunID || failure.AssignmentID != request.AssignmentID || failure.RunTerminal == nil || failure.RunTerminal.ErrorCode != nativeNotStarted || failure.RunTerminal.NativeRunID != "" || failure.RunTerminal.Reason != protocol.TerminalReasonExpired {
					t.Fatal("deadline rejection lost exact non-submission evidence", failure)
				}
				cache.storeReply(request, *failure)
				replies, replayed := r.runStartReplayReplies(binding, request, session, cache)
				if !replayed || len(replies) != 1 || replies[0].MessageID != request.MessageID || adapter.starts.Load() != 0 {
					t.Fatal("expired duplicate command changed rejection or resubmitted")
				}
				if phase == "first delivery" {
					if store.writes.Load() != 1 || current.ActiveRunID != "run-1" || !current.ActiveRunNotStarted {
						t.Fatal("expired command changed native journal", current)
					}
				} else {
					if store.writes.Load() != 2 || current.ActiveRunID != "run-1" || !current.ActiveRunNotStarted || !current.ActiveRunDeadlineAt.Equal(deadline) {
						t.Fatal("activation delay renewed deadline or lost exact run", current)
					}
					receipts := &nativeTerminalReceipts{}
					receipts.record(r, binding, *failure)
					ack := protocol.Frame{MessageID: failure.MessageID, MessageType: protocol.FrameTypeRunTerminalAck, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "assignment-1", RunTerminalAck: &protocol.RunTerminalAckPayload{}}
					released, err := r.acknowledgeNativeTerminal(binding, ack, receipts)
					if err != nil || !released {
						t.Fatal("exact never-submitted ACK could not settle activated journal", err)
					}
				}
			})
		}
	}
}

func TestNativeExpiredRetainedHandleObservesProofInsteadOfNewSubmission(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	deadline := now.Add(-time.Minute)
	binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3, ActiveRunConnectionGeneration: 3, ActiveRunID: "run-1", ActiveAssignmentID: "assignment-1", ActiveNativeRunID: "native-1", ActiveRunDeadlineAt: deadline}
	memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
	r := Runner{Store: &memory, Now: func() time.Time { return now }}
	session := bridge.Session{Binding: binding}
	adapter := &nativeDeadlineSubmissionAdapter{}
	request := protocol.Frame{MessageID: "redelivery", MessageType: protocol.FrameTypeRunStart, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "assignment-1", RunStart: &protocol.RunStartPayload{DeadlineAt: deadline}}
	replies, replayed := r.runStartReplayReplies(binding, request, session, newCommandFrameCache())
	if !replayed || len(replies) != 2 || replies[0].RunAccepted == nil || replies[1].RunStarted == nil || adapter.starts.Load() != 0 {
		t.Fatal("expired retained assignment lost replay authority")
	}
	frames := make(chan protocol.Frame, 4)
	receipts := &nativeTerminalReceipts{}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	if err := r.replayActiveRun(ctx, binding, session, adapter, newRunObservationRegistry(), func(frame protocol.Frame) error {
		prepared, send, err := r.prepareAssignedRunFrame(binding, frame)
		if err == nil && send {
			receipts.record(r, binding, prepared)
			frames <- prepared
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	var proof protocol.Frame
	for proof.RunTerminal == nil {
		select {
		case f := <-frames:
			if f.RunTerminal == nil {
				continue
			}
			if f.RunTerminal.ErrorCode == nativeNotStarted {
				t.Fatal("existing native handle misclassified as never submitted")
			}
			if nativeTerminalProof(f) {
				proof = f
			}
		case <-time.After(2 * time.Second):
			t.Fatal("retained native writer lost physical proof observation")
		}
	}
	current, _ := config.BindingFor(&memory, binding)
	if current.ActiveRunID != "run-1" || !current.ActiveRunDeadlineAt.Equal(deadline) || adapter.starts.Load() != 0 || adapter.cancels.Load() != 1 || adapter.polls.Load() != 1 {
		t.Fatal("expiry changed deadline, resubmitted, or discarded native custody", current)
	}
	ack := protocol.Frame{MessageID: proof.MessageID, MessageType: protocol.FrameTypeRunTerminalAck, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "assignment-1", RunTerminalAck: &protocol.RunTerminalAckPayload{}}
	released, err := r.acknowledgeNativeTerminal(binding, ack, receipts)
	if err != nil || !released {
		t.Fatal("exact retained physical proof did not release journal", err)
	}
	fresh := request
	fresh.MessageID = "fresh-message"
	fresh.RunID = "successor"
	fresh.AssignmentID = "next"
	fresh.RunStart = &protocol.RunStartPayload{DeadlineAt: now.Add(time.Minute)}
	if _, failure, err := r.submitNativeRunCommand(t.Context(), binding, session, adapter, fresh); failure != nil || err != nil || adapter.starts.Load() != 1 {
		t.Fatal("fresh permitted intent did not launch after safe proof", failure)
	}
	released, err = r.acknowledgeNativeTerminal(binding, ack, receipts)
	if err != nil || released {
		t.Fatal("late old proof ACK released successor", err)
	}
}

func TestNativeRunStartMissingDeadlineNeverSubmits(t *testing.T) {
	t.Parallel()
	for _, payload := range []*protocol.RunStartPayload{nil, {}} {
		t.Run(map[bool]string{true: "missing payload", false: "missing deadline"}[payload == nil], func(t *testing.T) {
			t.Parallel()
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3}
			memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			store := &nativeDeadlineSubmissionStore{MemoryStore: &memory}
			adapter := &nativeDeadlineSubmissionAdapter{}
			r := Runner{Store: store}
			request := protocol.Frame{MessageID: "message", RunID: "run-1", AssignmentID: "assignment-1", RunStart: payload}
			_, failure, submitErr := r.submitNativeRunCommand(t.Context(), binding, bridge.Session{Binding: binding}, adapter, request)
			if submitErr != nil {
				t.Fatal(submitErr)
			}
			if failure == nil || failure.RunTerminal == nil || failure.RunTerminal.ErrorCode != nativeNotStarted || failure.MessageID != "message" || adapter.starts.Load() != 0 || store.writes.Load() != 1 {
				t.Fatal("missing original deadline entered native effect", failure)
			}
		})
	}
}

func TestNativeNeverStartedProofSurvivesLostFrameAndACKReconnect(t *testing.T) {
	t.Parallel()
	for _, phase := range []string{"before activation", "activation crosses deadline"} {
		t.Run(phase, func(t *testing.T) {
			t.Parallel()
			deadline := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
			now := deadline
			if phase == "activation crosses deadline" {
				now = deadline.Add(-time.Second)
			}
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3}
			memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			store := &nativeDeadlineSubmissionStore{MemoryStore: &memory}
			if phase == "activation crosses deadline" {
				store.afterActivation = func() { now = deadline }
			}
			r := Runner{Store: store, Now: func() time.Time { return now }}
			session := bridge.Session{Binding: binding}
			adapter := &nativeDeadlineSubmissionAdapter{}
			request := protocol.Frame{MessageID: "lost-first-proof", MessageType: protocol.FrameTypeRunStart, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "assignment-1", RunStart: &protocol.RunStartPayload{DeadlineAt: deadline}}
			_, failure, err := r.submitNativeRunCommand(t.Context(), binding, session, adapter, request)
			if err != nil || failure == nil || adapter.starts.Load() != 0 {
				t.Fatal("deadline rejection did not retain affirmative fact", failure, err)
			}
			// Drop the first frame. Reload the persisted binding representation before
			// real transport generation advance, not an in-memory command cache replay.
			encoded, err := json.Marshal(store.ListBindings())
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
			if !current.ActiveRunNotStarted || current.ActiveRunConnectionGeneration != 3 {
				t.Fatal("reconnect lost affirmative non-submission or original fence", current)
			}
			replay := func(b config.Binding) (protocol.Frame, *nativeTerminalReceipts) {
				t.Helper()
				if !r.canReplayNeverStartedNative(b) {
					t.Fatal("affirmative proof remained behind target/readiness reconciliation")
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
				if err != nil || proof.RunTerminal == nil || proof.RunTerminal.ErrorCode != nativeNotStarted || proof.RunTerminal.NativeRunID != "" || proof.ConnectionGeneration != 3 {
					t.Fatal("durable no-start replay lost positive exact proof", proof, err)
				}
				return proof, receipts
			}
			proof4, _ := replay(current) // API may commit this proof while its ACK is lost.
			current, err = r.advanceConnectionGeneration(current)
			if err != nil {
				t.Fatal(err)
			}
			proof5, receipts := replay(current)
			if proof4.MessageID == proof5.MessageID {
				t.Fatal("new transport reused stale proof ACK identity")
			}
			ack := protocol.Frame{MessageID: proof4.MessageID, MessageType: protocol.FrameTypeRunTerminalAck, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 4, RunID: "run-1", AssignmentID: "assignment-1", RunTerminalAck: &protocol.RunTerminalAckPayload{}}
			if released, err := r.acknowledgeNativeTerminal(current, ack, receipts); err != nil || released {
				t.Fatal("lost old transport ACK cleared current journal", err)
			}
			ack.MessageID, ack.ConnectionGeneration = proof5.MessageID, current.ConnectionGeneration
			released, err := r.acknowledgeNativeTerminal(current, ack, receipts)
			if err != nil || !released {
				t.Fatal("current exact proof ACK did not settle durable no-start", err)
			}
			settled, _ := config.BindingFor(&memory, current)
			if settled.ActiveRunNotStarted || settled.ActiveRunID != "" || adapter.starts.Load() != 0 || adapter.polls.Load() != 0 || adapter.cancels.Load() != 0 {
				t.Fatal("no-start proof polled/launched native work or kept stale journal", settled)
			}
			fresh := request
			fresh.MessageID = "fresh"
			fresh.ConnectionGeneration = current.ConnectionGeneration
			fresh.RunID = "successor"
			fresh.AssignmentID = "next"
			fresh.RunStart = &protocol.RunStartPayload{DeadlineAt: deadline.Add(time.Minute)}
			if _, failure, err := r.submitNativeRunCommand(t.Context(), current, bridge.Session{Binding: current}, adapter, fresh); err != nil || failure != nil || adapter.starts.Load() != 1 {
				t.Fatal("fresh intent failed after exact proof", failure, err)
			}
			if released, err := r.acknowledgeNativeTerminal(current, ack, receipts); err != nil || released {
				t.Fatal("old no-start proof ACK released successor", err)
			}
		})
	}
}

func TestNativeDeadlineProofCannotReplaceExistingJournal(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"known native", "sibling", "legacy unknown"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			now := time.Now().UTC()
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3, ActiveRunID: "run-1", ActiveAssignmentID: "assignment-1", ActiveRunConnectionGeneration: 3, ActiveNativeRunID: "native-existing"}
			if kind == "sibling" {
				binding.ActiveRunID = "sibling"
			}
			if kind == "legacy unknown" {
				binding.ActiveNativeRunID = ""
				binding.ActiveRunConnectionGeneration = 0
			}
			memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			r := Runner{Store: &memory, Now: func() time.Time { return now }}
			adapter := &nativeDeadlineSubmissionAdapter{}
			request := protocol.Frame{RunID: "run-1", AssignmentID: "assignment-1", RunStart: &protocol.RunStartPayload{DeadlineAt: now}}
			_, _, err := r.submitNativeRunCommand(t.Context(), binding, bridge.Session{Binding: binding}, adapter, request)
			current, _ := config.BindingFor(&memory, binding)
			if err == nil || current.ActiveRunID != binding.ActiveRunID || current.ActiveNativeRunID != binding.ActiveNativeRunID || current.ActiveRunNotStarted || adapter.starts.Load() != 0 {
				t.Fatal("expiry invented no-start proof for retained native/unknown/sibling", current, err)
			}
		})
	}
}

func TestNativeContradictoryNoStartJournalObservesKnownHandle(t *testing.T) {
	t.Parallel()
	now := time.Now().UTC()
	binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3, ActiveRunConnectionGeneration: 3, ActiveRunID: "run-1", ActiveAssignmentID: "assignment-1", ActiveNativeRunID: "native-1", ActiveRunNotStarted: true, ActiveRunDeadlineAt: now.Add(-time.Minute)}
	memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
	r := Runner{Store: &memory, Now: func() time.Time { return now }}
	adapter := &nativeDeadlineSubmissionAdapter{}
	session := bridge.Session{Binding: binding}
	request := protocol.Frame{MessageID: "command", MessageType: protocol.FrameTypeRunStart, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "assignment-1", RunStart: &protocol.RunStartPayload{DeadlineAt: binding.ActiveRunDeadlineAt}}
	replies, replayed := r.runStartReplayReplies(binding, request, session, newCommandFrameCache())
	if !replayed || len(replies) != 2 || replies[0].RunAccepted == nil {
		t.Fatal("contradictory no-start flag displaced known native identity", replies)
	}
	if err := r.recordNativeRunID(binding, "run-1", "native-1"); err != nil {
		t.Fatal(err)
	}
	current, _ := config.BindingFor(&memory, binding)
	if current.ActiveRunNotStarted {
		t.Fatal("known native record retained contradictory no-start flag")
	}
	frames := make(chan protocol.Frame, 4)
	if err := r.replayActiveRun(t.Context(), binding, session, adapter, newRunObservationRegistry(), func(f protocol.Frame) error { frames <- f; return nil }); err != nil {
		t.Fatal(err)
	}
	for {
		select {
		case f := <-frames:
			if f.RunTerminal != nil && f.RunTerminal.ErrorCode == nativeNotStarted {
				t.Fatal("contradictory flag became affirmative no-start proof")
			}
			if nativeTerminalProof(f) {
				if adapter.starts.Load() != 0 || adapter.polls.Load() != 1 || adapter.cancels.Load() != 1 {
					t.Fatal("known native custody did not use exact observation")
				}
				return
			}
		case <-time.After(2 * time.Second):
			t.Fatal("known native custody lost observer")
		}
	}
}

func TestNativeActivationWriteFailureRetainsNeverStartedProofAcrossReconnect(t *testing.T) {
	t.Parallel()
	now := time.Now().UTC()
	deadline := now.Add(time.Minute)
	binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3}
	memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
	store := &failNativeJournalOnceStore{MemoryStore: &memory}
	store.fail.Store(true)
	r := Runner{Store: store, Now: func() time.Time { return now }}
	adapter := &nativeDeadlineSubmissionAdapter{}
	request := protocol.Frame{MessageID: "first", MessageType: protocol.FrameTypeRunStart, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 3, RunID: "run-1", AssignmentID: "assignment-1", RunStart: &protocol.RunStartPayload{DeadlineAt: deadline}}
	_, failure, err := r.submitNativeRunCommand(t.Context(), binding, bridge.Session{Binding: binding}, adapter, request)
	if err != nil || failure == nil || failure.RunTerminal == nil || failure.RunTerminal.ErrorCode != nativeNotStarted || failure.RunTerminal.Reason != protocol.TerminalReasonFailed || failure.RunTerminal.FinalMessage != "one-time journal write failure" || adapter.starts.Load() != 0 {
		t.Fatal("activation write failure lost exact non-submission cause", failure, err)
	}
	encoded, err := json.Marshal(store.ListBindings())
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
	var proof protocol.Frame
	receipts := &nativeTerminalReceipts{}
	err = r.replayActiveRun(t.Context(), current, bridge.Session{Binding: current}, nil, newRunObservationRegistry(), func(f protocol.Frame) error {
		prepared, send, err := r.prepareAssignedRunFrame(current, f)
		if err == nil && send {
			proof = prepared
			receipts.record(r, current, proof)
		}
		return err
	})
	if err != nil || proof.RunTerminal == nil || proof.RunTerminal.ErrorCode != nativeNotStarted || proof.RunTerminal.Reason != protocol.TerminalReasonFailed || proof.RunTerminal.NativeRunID != "" || proof.ConnectionGeneration != 3 || proof.RunTerminal.FinalMessage != "external agent native run did not start: run-1" {
		t.Fatal("reconnect invented expiry or lost durable no-start fact", proof, err)
	}
	ack := protocol.Frame{MessageID: proof.MessageID, MessageType: protocol.FrameTypeRunTerminalAck, ConnectionID: "conn-1", PersonaID: "persona-1", ConnectionGeneration: 4, RunID: "run-1", AssignmentID: "assignment-1", RunTerminalAck: &protocol.RunTerminalAckPayload{}}
	released, err := r.acknowledgeNativeTerminal(current, ack, receipts)
	if err != nil || !released {
		t.Fatal("exact no-start ACK did not clear recovered journal", err)
	}
	fresh := request
	fresh.MessageID = "fresh"
	fresh.ConnectionGeneration = 4
	fresh.RunID = "successor"
	fresh.AssignmentID = "next"
	if _, failure, err := r.submitNativeRunCommand(t.Context(), current, bridge.Session{Binding: current}, adapter, fresh); err != nil || failure != nil || adapter.starts.Load() != 1 {
		t.Fatal("fresh intent failed after recovered no-start proof", failure, err)
	}
}

type unavailableNativeSubmissionStore struct {
	*config.MemoryStore
	attempts atomic.Int32
}

func (s *unavailableNativeSubmissionStore) UpdateBinding(config.BindingKey, func(*config.Binding) error) error {
	s.attempts.Add(1)
	return errors.New("native journal storage unavailable")
}
func TestNativeActivationPersistentWriteFailureIsBoundedDependency(t *testing.T) {
	t.Parallel()
	binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona-1", ConnectionID: "conn-1", ConnectionGeneration: 3}
	memory := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
	store := &unavailableNativeSubmissionStore{MemoryStore: &memory}
	r := Runner{Store: store}
	adapter := &nativeDeadlineSubmissionAdapter{}
	request := protocol.Frame{RunID: "run-1", AssignmentID: "assignment-1", RunStart: &protocol.RunStartPayload{DeadlineAt: time.Now().Add(time.Minute)}}
	_, failure, err := r.submitNativeRunCommand(t.Context(), binding, bridge.Session{Binding: binding}, adapter, request)
	current, _ := config.BindingFor(store, binding)
	if err == nil || failure != nil || adapter.starts.Load() != 0 || store.attempts.Load() != 3 || current.ActiveRunNotStarted || current.ActiveRunID != "" {
		t.Fatal("unavailable storage invented durable proof or retried without bound", failure, err, store.attempts.Load(), current)
	}
}
