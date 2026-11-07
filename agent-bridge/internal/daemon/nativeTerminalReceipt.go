package daemon

import (
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
)

// This session-local receipt proves which physical terminal observation was
// sent. Reconnect starts empty and must observe/replay proof before any ACK can
// clear the existing durable native assignment journal.
type nativeTerminalReceipts struct {
	mu                                       sync.Mutex
	messageID, runID, assignmentID, nativeID string
}

func nativeTerminalProof(frame externalagentprotocol.Frame) bool {
	if frame.RunTerminal == nil || frame.MessageID == "" || frame.RunID == "" || frame.AssignmentID == "" {
		return false
	}
	code := frame.RunTerminal.ErrorCode
	if code == nativeTerminationUnconfirmed {
		return false
	}
	native := strings.TrimSpace(frame.RunTerminal.NativeRunID)
	switch frame.MessageType {
	case externalagentprotocol.FrameTypeRunCompleted, externalagentprotocol.FrameTypeRunCancelled:
		return native != ""
	case externalagentprotocol.FrameTypeRunFailed:
		return (code == nativeTerminationConfirmed && native != "") || (code == nativeNotStarted && native == "")
	default:
		return false
	}
}

func (r Runner) prepareAssignedRunFrame(binding config.Binding, frame externalagentprotocol.Frame) (externalagentprotocol.Frame, bool, error) {
	if r.Store == nil || frame.RunID == "" {
		return frame, true, nil
	}
	latest, ok := config.BindingFor(r.Store, binding)
	if !ok {
		return frame, false, fmt.Errorf("binding unavailable")
	}
	if latest.ConnectionGeneration != binding.ConnectionGeneration {
		return frame, false, fmt.Errorf("stale connection generation")
	}
	if latest.ActiveRunID != frame.RunID || latest.ActiveAssignmentID != frame.AssignmentID {
		return frame, true, nil
	}
	generation := latest.ActiveRunConnectionGeneration
	if generation == 0 {
		// Legacy journals may have reconnected repeatedly. The last transport
		// generation cannot recover their original assignment generation.
		if !nativeTerminalProof(frame) || latest.ActiveNativeRunID == "" || strings.TrimSpace(frame.RunTerminal.NativeRunID) != latest.ActiveNativeRunID {
			return frame, false, nil
		}
		frame.ConnectionGeneration = binding.ConnectionGeneration
		return frame, true, nil
	}
	if generation != binding.ConnectionGeneration && !nativeTerminalProof(frame) {
		return frame, false, nil
	}
	if frame.RunTerminal != nil {
		frame.ConnectionGeneration = generation
	}
	return frame, true, nil
}

func (receipts *nativeTerminalReceipts) record(r Runner, binding config.Binding, frame externalagentprotocol.Frame) {
	if receipts == nil || r.Store == nil || !nativeTerminalProof(frame) {
		return
	}
	latest, ok := config.BindingFor(r.Store, binding)
	if !ok || latest.ActiveRunID != frame.RunID || latest.ActiveAssignmentID != frame.AssignmentID || latest.ConnectionGeneration != binding.ConnectionGeneration {
		return
	}
	if latest.ActiveNativeRunID != "" && latest.ActiveNativeRunID != frame.RunTerminal.NativeRunID {
		return
	}
	receipts.mu.Lock()
	defer receipts.mu.Unlock()
	receipts.messageID, receipts.runID, receipts.assignmentID, receipts.nativeID = frame.MessageID, frame.RunID, frame.AssignmentID, frame.RunTerminal.NativeRunID
}

func (r Runner) acknowledgeNativeTerminal(binding config.Binding, ack externalagentprotocol.Frame, receipts *nativeTerminalReceipts) (bool, error) {
	if receipts == nil || !matchesFrameScope(binding, ack) || ack.RunTerminalAck == nil {
		return false, nil
	}
	receipts.mu.Lock()
	defer receipts.mu.Unlock()
	if receipts.messageID == "" || ack.MessageID != receipts.messageID || ack.RunID != receipts.runID || ack.AssignmentID != receipts.assignmentID {
		return false, nil
	}
	released := false
	err := config.UpdateBinding(r.Store, binding, func(latest *config.Binding) error {
		if latest.ConnectionGeneration != binding.ConnectionGeneration || latest.ActiveRunID != ack.RunID || latest.ActiveAssignmentID != ack.AssignmentID {
			return nil
		}
		if latest.ActiveNativeRunID != "" && latest.ActiveNativeRunID != receipts.nativeID {
			return nil
		}
		latest.ActiveRunID = ""
		latest.ActiveAssignmentID = ""
		latest.ActiveNativeRunID = ""
		latest.ActiveRunDeadlineAt = time.Time{}
		latest.ActiveRunConnectionGeneration = 0
		latest.ActiveRunNotStarted = false
		released = true
		return nil
	})
	if released {
		receipts.messageID = ""
	}
	return released, err
}
