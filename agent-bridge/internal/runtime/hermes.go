package runtime

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"time"
	"unicode"

	"github.com/personastack/macos/agent-bridge/internal/hermessetup"
)

const defaultHermesURL = "http://127.0.0.1:8642"
const defaultHermesCancelWait = 15 * time.Second
const hermesRequiredRunSubmissionFeature = "run_submission"
const hermesRequiredRunStatusFeature = "run_status"
const hermesDegradedRunEventsSSEFeature = "run_events_sse"
const hermesDegradedRunStopFeature = "run_stop"

var errHermesRunEventsUnavailable = errors.New("Hermes run events unavailable")
var hermesToolsListCommand = exec.CommandContext
var hermesLookPath = exec.LookPath

type HermesAdapter struct {
	ProfileHome string
	BaseURL     string
	APIKey      string
	Client      *http.Client
}

type HermesMCPRegistryCheck struct {
	OK   bool
	Note string
}

func NewHermesAdapter(baseURL string, apiKey string) HermesAdapter {
	if strings.TrimSpace(baseURL) == "" {
		baseURL = defaultHermesURL
	}
	if strings.TrimSpace(apiKey) == "" {
		apiKey = hermessetup.LoadAPIKey()
	}
	return HermesAdapter{
		BaseURL: strings.TrimRight(baseURL, "/"), APIKey: strings.TrimSpace(apiKey), Client: defaultHTTPClient()}
}

func NewHermesAdapterForHome(baseURL string, hermesHome string) HermesAdapter {
	if strings.TrimSpace(baseURL) == "" {
		baseURL = defaultHermesURL
	}
	homeDir, _ := os.UserHomeDir()
	paths := hermessetup.ResolvePaths(homeDir, hermesHome)
	return HermesAdapter{
		ProfileHome: hermesHome,
		BaseURL:     strings.TrimRight(baseURL, "/"),
		APIKey:      strings.TrimSpace(hermessetup.LoadAPIKeyForPaths(paths)),
		Client:      defaultHTTPClient(),
	}
}

func (adapter HermesAdapter) Kind() AdapterKind {
	return AdapterKindHermes
}

func (adapter HermesAdapter) Detect() Detection {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return adapter.DetectContext(ctx)
}

func (adapter HermesAdapter) DetectContext(ctx context.Context) Detection {
	if err := adapter.validateLoopbackBaseURL(); err != nil {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateRuntimeMissing, Note: err.Error()}
	}
	client := adapter.client()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, adapter.BaseURL+"/health", nil)
	if err != nil {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateRuntimeMissing, Note: err.Error()}
	}
	resp, err := client.Do(req)
	if err != nil {
		return adapter.unavailableDetection("Hermes API unavailable")
	}
	_ = resp.Body.Close()
	if resp.StatusCode >= 300 {
		return adapter.unavailableDetection(fmt.Sprintf("health status %d", resp.StatusCode))
	}
	if adapter.APIKey == "" {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateAuthMissing, Note: "HERMES_API_SERVER_KEY is required"}
	}
	if detection, failed := adapter.probeOptionalAuthenticatedEndpoint(ctx, "/health/detailed"); failed {
		return detection
	}
	if detection, failed := adapter.probeOptionalAuthenticatedEndpoint(ctx, "/v1/models"); failed {
		return detection
	}
	req, err = http.NewRequestWithContext(ctx, http.MethodGet, adapter.BaseURL+"/v1/capabilities", nil)
	if err != nil {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateCapabilityMissing, Note: err.Error()}
	}
	req.Header.Set("Authorization", "Bearer "+adapter.APIKey)
	resp, err = client.Do(req)
	if err != nil {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateCapabilityMissing, Note: err.Error()}
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateAuthMissing, Note: "Hermes API key rejected"}
	}
	if resp.StatusCode >= 300 {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateCapabilityMissing, Note: fmt.Sprintf("capabilities status %d", resp.StatusCode)}
	}
	var capabilities hermesCapabilities
	if err := json.NewDecoder(resp.Body).Decode(&capabilities); err != nil {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateCapabilityMissing, Note: err.Error()}
	}
	missing := capabilities.missingRequiredFeatures()
	if len(missing) > 0 {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateCapabilityMissing, Note: strings.Join(missing, ",") + " missing"}
	}
	degraded := capabilities.degradedFallbackFeatures()
	if len(degraded) > 0 {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateCapabilityMissing, Note: "runtime_unsupported: native progress and stop required"}
	}
	return Detection{Kind: AdapterKindHermes, State: AdapterStateReady, Note: "Hermes API ready"}
}

