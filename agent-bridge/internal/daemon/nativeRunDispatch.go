package daemon

import (
	"context"
	"fmt"
	"time"

	protocol "github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/bridge"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

// This is the production run.start dispatch phase after retained-command replay.
// Every refusal of an empty current journal retains its affirmative proof before
// returning a frame. A different or unknown owned journal is never overwritten.
func (r Runner) dispatchNativeRunStart(ctx context.Context, binding config.Binding, session bridge.Session, adapter runtime.Adapter, frame protocol.Frame, version string, snapshot runtimeSnapshot, wake *time.Time) (runtime.Adapter, string, *protocol.Frame, error) {
	if r.Store == nil || frame.RunStart == nil || !matchesFrameScope(binding, frame) {
		return nil, "", nil, fmt.Errorf("native dispatch scope unavailable")
	}
	latest, found := config.BindingFor(r.Store, binding)
	if !found || latest.ConnectionGeneration != binding.ConnectionGeneration {
		return nil, "", nil, fmt.Errorf("native dispatch generation changed")
	}
	if r.activeRunMatchesWithoutNativeRunID(binding, frame) {
		failed := unconfirmedNativeRunFailure(session, frame, protocol.TerminalReasonFailed, "active run native id missing", "")
		return nil, "", &failed, nil
	}
	if active, conflict := r.activeRunConflict(binding, frame); conflict {
		// This rejection belongs to a different incoming assignment. The retained
		// native/unknown sibling journal remains its only physical custody owner.
		failed := nativeRunNotStartedFailure(session, frame, "external persona already has active run "+active)
		return nil, "", &failed, nil
	}
	if latest.ActiveNativeRunID != "" {
		return nil, "", nil, fmt.Errorf("native assignment already retains a handle")
	}
	if latest.Quiesced {
		return r.refuseNativeRunStart(ctx, binding, session, frame, "background agent quiesced")
	}
	readiness := runtime.Detection{}
	if version == protocol.ProtocolVersionV4 {
		if snapshot.Target == nil || !runtimeTargetsEqual(snapshot.Target, frame.RunStart.RuntimeTarget) || snapshot.Adapter == nil {
			return r.refuseNativeRunStart(ctx, binding, session, frame, "external runtime is not ready: selected target is unavailable")
		}
		adapter, readiness = snapshot.Adapter, snapshot.Detection
	} else {
		readiness = r.bindingReadiness(adapter, binding)
	}
	if !canStartRunWithReadiness(readiness.State, wake) {
		return r.refuseNativeRunStart(ctx, binding, session, frame, "external runtime is not ready: "+readiness.State.String())
	}
	native, failure, err := r.submitNativeRunCommand(ctx, binding, session, adapter, frame)
	return adapter, native, failure, err
}

func (r Runner) refuseNativeRunStart(ctx context.Context, binding config.Binding, session bridge.Session, frame protocol.Frame, message string) (runtime.Adapter, string, *protocol.Frame, error) {
	failure := nativeRunNotStartedFailure(session, frame, message)
	native, retained, err := r.persistNativeNonSubmissionProof(ctx, binding, frame, &failure)
	return nil, native, retained, err
}
