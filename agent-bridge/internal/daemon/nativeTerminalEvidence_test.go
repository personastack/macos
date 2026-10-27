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

type terminalEvidenceAdapter struct {
	runtime.ErrorAdapter
	result runtime.RunResult
	err    error
	wait   bool
}

func (a terminalEvidenceAdapter) StreamOrPollRun(ctx context.Context, _ string, _ runtime.RunEventHandler) (runtime.RunResult, error) {
	if a.wait {
		<-ctx.Done()
		return runtime.RunResult{}, ctx.Err()
	}
	return a.result, a.err
}

func (terminalEvidenceAdapter) CancelRun(string) error { return nil }

func TestObservedNativeTerminalEvidence(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name     string
		adapter  terminalEvidenceAdapter
		deadline time.Time
		typeName externalagentprotocol.FrameType
		code     string
	}{
		{name: "transport failure", adapter: terminalEvidenceAdapter{err: errors.New("observation failed")}, typeName: externalagentprotocol.FrameTypeRunFailed, code: nativeTerminationUnconfirmed},
		{name: "deadline", adapter: terminalEvidenceAdapter{wait: true}, deadline: time.Now().Add(-time.Second), typeName: externalagentprotocol.FrameTypeRunFailed, code: nativeTerminationUnconfirmed},
		{name: "native failure", adapter: terminalEvidenceAdapter{result: runtime.RunResult{Status: runtime.RunStatusFailed}}, typeName: externalagentprotocol.FrameTypeRunFailed, code: nativeTerminationConfirmed},
		{name: "native cancellation", adapter: terminalEvidenceAdapter{result: runtime.RunResult{Status: runtime.RunStatusCancelled}}, typeName: externalagentprotocol.FrameTypeRunCancelled},
		{name: "native success", adapter: terminalEvidenceAdapter{result: runtime.RunResult{Status: runtime.RunStatusSucceeded}}, typeName: externalagentprotocol.FrameTypeRunCompleted},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			binding := config.Binding{ConnectionID: "connection", PersonaID: "persona", ConnectionGeneration: 1}
			session := bridge.Session{Binding: binding}
			request := externalagentprotocol.Frame{RunID: "run", AssignmentID: "assignment"}
			var got []externalagentprotocol.Frame
			Runner{}.observeActiveRun(t.Context(), binding, session, tc.adapter, request, "native", tc.deadline, nil, func(frame externalagentprotocol.Frame) error {
				got = append(got, frame)
				return nil
			})
			if len(got) != 1 || got[0].MessageType != tc.typeName || got[0].RunID != "run" || got[0].AssignmentID != "assignment" || got[0].RunTerminal == nil || got[0].RunTerminal.ErrorCode != tc.code {
				t.Fatalf("terminal = %+v", got)
			}
		})
	}
}

func TestNativeTerminalWithoutStartProof(t *testing.T) {
	t.Parallel()
	session := bridge.Session{Binding: config.Binding{ConnectionID: "connection", PersonaID: "persona", ConnectionGeneration: 1}}
	frame := externalagentprotocol.Frame{RunID: "run", AssignmentID: "assignment"}
	known := nativeRunNotStartedFailure(session, frame, "not ready")
	unknown := unconfirmedNativeRunFailure(session, frame, externalagentprotocol.TerminalReasonFailed, "ambiguous", "native")
	if known.RunTerminal.ErrorCode != nativeNotStarted || unknown.RunTerminal.ErrorCode != nativeTerminationUnconfirmed || unknown.RunTerminal.NativeRunID != "native" {
		t.Fatalf("incorrect termination evidence: known=%+v unknown=%+v", known.RunTerminal, unknown.RunTerminal)
	}
}