func (adapter HermesAdapter) DescribeNativeCapabilities(ctx context.Context, nativeMCPServerName string) ([]NativeCapability, error) {
	capabilities, err := adapter.fetchHermesCapabilities(ctx)
	capabilitiesErr := err
	out := []NativeCapability{}
	if err == nil {
		summaries := capabilities.nativeCapabilitySummaries()
		if len(summaries) == 0 {
			summaries = append(summaries, nativeCapabilitySource(NativeCapabilitySourceHermesRuntimeAPI))
		}
		out = append(out, summaries...)
	}
	tools, err := hermesToolListCapabilities(ctx, nativeMCPServerName, adapter.ProfileHome)
	toolsErr := err
	if err == nil {
		if capabilitiesErr != nil {
			markNativeCapabilitiesDegraded(tools)
		}
		out = append(out, tools...)
	}
	if capabilitiesErr != nil || toolsErr != nil {
		return out, errors.Join(capabilitiesErr, toolsErr)
	}
	return out, nil
}

func (adapter HermesAdapter) fetchHermesCapabilities(ctx context.Context) (hermesCapabilities, error) {
	if err := adapter.validateLoopbackBaseURL(); err != nil {
		return hermesCapabilities{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, adapter.BaseURL+"/v1/capabilities", nil)
	if err != nil {
		return hermesCapabilities{}, err
	}
	if adapter.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+adapter.APIKey)
	}
	resp, err := adapter.client().Do(req)
	if err != nil {
		return hermesCapabilities{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return hermesCapabilities{}, fmt.Errorf("Hermes capabilities status %d", resp.StatusCode)
	}
	var capabilities hermesCapabilities
	if err := json.NewDecoder(resp.Body).Decode(&capabilities); err != nil {
		return hermesCapabilities{}, err
	}
	return capabilities, nil
}

func (adapter HermesAdapter) probeOptionalAuthenticatedEndpoint(ctx context.Context, path string) (Detection, bool) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, adapter.BaseURL+path, nil)
	if err != nil {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateCapabilityMissing, Note: err.Error()}, true
	}
	req.Header.Set("Authorization", "Bearer "+adapter.APIKey)
	resp, err := adapter.client().Do(req)
	if err != nil {
		return Detection{}, false
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateAuthMissing, Note: "Hermes API key rejected"}, true
	}
	return Detection{}, false
}

func (adapter HermesAdapter) StreamOrPollRun(ctx context.Context, nativeRunID string, handle RunEventHandler) (RunResult, error) {
	if err := adapter.validateLoopbackBaseURL(); err != nil {
		return RunResult{}, err
	}
	trimmedRunID := strings.TrimSpace(nativeRunID)
	if trimmedRunID == "" {
		return RunResult{}, fmt.Errorf("native run id required")
	}

	state := &runEventState{}
	observedToolEventKeys := map[string]struct{}{}
	observer := func(event RunEvent) error {
		if event.Kind == RunEventStarted {
			return state.emitStarted(handle, event.StartedAt)
		}
		if event.Kind == RunEventToolEvent {
			observedToolEventKeys[hermesStateToolEventKey(event)] = struct{}{}
		}
		if handle == nil {
			return nil
		}
		return handle(event)
	}
	if result, terminal, err := adapter.streamRunEvents(ctx, trimmedRunID, observer); err != nil {
		if !errors.Is(err, errHermesRunEventsUnavailable) {
			return RunResult{}, err
		}
	} else if terminal {
		return adapter.terminalHermesRun(ctx, trimmedRunID, result, handle, state, observedToolEventKeys)
	}
	return adapter.pollRunStatus(ctx, trimmedRunID, handle, state, observedToolEventKeys)
}

func (adapter HermesAdapter) WaitRun(ctx context.Context, nativeRunID string) (RunResult, error) {
	return adapter.StreamOrPollRun(ctx, nativeRunID, nil)
}

func (adapter HermesAdapter) StartRun(request RunRequest) (string, error) {
	if err := adapter.validateLoopbackBaseURL(); err != nil {
		return "", err
	}
	nativeRunID, err := adapter.startHermesRun(request)
	if err != nil {
		return "", err
	}
	return nativeRunID, nil
}

