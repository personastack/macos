package daemon

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/bridge"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

// The existing session owns this one observer. Read failure never resubmits the
// known native handle. After the original deadline only physical observation
// continues; the saved work deadline and journal stay unchanged until exact ACK.
func (r Runner) observeAssignedNativeRun(ctx context.Context, binding config.Binding, session bridge.Session, adapter runtime.Adapter, frame externalagentprotocol.Frame, nativeRunID string, deadline time.Time, observations *runObservationRegistry, writeFrame func(externalagentprotocol.Frame) error, onEvent runtime.RunEventHandler) {
	if adapter == nil {
		return
	}
	sessionCtx, cancel := context.WithCancel(ctx)
	defer observations.track(frame.RunID, cancel)()
	observeCtx, cancelDeadline := contextForRunDeadline(sessionCtx, deadline)
	defer cancelDeadline()
	lastFailure, failureOutput := externalagentprotocol.TerminalReason(""), ""
	if frame.RunTerminal != nil && frame.RunTerminal.ErrorCode == nativeTerminationUnconfirmed {
		lastFailure, failureOutput = frame.RunTerminal.Reason, frame.RunTerminal.FinalMessage
		if lastFailure == "" {
			lastFailure = externalagentprotocol.TerminalReasonFailed
		}
	}
	for {
		r.retainNativeObservationHandle(binding, frame, nativeRunID)
		handle := onEvent
		if deadline.IsZero() || lastFailure != "" || frame.RunTerminal != nil {
			// Logical completion is absorbing at API ingress. Continue native
			// readback for stop proof without publishing later business output.
			handle = func(runtime.RunEvent) error { return nil }
		}
		result, err := adapter.StreamOrPollRun(observeCtx, nativeRunID, handle)
		if err == nil {
			_ = writeFrame(nativeObservationTerminal(session, frame, result, nativeRunID, lastFailure, failureOutput))
			return
		}
		if sessionCtx.Err() != nil || errors.Is(observeCtx.Err(), context.Canceled) {
			return
		}
		reason, output := externalagentprotocol.TerminalReasonFailed, safeDiagnosticNote(err.Error())
		if errors.Is(observeCtx.Err(), context.DeadlineExceeded) {
			reason, output = externalagentprotocol.TerminalReasonExpired, "external agent run deadline exceeded"
		}
		if lastFailure == "" {
			if writeErr := writeFrame(unconfirmedNativeRunFailure(session, frame, reason, output, nativeRunID)); writeErr != nil {
				return
			}
			lastFailure, failureOutput = reason, output
		}
		if reason == externalagentprotocol.TerminalReasonExpired {
			_ = adapter.CancelRun(nativeRunID)
			observeCtx = sessionCtx
		}
		timer := time.NewTimer(r.reconnectMin())
		select {
		case <-sessionCtx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

// Preserve the handle in the current observer while retrying a failed journal
// write before another transport effect. A one-time write failure is repaired
// before reconnect can require that journal to recover the existing handle.
func (r Runner) observeNativeRunAfterJournalFailure(ctx context.Context, binding config.Binding, session bridge.Session, adapter runtime.Adapter, frame externalagentprotocol.Frame, nativeRunID string, recordErr error, observations *runObservationRegistry, cache *commandFrameCache, writeFrame func(externalagentprotocol.Frame) error) error {
	_ = r.recordNativeRunID(binding, frame.RunID, nativeRunID)
	failed := runRecordFailureTerminal(adapter, session, frame, nativeRunID, recordErr)
	cache.storeReply(frame, failed)
	if err := writeFrame(failed); err != nil {
		return fmt.Errorf("write run journal failure: %w", err)
	}
	deadline := time.Time{}
	if frame.RunStart != nil {
		deadline = frame.RunStart.DeadlineAt
	}
	go r.observeActiveRun(ctx, binding, session, adapter, failed, nativeRunID, deadline, observations, writeFrame)
	return nil
}

func (r Runner) retainNativeObservationHandle(binding config.Binding, frame externalagentprotocol.Frame, nativeRunID string) {
	if r.Store == nil {
		return
	}
	latest, found := config.BindingFor(r.Store, binding)
	if !found || latest.ConnectionGeneration != binding.ConnectionGeneration || latest.ActiveRunID != frame.RunID || latest.ActiveAssignmentID != frame.AssignmentID || latest.ActiveNativeRunID != "" {
		return
	}
	_ = r.recordNativeRunID(binding, frame.RunID, nativeRunID)
}

func nativeObservationTerminal(session bridge.Session, frame externalagentprotocol.Frame, result runtime.RunResult, nativeRunID string, failure externalagentprotocol.TerminalReason, failureOutput string) externalagentprotocol.Frame {
	status, reason := externalagentprotocol.RunStatusCompleted, externalagentprotocol.TerminalReasonSucceeded
	if result.Status == runtime.RunStatusFailed {
		status, reason = externalagentprotocol.RunStatusFailed, externalagentprotocol.TerminalReasonFailed
	}
	if result.Status == runtime.RunStatusCancelled {
		status, reason = externalagentprotocol.RunStatusCancelled, externalagentprotocol.TerminalReasonCancelled
	}
	if failure != "" {
		if status == externalagentprotocol.RunStatusCompleted {
			status = externalagentprotocol.RunStatusFailed
		}
		reason, result.Output = failure, failureOutput
	}
	return observedNativeRunTerminal(session, frame, status, reason, result.Output, nativeRunID)
}
