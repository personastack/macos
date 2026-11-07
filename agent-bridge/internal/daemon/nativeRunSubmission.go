package daemon

import (
	"context"
	"fmt"
	"time"

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/bridge"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

// The authenticated run.start command reaches this effect boundary only after
// retained-run replay, current binding, target and readiness checks. Activation
// may block on local persistence, so recheck the original deadline after it.
func (r Runner) submitNativeRunCommand(ctx context.Context, binding config.Binding, session bridge.Session, adapter runtime.Adapter, frame externalagentprotocol.Frame) (string, *externalagentprotocol.Frame, error) {
	if failure := r.nativeSubmissionDeadlineFailure(session, frame); failure != nil {
		return r.persistNativeNonSubmissionProof(ctx, binding, frame, failure)
	}
	if err := r.activateRun(binding, frame); err != nil {
		failed := nativeRunNotStartedFailure(session, frame, safeDiagnosticNote(err.Error()))
		return r.persistNativeNonSubmissionProof(ctx, binding, frame, &failed)
	}
	if failure := r.nativeSubmissionDeadlineFailure(session, frame); failure != nil {
		return r.persistNativeNonSubmissionProof(ctx, binding, frame, failure)
	}
	nativeID, err := adapter.StartRun(assignedRunRequest(frame))
	if err != nil {
		failed := unconfirmedNativeRunFailure(session, frame, externalagentprotocol.TerminalReasonFailed, safeDiagnosticNote(err.Error()), "")
		return "", &failed, nil
	}
	return nativeID, nil, nil
}

func (r Runner) nativeSubmissionDeadlineFailure(session bridge.Session, frame externalagentprotocol.Frame) *externalagentprotocol.Frame {
	if frame.RunStart == nil || frame.RunStart.DeadlineAt.IsZero() {
		failed := nativeRunNotStartedFailure(session, frame, "external agent run deadline required before native submission")
		return &failed
	}
	if !activeRunDeadlineExpired(frame.RunStart.DeadlineAt, r.now()) {
		return nil
	}
	failed := nativeRunNotStartedFailure(session, frame, "external agent run deadline exceeded before native submission")
	failed.RunTerminal.Reason = externalagentprotocol.TerminalReasonExpired
	return &failed
}

func (r Runner) persistNativeNonSubmissionProof(ctx context.Context, binding config.Binding, frame externalagentprotocol.Frame, failure *externalagentprotocol.Frame) (string, *externalagentprotocol.Frame, error) {
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		if err = ctx.Err(); err != nil {
			break
		}
		err = r.recordNativeNotStarted(binding, frame)
		if err == nil {
			return "", failure, nil
		}
	}
	return "", nil, fmt.Errorf("retain native non-submission proof: %w", err)
}

func (r Runner) recordNativeNotStarted(binding config.Binding, frame externalagentprotocol.Frame) error {
	return config.UpdateBinding(r.Store, binding, func(latest *config.Binding) error {
		if latest.ConnectionGeneration != binding.ConnectionGeneration || latest.ActiveNativeRunID != "" {
			return fmt.Errorf("native journal changed")
		}
		if latest.ActiveRunID != "" && (latest.ActiveRunID != frame.RunID || latest.ActiveAssignmentID != frame.AssignmentID) {
			return fmt.Errorf("native assignment changed")
		}
		if latest.ActiveRunID != "" && latest.ActiveRunConnectionGeneration <= 0 && !latest.ActiveRunNotStarted {
			return fmt.Errorf("native assignment generation unknown")
		}
		if latest.ActiveRunID != "" && frame.RunStart != nil && !latest.ActiveRunDeadlineAt.Equal(frame.RunStart.DeadlineAt) {
			return fmt.Errorf("native assignment deadline changed")
		}
		if latest.ActiveRunID == "" {
			latest.ActiveRunID, latest.ActiveAssignmentID = frame.RunID, frame.AssignmentID
			latest.ActiveRunConnectionGeneration = binding.ConnectionGeneration
			if frame.RunStart != nil {
				latest.ActiveRunDeadlineAt = frame.RunStart.DeadlineAt.UTC()
			}
		}
		latest.ActiveRunNotStarted = true
		return nil
	})
}

// A positive local fact cannot certify a legacy/unknown assignment or conflict
// with a known native handle. Such journals retain their existing custody path.
func nativeNeverStartedJournal(binding config.Binding) bool {
	return binding.ActiveRunNotStarted && binding.ActiveRunID != "" && binding.ActiveAssignmentID != "" && binding.ActiveNativeRunID == "" && binding.ActiveRunConnectionGeneration > 0 && binding.ActiveRunConnectionGeneration <= binding.ConnectionGeneration
}

func (r Runner) canReplayNeverStartedNative(binding config.Binding) bool {
	if r.Store == nil {
		return false
	}
	latest, found := config.BindingFor(r.Store, binding)
	return found && latest.ConnectionGeneration == binding.ConnectionGeneration && nativeNeverStartedJournal(latest)
}

func (r Runner) nativeNeverStartedReplayFrame(session bridge.Session, frame externalagentprotocol.Frame, deadline time.Time) externalagentprotocol.Frame {
	failure := nativeRunNotStartedFailure(session, frame, "external agent native run did not start: "+frame.RunID)
	if activeRunDeadlineExpired(deadline, r.now()) {
		failure.RunTerminal.Reason = externalagentprotocol.TerminalReasonExpired
	}
	return failure
}