func (adapter HermesAdapter) startHermesRun(request RunRequest) (string, error) {
	body := hermesRunSubmission{Input: strings.TrimSpace(request.FullyComposedPrompt), NativeMCPServer: boundedRunMetadataText(request.NativeMCPServerName, maxRunMetadataValueRunes), NativeMCPNamespace: boundedRunMetadataText(request.NativeMCPToolNamespace, maxRunMetadataValueRunes), IncludeNativeTools: true, Metadata: runMetadata(request)}
	conversationKey := hermesConversationKey(request)
	if conversationKey == "" {
		body.SessionID = boundedRunMetadataText(firstNonEmpty(request.RunID, request.AssignmentID), maxRunMetadataValueRunes)
	}

	raw, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequest(http.MethodPost, adapter.BaseURL+"/v1/runs", bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	if conversationKey != "" {
		req.Header.Set("X-Hermes-Session-Key", conversationKey)
	}
	if request.AssignmentID != "" {
		req.Header.Set("Idempotency-Key", request.AssignmentID)
	}
	req.Header.Set("Content-Type", "application/json")
	if adapter.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+adapter.APIKey)
	}
	resp, err := adapter.client().Do(req)
	if err != nil {
		return "", fmt.Errorf("Hermes run dispatch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return "", hermesRunDispatchError{status: resp.StatusCode, body: readHermesResponseBody(resp.Body)}
	}
	var decoded hermesRunResponse
	if err := json.NewDecoder(resp.Body).Decode(&decoded); err != nil {
		return "", err
	}
	nativeRunID := strings.TrimSpace(firstNonEmpty(decoded.RunID, decoded.ID))
	if nativeRunID == "" {
		return "", fmt.Errorf("Hermes response missing run id")
	}
	return nativeRunID, nil
}

func (adapter HermesAdapter) streamRunEvents(ctx context.Context, nativeRunID string, handle RunEventHandler) (RunResult, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, adapter.BaseURL+"/v1/runs/"+strings.TrimSpace(nativeRunID)+"/events", nil)
	if err != nil {
		return RunResult{}, false, err
	}
	req.Header.Set("Accept", "text/event-stream")
	if adapter.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+adapter.APIKey)
	}
	resp, err := adapter.streamClient().Do(req)
	if err != nil {
		return RunResult{}, false, nil
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusNotImplemented || resp.StatusCode == http.StatusMethodNotAllowed {
		return RunResult{}, false, nil
	}
	if resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500 {
		return RunResult{}, false, errHermesRunEventsUnavailable
	}
	if resp.StatusCode >= 300 {
		return RunResult{}, false, fmt.Errorf("Hermes run events status %d", resp.StatusCode)
	}
	result, terminal, err := readHermesRunEvents(resp.Body, handle, nativeRunID)
	if err != nil {
		return RunResult{}, false, err
	}
	return result, terminal, nil
}

func (adapter HermesAdapter) pollRunStatus(ctx context.Context, nativeRunID string, handle RunEventHandler, state *runEventState, observedToolEventKeys map[string]struct{}) (RunResult, error) {
	result, err := adapter.waitHermesRunStatus(ctx, nativeRunID)
	if err != nil {
		return RunResult{}, err
	}
	if state != nil {
		if err := state.emitStarted(handle, time.Time{}); err != nil {
			return RunResult{}, err
		}
	}
	return result, nil
}

func (adapter HermesAdapter) terminalHermesRun(ctx context.Context, nativeRunID string, result RunResult, handle RunEventHandler, state *runEventState, observedToolEventKeys map[string]struct{}) (RunResult, error) {
	if result.Status == RunStatusSucceeded && strings.TrimSpace(result.Output) == "" {
		enriched, enrichedTerminal, err := adapter.runStatus(ctx, nativeRunID)
		if err == nil && enrichedTerminal && strings.TrimSpace(enriched.Output) != "" {
			return enriched, nil
		}
	}
	return result, nil
}

func hermesStateToolEventKey(event RunEvent) string {
	if toolCallID := strings.TrimSpace(event.ToolCallID); toolCallID != "" {
		return strings.Join([]string{toolCallID, event.ToolPhase}, "\x00")
	}
	return strings.Join([]string{event.ToolName, event.ToolPhase, event.Summary}, "\x00")
}

func (adapter HermesAdapter) waitHermesRunStatus(ctx context.Context, nativeRunID string) (RunResult, error) {

	return adapter.waitRunStatus(ctx, nativeRunID)
}

