package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/bridge"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

type expiredCustodyAdapter struct {
	runtime.ErrorAdapter
	cancels     chan string
	settle      <-chan struct{}
	cancelError error
}

func (a expiredCustodyAdapter) CancelRun(id string) error {
	a.cancels <- id
	return a.cancelError
}

func (a expiredCustodyAdapter) StreamOrPollRun(ctx context.Context, _ string, _ runtime.RunEventHandler) (runtime.RunResult, error) {
	select {
	case <-ctx.Done():
		return runtime.RunResult{}, ctx.Err()
	case <-a.settle:
		return runtime.RunResult{Status: runtime.RunStatusCancelled}, nil
	}
}

// A deadline is a logical outcome, not proof that the native writer is gone.
// Reconnect must retain custody until actual terminal readback and its ACK.
func TestExpiredAssignedRunRetainsCustodyUntilNativeTerminal(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name            string
		cancelRefused   bool
		liveObservation bool
	}{
		{name: "reconnect cancel accepted"},
		{name: "reconnect cancel refused", cancelRefused: true},
		{name: "live cancel accepted", liveObservation: true},
		{name: "live cancel refused", liveObservation: true, cancelRefused: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
			binding := config.Binding{EnvironmentID: "https://app.example", PersonaID: "persona", ConnectionID: "connection", ConnectionGeneration: 3, ActiveRunID: "old-run", ActiveAssignmentID: "old-assignment", ActiveNativeRunID: "old-native", ActiveRunDeadlineAt: now}
			store := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
			runner := Runner{Store: &store, Now: func() time.Time { return now }}
			settle := make(chan struct{})
			adapter := expiredCustodyAdapter{cancels: make(chan string, 1), settle: settle}
			if tc.cancelRefused {
				adapter.cancelError = errors.New("native cancellation refused")
			}
			frames := make(chan externalagentprotocol.Frame, 2)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			writeFrame := func(frame externalagentprotocol.Frame) error {
				frames <- frame
				return nil
			}
			var err error
			if tc.liveObservation {
				request := externalagentprotocol.Frame{RunID: binding.ActiveRunID, AssignmentID: binding.ActiveAssignmentID}
				runner.observeActiveRun(ctx, binding, bridge.Session{Binding: binding}, adapter, request, binding.ActiveNativeRunID, time.Unix(1, 0), newRunObservationRegistry(), writeFrame)
			} else {
				err = runner.replayActiveRun(ctx, binding, bridge.Session{Binding: binding}, adapter, newRunObservationRegistry(), writeFrame)
			}
			if err != nil {
				t.Fatal(err)
			}
			expired := awaitCustodyFrame(t, frames)
			if expired.RunTerminal == nil || expired.RunTerminal.Reason != externalagentprotocol.TerminalReasonExpired || expired.RunTerminal.ErrorCode != nativeTerminationUnconfirmed || expired.RunTerminal.NativeRunID != "old-native" {
				t.Fatalf("deadline fabricated native termination: %+v", expired)
			}
			select {
			case id := <-adapter.cancels:
				if id != "old-native" {
					t.Fatal("cancel targeted another native writer", id)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("expired native run did not receive cancellation")
			}
			current, _ := config.BindingFor(&store, binding)
			if current.ActiveRunID != binding.ActiveRunID || current.ActiveNativeRunID != binding.ActiveNativeRunID || current.ActiveRunDeadlineAt != binding.ActiveRunDeadlineAt {
				t.Fatal("deadline or cancellation acknowledgement discarded custody", current)
			}
			fresh := externalagentprotocol.Frame{RunID: "fresh", AssignmentID: "fresh-assignment"}
			if owner, conflict := runner.activeRunConflict(binding, fresh); !conflict || owner != binding.ActiveRunID {
				t.Fatal("new assignment bypassed unconfirmed native writer")
			}
			close(settle)
			terminal := awaitCustodyFrame(t, frames)
			if terminal.MessageType != externalagentprotocol.FrameTypeRunCancelled || terminal.RunID != binding.ActiveRunID || terminal.AssignmentID != binding.ActiveAssignmentID || terminal.RunTerminal == nil || terminal.RunTerminal.NativeRunID != binding.ActiveNativeRunID {
				t.Fatalf("did not observe physical settlement after logical expiry: %+v", terminal)
			}
			current, _ = config.BindingFor(&store, binding)
			if current.ActiveRunID != binding.ActiveRunID {
				t.Fatal("native terminal released custody before acknowledgement")
			}
			// The existing authenticated terminal ACK owns journal release.
			err = runner.clearRunState(binding, terminal.RunID)
			if err != nil {
				t.Fatal(err)
			}
			if _, conflict := runner.activeRunConflict(binding, fresh); conflict {
				t.Fatal("settled writer blocked the next assignment")
			}
		})
	}
}

func awaitCustodyFrame(t *testing.T, frames <-chan externalagentprotocol.Frame) externalagentprotocol.Frame {
	t.Helper()
	select {
	case frame := <-frames:
		return frame
	case <-time.After(2 * time.Second):
		t.Fatal("native observation did not publish a bounded test result")
		return externalagentprotocol.Frame{}
	}
}

func TestExpiredAssignedRunFailedReportKeepsJournal(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	binding := config.Binding{EnvironmentID: "https://app.example", ConnectionID: "connection", ConnectionGeneration: 1, ActiveRunID: "old", ActiveAssignmentID: "assignment", ActiveNativeRunID: "native", ActiveRunDeadlineAt: now}
	store := config.NewMemoryStore(config.State{Bindings: []config.Binding{binding}})
	runner := Runner{Store: &store, Now: func() time.Time { return now }}
	err := runner.replayActiveRun(t.Context(), binding, bridge.Session{Binding: binding}, nil, nil, func(externalagentprotocol.Frame) error { return errors.New("gateway unavailable") })
	if err == nil {
		t.Fatal("lost expiry report claimed success")
	}
	current, _ := config.BindingFor(&store, binding)
	if current.ActiveRunID != binding.ActiveRunID || current.ActiveNativeRunID != binding.ActiveNativeRunID {
		t.Fatal("lost expiry report discarded custody")
	}
}