func readHermesRunEvents(body io.Reader, handle RunEventHandler, expectedRunID ...string) (RunResult, bool, error) {
	scanner := bufio.NewScanner(body)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	var data []string
	started := false
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			if result, terminal, event, hasEvent := hermesRunEventResult(strings.Join(data, "\n")); hasEvent {
				if len(expectedRunID) > 0 && event.RunID != "" && event.RunID != expectedRunID[0] {
					data = nil
					continue
				}
				if !started {
					started = true
					if handle != nil {
						if err := handle(RunEvent{Kind: RunEventStarted, StartedAt: hermesRunEventStartedAt(event)}); err != nil {
							return RunResult{}, false, err
						}
					}
				}
				if handle != nil {
					for _, runEvent := range hermesRunEventsForEvent(event) {
						if err := handle(runEvent); err != nil {
							return RunResult{}, false, err
						}
					}
				}
				if terminal {
					return result, true, nil
				}
			} else if result, terminal := hermesRunEventResultLegacy(strings.Join(data, "\n")); terminal {
				if !started {
					started = true
					if handle != nil {
						if err := handle(RunEvent{Kind: RunEventStarted, StartedAt: time.Now().UTC()}); err != nil {
							return RunResult{}, false, err
						}
					}
				}
				if terminal {
					return result, true, nil
				}
			}
			if len(data) > 0 && !started {
				started = true
				if handle != nil {
					if err := handle(RunEvent{Kind: RunEventStarted, StartedAt: time.Now().UTC()}); err != nil {
						return RunResult{}, false, err
					}
				}
			}
			data = nil
			continue
		}
		if after, ok := strings.CutPrefix(line, "data:"); ok {
			data = append(data, strings.TrimSpace(after))
		}
	}
	if err := scanner.Err(); err != nil {
		return RunResult{}, false, fmt.Errorf("%w: %v", errHermesRunEventsUnavailable, err)
	}
	if result, terminal, event, hasEvent := hermesRunEventResult(strings.Join(data, "\n")); hasEvent {
		if len(expectedRunID) > 0 && event.RunID != "" && event.RunID != expectedRunID[0] {
			return RunResult{}, false, nil
		}
		if !started {
			started = true
			if handle != nil {
				if err := handle(RunEvent{Kind: RunEventStarted, StartedAt: hermesRunEventStartedAt(event)}); err != nil {
					return RunResult{}, false, err
				}
			}
		}
		if handle != nil {
			for _, runEvent := range hermesRunEventsForEvent(event) {
				if err := handle(runEvent); err != nil {
					return RunResult{}, false, err
				}
			}
		}
		if terminal {
			return result, true, nil
		}
	}
	return RunResult{}, false, nil
}

func hermesRunEventResult(raw string) (RunResult, bool, hermesRunEvent, bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || trimmed == "[DONE]" {
		return RunResult{}, false, hermesRunEvent{}, false
	}
	var event hermesRunEvent
	if err := json.Unmarshal([]byte(trimmed), &event); err != nil {
		return RunResult{}, false, hermesRunEvent{}, false
	}
	if len(event.Data) > 0 {
		var nested hermesRunEvent
		if err := json.Unmarshal(event.Data, &nested); err == nil {
			event = mergeHermesRunEvents(event, nested)
		}
	}
	status := strings.ToLower(strings.TrimSpace(firstNonEmpty(event.Status, event.Type, event.Event)))
	switch status {
	case "run.completed", "completed", "succeeded", "success":
		return RunResult{Status: RunStatusSucceeded, Output: strings.TrimSpace(event.Output)}, true, event, true
	case "run.failed", "failed", "error":
		return RunResult{Status: RunStatusFailed, Output: strings.TrimSpace(firstNonEmpty(event.Error, event.Output))}, true, event, true
	case "run.cancelled", "run.canceled", "cancelled", "canceled":
		return RunResult{Status: RunStatusCancelled}, true, event, true
	default:
		return RunResult{}, false, event, true
	}
}

func hermesRunEventResultLegacy(raw string) (RunResult, bool) {
	result, terminal, _, hasEvent := hermesRunEventResult(raw)
	if !hasEvent {
		return RunResult{}, false
	}
	return result, terminal
}

func hermesRunEventsForEvent(event hermesRunEvent) []RunEvent {
	events := []RunEvent{}
	if delta := firstNonEmpty(hermesRunEventString(event, "deltaText"), hermesRunEventString(event, "delta"), hermesRunEventString(event, "text")); delta != "" {
		events = append(events, RunEvent{Kind: RunEventOutputDelta, Delta: delta})
	}
	toolName := firstNonEmpty(hermesRunEventString(event, "toolName"), hermesRunEventString(event, "tool"), hermesRunEventString(event, "name"))
	phase := firstNonEmpty(hermesRunEventString(event, "phase"), hermesRunEventString(event, "status"))
	summary := firstNonEmpty(hermesRunEventString(event, "summary"), hermesRunEventString(event, "message"), event.Output, event.Error)
	if toolName != "" && phase != "" {
		events = append(events, RunEvent{Kind: RunEventToolEvent, ToolName: toolName, ToolPhase: phase, Summary: summary})
	}
	return events
}

func hermesRunEventStartedAt(event hermesRunEvent) time.Time {
	if startedAt, ok := hermesRunEventTime(event, "startedAt", "started_at"); ok {
		return startedAt
	}
	return time.Now().UTC()
}

func hermesRunEventString(event hermesRunEvent, names ...string) string {
	for _, name := range names {
		switch name {
		case "delta":
			if event.Delta != "" {
				return event.Delta
			}
		case "toolName", "tool":
			if event.ToolName != "" {
				return event.ToolName
			}
		case "phase":
			if event.ToolPhase != "" {
				return event.ToolPhase
			}
		}
	}
	if len(event.Data) > 0 {
		var envelope map[string]json.RawMessage
		if err := json.Unmarshal(event.Data, &envelope); err == nil {
			for _, name := range names {
				if raw, ok := envelope[name]; ok {
					var value string
					if err := json.Unmarshal(raw, &value); err == nil {
						return strings.TrimSpace(value)
					}
				}
			}
		}
	}
	return ""
}

func hermesRunEventTime(event hermesRunEvent, names ...string) (time.Time, bool) {
	if len(event.Data) == 0 {
		return time.Time{}, false
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(event.Data, &envelope); err != nil {
		return time.Time{}, false
	}
	for _, name := range names {
		if raw, ok := envelope[name]; ok {
			if parsed, ok := parseHermesJSONTime(raw); ok {
				return parsed, true
			}
		}
	}
	return time.Time{}, false
}

func parseHermesJSONTime(raw json.RawMessage) (time.Time, bool) {
	if len(raw) == 0 {
		return time.Time{}, false
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		if parsed, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(text)); err == nil {
			return parsed.UTC(), true
		}
	}
	var millis int64
	if err := json.Unmarshal(raw, &millis); err == nil {
		return time.UnixMilli(millis).UTC(), true
	}
	return time.Time{}, false
}

func mergeHermesRunEvents(parent hermesRunEvent, child hermesRunEvent) hermesRunEvent {
	if strings.TrimSpace(parent.Status) == "" {
		parent.Status = child.Status
	}
	if strings.TrimSpace(parent.Output) == "" {
		parent.Output = child.Output
	}
	if strings.TrimSpace(parent.Error) == "" {
		parent.Error = child.Error
	}
	return parent
}

func (adapter HermesAdapter) runStatus(ctx context.Context, nativeRunID string) (RunResult, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, adapter.BaseURL+"/v1/runs/"+strings.TrimSpace(nativeRunID), nil)
	if err != nil {
		return RunResult{}, false, err
	}
	if adapter.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+adapter.APIKey)
	}
	resp, err := adapter.client().Do(req)
	if err != nil {
		return RunResult{}, false, fmt.Errorf("Hermes run status: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return RunResult{}, false, fmt.Errorf("Hermes run status %d", resp.StatusCode)
	}
	var decoded hermesRunStatusResponse
	if err := json.NewDecoder(resp.Body).Decode(&decoded); err != nil {
		return RunResult{}, false, err
	}
	switch strings.ToLower(strings.TrimSpace(decoded.Status)) {
	case "completed", "succeeded", "success":
		return RunResult{Status: RunStatusSucceeded, Output: strings.TrimSpace(decoded.Output)}, true, nil
	case "failed", "error":
		return RunResult{Status: RunStatusFailed, Output: strings.TrimSpace(firstNonEmpty(decoded.Error, decoded.Output))}, true, nil
	case "cancelled", "canceled":
		return RunResult{Status: RunStatusCancelled}, true, nil
	default:
		return RunResult{}, false, nil
	}
}

func (adapter HermesAdapter) waitRunStatus(ctx context.Context, nativeRunID string) (RunResult, error) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		result, terminal, err := adapter.runStatus(ctx, nativeRunID)
		if err != nil {
			return RunResult{}, err
		}
		if terminal {
			return result, nil
		}
		select {
		case <-ctx.Done():
			return RunResult{}, ctx.Err()
		case <-ticker.C:
		}
	}
}

func (adapter HermesAdapter) CancelRun(nativeRunID string) error {
	if err := adapter.validateLoopbackBaseURL(); err != nil {
		return err
	}
	trimmedRunID := strings.TrimSpace(nativeRunID)
	if trimmedRunID == "" {
		return fmt.Errorf("native run id required")
	}

	req, err := http.NewRequest(http.MethodPost, adapter.BaseURL+"/v1/runs/"+strings.TrimSpace(nativeRunID)+"/stop", nil)
	if err != nil {
		return err
	}
	if adapter.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+adapter.APIKey)
	}
	resp, err := adapter.client().Do(req)
	if err != nil {
		return fmt.Errorf("Hermes stop: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("Hermes stop status %d", resp.StatusCode)
	}
	ctx, cancel := context.WithTimeout(context.Background(), defaultHermesCancelWait)
	defer cancel()
	_, err = adapter.waitRunStatus(ctx, trimmedRunID)
	if err != nil && !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
		return err
	}
	return nil
}

func (adapter HermesAdapter) Diagnose() Detection {
	return adapter.Detect()
}

func (adapter HermesAdapter) unavailableDetection(prefix string) Detection {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateRuntimeMissing, Note: prefix + "; resolve home dir: " + err.Error()}
	}
	diagnostic := hermessetup.Diagnose(homeDir)
	note := prefix
	if strings.TrimSpace(diagnostic.Note) != "" {
		note += "; " + diagnostic.Note
	}
	if diagnostic.State == hermessetup.SetupStateNeedsEnv {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateRuntimeStopped, Note: note}
	}
	if diagnostic.State == hermessetup.SetupStateNeedsConfig {
		return Detection{Kind: AdapterKindHermes, State: AdapterStateMCPConfigMissing, Note: note}
	}
	return Detection{Kind: AdapterKindHermes, State: AdapterStateRuntimeStopped, Note: note}
}

func (adapter HermesAdapter) client() *http.Client {
	checkRedirect := func(req *http.Request, via []*http.Request) error {
		if err := validateHermesLoopbackURL(req.URL); err != nil {
			return err
		}
		return nil
	}
	if adapter.Client != nil {
		copied := *adapter.Client
		copied.CheckRedirect = checkRedirect
		return &copied
	}
	client := defaultHTTPClient()
	client.CheckRedirect = checkRedirect
	return client
}

func (adapter HermesAdapter) streamClient() *http.Client {
	client := adapter.client()
	copied := *client
	copied.Timeout = 0
	return &copied
}

func (adapter HermesAdapter) validateLoopbackBaseURL() error {
	parsed, err := url.Parse(strings.TrimSpace(adapter.BaseURL))
	if err != nil {
		return fmt.Errorf("parse Hermes API URL: %w", err)
	}
	return validateHermesLoopbackURL(parsed)
}

func validateHermesLoopbackURL(parsed *url.URL) error {
	if parsed.Scheme != "http" {
		return fmt.Errorf("Hermes API URL must use http loopback")
	}
	host := parsed.Hostname()
	if host == "localhost" {
		ips, err := net.LookupIP(host)
		if err != nil {
			return fmt.Errorf("resolve Hermes API host: %w", err)
		}
		for _, ip := range ips {
			if !ip.IsLoopback() {
				return fmt.Errorf("Hermes API URL must be loopback")
			}
		}
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("Hermes API URL must be loopback")
	}
	return nil
}

type hermesCapabilities struct {
	Features struct {
		RunSubmission bool `json:"run_submission"`
		RunStatus     bool `json:"run_status"`
		RunEventsSSE  bool `json:"run_events_sse"`
		RunStop       bool `json:"run_stop"`
	} `json:"features"`
}

type hermesRunDispatchError struct {
	status int
	body   string
}

func (err hermesRunDispatchError) Error() string {
	if strings.TrimSpace(err.body) != "" {
		return fmt.Sprintf("Hermes run dispatch status %d: %s", err.status, strings.TrimSpace(err.body))
	}
	return fmt.Sprintf("Hermes run dispatch status %d", err.status)
}

func readHermesResponseBody(body io.Reader) string {
	raw, _ := io.ReadAll(io.LimitReader(body, 4096))
	return strings.TrimSpace(string(raw))
}

func (capabilities hermesCapabilities) missingRequiredFeatures() []string {
	missing := []string{}
	if !capabilities.Features.RunSubmission {
		missing = append(missing, hermesRequiredRunSubmissionFeature)
	}
	if !capabilities.Features.RunStatus {
		missing = append(missing, hermesRequiredRunStatusFeature)
	}
	return missing
}

func (capabilities hermesCapabilities) degradedFallbackFeatures() []string {
	missing := []string{}
	if !capabilities.Features.RunEventsSSE {
		missing = append(missing, hermesDegradedRunEventsSSEFeature)
	}
	if !capabilities.Features.RunStop {
		missing = append(missing, hermesDegradedRunStopFeature)
	}
	return missing
}

func (capabilities hermesCapabilities) nativeCapabilitySummaries() []NativeCapability {
	out := []NativeCapability{}
	if capabilities.Features.RunSubmission {
		out = append(out, hermesNativeCapability("run_submission", "Task delegation", "can accept delegated tasks"))
	}
	if capabilities.Features.RunStatus {
		out = append(out, hermesNativeCapability("run_status", "Task status", "can report task status"))
	}
	if capabilities.Features.RunEventsSSE {
		out = append(out, hermesNativeCapability("run_events_sse", "Progress streaming", "can stream progress updates"))
	}
	if capabilities.Features.RunStop {
		out = append(out, hermesNativeCapability("run_stop", "Task cancellation", "can cancel delegated tasks"))
	}
	return out
}

func hermesNativeCapability(id string, label string, summary string) NativeCapability {
	return NativeCapability{
		Source:       NativeCapabilitySourceHermesRuntimeAPI,
		Kind:         NativeCapabilityKindRuntimeFeature,
		CapabilityID: strings.TrimSpace(id),
		Label:        strings.TrimSpace(label),
		Summary:      strings.TrimSpace(summary),
	}
}

func hermesToolListCapabilities(ctx context.Context, nativeMCPServerName, profileHome string) ([]NativeCapability, error) {
	hermesBin, err := resolveHermesBinary()
	if err != nil {
		return nil, err
	}
	command := hermesToolsListCommand(ctx, hermesBin, "tools", "list", "--platform", "api_server")
	command.WaitDelay = 250 * time.Millisecond
	command.Env = selectedHermesEnvironment(profileHome)
	raw, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("Hermes tools list: %w", err)
	}
	capabilities := parseHermesToolsList(string(raw), nativeMCPServerName)
	if len(capabilities) == 0 {
		capabilities = append(capabilities, nativeCapabilitySource(NativeCapabilitySourceHermesToolsList))
	}
	return capabilities, nil
}

func VerifyHermesMCPServerLoaded(ctx context.Context, nativeMCPServerName string) HermesMCPRegistryCheck {
	return VerifyHermesMCPServerLoadedWithHome(ctx, nativeMCPServerName, "")
}

func VerifyHermesMCPServerLoadedWithHome(ctx context.Context, nativeMCPServerName string, hermesHome string) HermesMCPRegistryCheck {
	serverName := strings.TrimSpace(nativeMCPServerName)
	if serverName == "" {
		return HermesMCPRegistryCheck{Note: "Hermes MCP server name missing"}
	}
	hermesBin, err := resolveHermesBinary()
	if err != nil {
		return HermesMCPRegistryCheck{Note: err.Error()}
	}
	command := hermesToolsListCommand(ctx, hermesBin, "tools", "list", "--platform", "api_server")
	command.WaitDelay = 250 * time.Millisecond
	if strings.TrimSpace(hermesHome) != "" {
		for _, entry := range os.Environ() {
			if !strings.HasPrefix(entry, "HERMES_HOME=") {
				command.Env = append(command.Env, entry)
			}
		}
		command.Env = append(command.Env, "HERMES_HOME="+strings.TrimSpace(hermesHome))
	}
	raw, err := command.Output()
	if err != nil {
		return HermesMCPRegistryCheck{Note: fmt.Sprintf("Hermes tools list: %v", err)}
	}
	if hermesMCPServerLoaded(string(raw), serverName) {
		return HermesMCPRegistryCheck{OK: true, Note: "Hermes MCP server loaded in api_server tool registry"}
	}
	return HermesMCPRegistryCheck{Note: "Hermes MCP server not loaded in api_server tool registry"}
}

func resolveHermesBinary() (string, error) {
	if explicit := strings.TrimSpace(os.Getenv("HERMES_BIN")); explicit != "" {
		if executableFile(explicit) {
			return explicit, nil
		}
		return "", fmt.Errorf("Hermes binary not executable: %s", explicit)
	}
	if path, err := hermesLookPath("hermes"); err == nil && strings.TrimSpace(path) != "" {
		return path, nil
	}
	for _, candidate := range hermesBinaryCandidates() {
		if executableFile(candidate) {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("Hermes binary not found in PATH or known install locations")
}

func hermesBinaryCandidates() []string {
	candidates := []string{}
	homeDir := strings.TrimSpace(os.Getenv("HOME"))
	if homeDir != "" {
		candidates = append(candidates,
			filepath.Join(homeDir, ".local", "bin", "hermes"),
			filepath.Join(homeDir, ".hermes", "bin", "hermes"),
			filepath.Join(homeDir, ".hermes", "hermes-agent", "venv", "bin", "hermes"),
			filepath.Join(homeDir, ".hermes", "hermes-agent", ".venv", "bin", "hermes"),
			filepath.Join(homeDir, ".nix-profile", "bin", "hermes"),
		)
	}
	user := strings.TrimSpace(os.Getenv("USER"))
	if user != "" {
		candidates = append(candidates, filepath.Join("/etc/profiles/per-user", user, "bin", "hermes"))
	}
	candidates = append(candidates,
		"/run/current-system/sw/bin/hermes",
		"/opt/homebrew/bin/hermes",
		"/usr/local/bin/hermes",
		"/usr/local/lib/hermes-agent/venv/bin/hermes",
	)
	prefix := strings.TrimSpace(os.Getenv("PREFIX"))
	if prefix != "" {
		candidates = append(candidates, filepath.Join(prefix, "bin", "hermes"))
	}
	localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
	if localAppData != "" {
		candidates = append(candidates, filepath.Join(localAppData, "hermes", "hermes-agent", "venv", "Scripts", "hermes.exe"))
	}
	return candidates
}

func executableFile(path string) bool {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return false
	}
	info, err := os.Stat(trimmed)
	if err != nil || info.IsDir() {
		return false
	}
	if goruntime.GOOS == "windows" {
		return true
	}
	return info.Mode().Perm()&0o111 != 0
}

func parseHermesToolsList(raw string, nativeMCPServerName string) []NativeCapability {
	const maxHermesToolCapabilities = 40
	out := []NativeCapability{}
	seen := map[string]bool{}
	mcpPrefix := hermesNativeMCPToolPrefix(nativeMCPServerName)
	for _, line := range strings.Split(raw, "\n") {
		id, label, ok := parseHermesToolListLine(line)
		boundedID := boundedCapabilityText(id, 96)
		if !ok || boundedID == "" || seen[boundedID] || hermesToolMatchesPrefix(id, mcpPrefix) {
			continue
		}
		seen[boundedID] = true
		summary := id
		if label != "" && label != id {
			summary = id + " (" + label + ")"
		}
		out = append(out, NativeCapability{
			Source:       NativeCapabilitySourceHermesToolsList,
			Kind:         NativeCapabilityKindNativeTool,
			CapabilityID: boundedID,
			Label:        boundedCapabilityText(firstNonEmpty(label, id), 80),
			Summary:      boundedCapabilityText(summary, 160),
		})
		if len(out) >= maxHermesToolCapabilities {
			break
		}
	}
	return out
}

func hermesMCPServerLoaded(raw string, nativeMCPServerName string) bool {
	serverName := strings.TrimSpace(nativeMCPServerName)
	if serverName == "" {
		return false
	}
	toolPrefix := hermesNativeMCPToolPrefix(serverName)
	inMCPSection := false
	for _, line := range strings.Split(raw, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.EqualFold(trimmed, "MCP servers:") {
			inMCPSection = true
			continue
		}
		if strings.Contains(trimmed, toolPrefix) {
			return true
		}
		if inMCPSection {
			fields := strings.Fields(trimmed)
			if len(fields) > 0 && fields[0] == serverName {
				return true
			}
		}
	}
	return false
}

func hermesNativeMCPToolPrefix(nativeMCPServerName string) string {
	trimmed := strings.TrimSpace(nativeMCPServerName)
	if trimmed == "" {
		return ""
	}
	return "mcp_" + trimmed + "_"
}

func hermesToolMatchesPrefix(toolID string, prefix string) bool {
	return prefix != "" && strings.HasPrefix(strings.TrimSpace(toolID), prefix)
}

func parseHermesToolListLine(line string) (string, string, bool) {
	fields := strings.Fields(strings.TrimSpace(line))
	if len(fields) < 2 {
		return "", "", false
	}
	statusIndex, ok := hermesToolStatusIndex(fields)
	if !ok {
		return "", "", false
	}
	if fields[statusIndex] == "disabled" || statusIndex+1 >= len(fields) {
		return "", "", false
	}
	id := strings.TrimSpace(fields[statusIndex+1])
	if id == "" || id == "MCP" {
		return "", "", false
	}
	label := strings.Join(fields[statusIndex+2:], " ")
	label = strings.TrimSpace(strings.TrimLeftFunc(label, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}))
	return id, label, true
}

func hermesToolStatusIndex(fields []string) (int, bool) {
	for index := 0; index < len(fields) && index < 2; index++ {
		switch fields[index] {
		case "enabled", "disabled":
			return index, true
		}
	}
	return 0, false
}

type hermesRunResponse struct {
	ID    string `json:"id"`
	RunID string `json:"run_id"`
}

type hermesRunEvent struct {
	RunID      string          `json:"run_id"`
	Delta      string          `json:"delta"`
	ToolName   string          `json:"tool_name"`
	ToolPhase  string          `json:"phase"`
	ToolCallID string          `json:"tool_call_id"`
	Type       string          `json:"type"`
	Event      string          `json:"event"`
	Status     string          `json:"status"`
	Output     string          `json:"output"`
	Error      string          `json:"error"`
	Data       json.RawMessage `json:"data"`
}

type hermesRunStatusResponse struct {
	Status string `json:"status"`
	Output string `json:"output"`
	Error  string `json:"error"`
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func selectedHermesEnvironment(home string) []string {
	env := []string{}
	for _, value := range os.Environ() {
		if !strings.HasPrefix(value, "HERMES_HOME=") {
			env = append(env, value)
		}
	}
	if home != "" {
		env = append(env, "HERMES_HOME="+home)
	}
	return env
}

// The native declared-conversation owner resolves its current transcript, including
// compression rotations. Never treat a PersonaStack ID as a native session ID.
func hermesConversationKey(request RunRequest) string {
	if request.ConversationID == "" {
		return ""
	}
	parts := []string{request.NativeMCPToolNamespace, request.ConversationID}
	raw, _ := json.Marshal(parts)
	return fmt.Sprintf("personastack:%x", sha256.Sum256(raw))
}

type hermesRunSubmission struct {
	Input              string            `json:"input"`
	SessionID          string            `json:"session_id,omitempty"`
	NativeMCPServer    string            `json:"native_mcp_server"`
	NativeMCPNamespace string            `json:"native_mcp_namespace"`
	IncludeNativeTools bool              `json:"include_native_tools"`
	Metadata           map[string]string `json:"metadata"`
}
