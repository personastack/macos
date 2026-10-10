package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"runtime"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const defaultOpenClawGatewayURL = "ws://127.0.0.1:18789"
const minOpenClawProtocolVersion = 3
const maxOpenClawProtocolVersion = 4

type OpenClawAdapter struct {
	StateRoot          string
	ConfigPath         string
	CallNative         func(context.Context, openClawRequest) (openClawResponse, error)
	GatewayURL         string
	Token              string
	Password           string
	DeviceToken        string
	AgentID            string
	SessionOwner       string
	NativeMCPServer    string
	NativeMCPNamespace string
	ReadinessSession   OpenClawSessionIdentity
	MCPAppsEnabled     func() (bool, error)
	DeviceTokenSink    func(string) error
	Dialer             *websocket.Dialer
}

func NewOpenClawAdapter(gatewayURL string, token string) OpenClawAdapter {
	return NewOpenClawAdapterWithAuth(gatewayURL, OpenClawAuth{Token: token}, "")
}

type OpenClawAuth struct {
	Token       string
	Password    string
	DeviceToken string
}

func NewOpenClawAdapterWithAuth(gatewayURL string, auth OpenClawAuth, agentID string) OpenClawAdapter {
	if strings.TrimSpace(gatewayURL) == "" {
		gatewayURL = defaultOpenClawGatewayURL
	}
	return OpenClawAdapter{
		GatewayURL:  strings.TrimSpace(gatewayURL),
		Token:       strings.TrimSpace(auth.Token),
		Password:    strings.TrimSpace(auth.Password),
		DeviceToken: strings.TrimSpace(auth.DeviceToken),
		AgentID:     strings.TrimSpace(agentID),
		Dialer:      websocket.DefaultDialer,
	}
}

func (adapter OpenClawAdapter) Kind() AdapterKind {
	return AdapterKindOpenClaw
}

func (adapter OpenClawAdapter) Detect() Detection {
	ctx, cancel := context.WithTimeout(context.Background(), openClawSetupRetryBudget)
	defer cancel()
	return adapter.DetectContext(ctx)
}

func (adapter OpenClawAdapter) DetectContext(ctx context.Context) Detection {
	if !adapter.hasAuth() {
		return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateAuthMissing, Note: "OpenClaw operator token, password, or device token is required"}
	}
	if adapter.CallNative != nil {
		return adapter.detectWithNativeCaller(ctx)
	}
	conn, err := adapter.connectOperatorWithRetry(ctx)
	if err != nil {
		if openClawConnectErrorIsAuth(err) {
			return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateAuthMissing, Note: "OpenClaw operator credential rejected"}
		}
		if openClawConnectErrorIsCapability(err) {
			return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: err.Error()}
		}
		return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateRuntimeMissing, Note: err.Error()}
	}
	defer conn.Close()
	if err := conn.WriteJSON(openClawRequest{Type: "req", ID: "detect-1", Method: "health"}); err != nil {
		return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateRuntimeStopped, Note: err.Error()}
	}
	var health openClawResponse
	if err := readOpenClawResponse(conn, "detect-1", &health); err != nil {
		return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateRuntimeStopped, Note: err.Error()}
	}
	if errText := health.errorString(); errText != "" {
		return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateRuntimeStopped, Note: errText}
	}
	if _, detection, failed := adapter.probeOpenClawMethod(conn, "detect-2", "status"); failed {
		return detection
	}
	agentsRaw, detection, failed := adapter.probeOpenClawMethod(conn, "detect-3", "agents.list")
	if failed {
		return detection
	}
	agents, err := openClawAgentsFromResult(agentsRaw)
	if err != nil {
		return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: err.Error()}
	}
	if err := adapter.validateAgentSelection(agents); err != nil {
		return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: err.Error()}
	}
	return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateReady, Note: "OpenClaw Gateway reachable"}
}

func (adapter OpenClawAdapter) detectWithNativeCaller(ctx context.Context) Detection {
	for n, method := range []string{"health", "status", "agents.list"} {
		response, err := adapter.callNative(ctx, openClawRequest{Type: "req", ID: fmt.Sprintf("detect-%d", n+1), Method: method})
		if err != nil || !response.isResponseOK() || response.errorString() != "" {
			return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: "selected native capability unavailable"}
		}
		if method == "agents.list" {
			agents, err := openClawAgentsFromResult(response.payload())
			if err != nil {
				return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: "selected native agent unavailable"}
			}
			if err = adapter.validateAgentSelection(agents); err != nil {
				return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: err.Error()}
			}
		}
	}
	return Detection{Kind: AdapterKindOpenClaw, State: AdapterStateReady}
}

func (adapter OpenClawAdapter) probeOpenClawMethod(conn *websocket.Conn, requestID string, method string) (json.RawMessage, Detection, bool) {
	if err := conn.WriteJSON(openClawRequest{Type: "req", ID: requestID, Method: method}); err != nil {
		return nil, Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: err.Error()}, true
	}
	var response openClawResponse
	if err := readOpenClawResponse(conn, requestID, &response); err != nil {
		return nil, Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: err.Error()}, true
	}
	if errText := response.errorString(); errText != "" {
		return nil, Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: errText}, true
	}
	if !response.isResponseOK() {
		return nil, Detection{Kind: AdapterKindOpenClaw, State: AdapterStateCapabilityMissing, Note: "OpenClaw response not ok"}, true
	}
	return response.payload(), Detection{}, false
}

type openClawToolsCatalogResult struct {
	AgentID string                      `json:"agentId"`
	Groups  []openClawToolsCatalogGroup `json:"groups"`
}

type openClawToolsCatalogGroup struct {
	ID       string                     `json:"id"`
	Label    string                     `json:"label"`
	Source   string                     `json:"source"`
	PluginID string                     `json:"pluginId,omitempty"`
	Tools    []openClawToolsCatalogTool `json:"tools"`
}

type openClawToolsCatalogTool struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	Source   string `json:"source"`
	PluginID string `json:"pluginId,omitempty"`
}

type openClawSkillsStatusResult struct {
	Skills []openClawSkillStatus `json:"skills"`
}

type openClawSkillStatus struct {
	ID                  string   `json:"id"`
	Name                string   `json:"name"`
	Key                 string   `json:"key"`
	Slug                string   `json:"slug"`
	Label               string   `json:"label"`
	Title               string   `json:"title"`
	Source              string   `json:"source"`
	SourceID            string   `json:"sourceId"`
	SourceName          string   `json:"sourceName"`
	PluginID            string   `json:"pluginId"`
	PluginName          string   `json:"pluginName"`
	MCPServerName       string   `json:"mcpServerName"`
	Description         string   `json:"description"`
	Summary             string   `json:"summary"`
	Status              string   `json:"status"`
	Eligible            *bool    `json:"eligible"`
	Ready               *bool    `json:"ready"`
	Enabled             *bool    `json:"enabled"`
	MissingRequirements []string `json:"missingRequirements"`
	Missing             []string `json:"missing"`
}

type OpenClawMCPVerificationResult struct {
	OK   bool
	Note string
}

func (adapter OpenClawAdapter) VerifyMCPCatalog(ctx context.Context, serverName string) OpenClawMCPVerificationResult {
	if adapter.ReadinessSession.ID == "" || adapter.ReadinessSession.Key == "" || adapter.ReadinessSession.Key != adapter.OwnedSessionKey("setup", "") {
		return OpenClawMCPVerificationResult{Note: "selected OpenClaw readiness session is not owned by this binding"}
	}
	return adapter.VerifyOwnedMCPSession(ctx, serverName, adapter.ReadinessSession)
}

func (adapter OpenClawAdapter) DescribeNativeCapabilities(ctx context.Context, nativeMCPServerName string) ([]NativeCapability, error) {
	status, err := adapter.fetchOpenClawSkillsStatus(ctx, "native-capabilities-1")
	if err != nil {
		catalog, catalogErr := adapter.fetchOpenClawToolsCatalog(ctx, "native-capabilities-catalog-1")
		if catalogErr != nil {
			return nil, fmt.Errorf("%w; OpenClaw tools.catalog fallback failed: %v", err, catalogErr)
		}
		capabilities := catalog.nativeCapabilitySummaries(nativeMCPServerName)
		if len(capabilities) == 0 {
			capabilities = append(capabilities, nativeCapabilitySource(NativeCapabilitySourceOpenClawToolsCatalog))
		}
		return capabilities, nil
	}
	capabilities := status.nativeCapabilitySummaries(nativeMCPServerName)
	if len(capabilities) == 0 {
		capabilities = append(capabilities, nativeCapabilitySource(NativeCapabilitySourceOpenClawReadySkills))
	}
	return capabilities, nil
}

func (adapter OpenClawAdapter) fetchOpenClawSkillsStatus(ctx context.Context, requestID string) (openClawSkillsStatusResult, error) {
	connectCtx, cancel := context.WithTimeout(ctx, openClawSetupRetryBudget)
	defer cancel()
	conn, err := adapter.connectOperatorWithRetry(connectCtx)
	if err != nil {
		return openClawSkillsStatusResult{}, fmt.Errorf("OpenClaw skills.status connect failed: %w", err)
	}
	defer conn.Close()
	params := map[string]any{}
	if trimmed := strings.TrimSpace(adapter.AgentID); trimmed != "" {
		params["agentId"] = trimmed
	}
	trimmedRequestID := strings.TrimSpace(requestID)
	if trimmedRequestID == "" {
		trimmedRequestID = "skills-status-1"
	}
	err = conn.WriteJSON(openClawRequest{
		Type:   "req",
		ID:     trimmedRequestID,
		Method: "skills.status",
		Params: params,
	})
	if err != nil {
		return openClawSkillsStatusResult{}, fmt.Errorf("OpenClaw skills.status request failed: %w", err)
	}
	var response openClawResponse
	err = readOpenClawResponse(conn, trimmedRequestID, &response)
	if err != nil {
		return openClawSkillsStatusResult{}, fmt.Errorf("OpenClaw skills.status response failed: %w", err)
	}
	if errText := response.errorString(); errText != "" {
		return openClawSkillsStatusResult{}, fmt.Errorf("OpenClaw skills.status error: %s", errText)
	}
	if !response.isResponseOK() {
		return openClawSkillsStatusResult{}, fmt.Errorf("OpenClaw skills.status response not ok")
	}
	status, err := openClawSkillsStatusFromResult(response.payload())
	if err != nil {
		return openClawSkillsStatusResult{}, fmt.Errorf("OpenClaw skills.status invalid: %w", err)
	}
	return status, nil
}

func (adapter OpenClawAdapter) fetchOpenClawToolsCatalog(ctx context.Context, requestID string) (openClawToolsCatalogResult, error) {
	connectCtx, cancel := context.WithTimeout(ctx, openClawSetupRetryBudget)
	defer cancel()
	conn, err := adapter.connectOperatorWithRetry(connectCtx)
	if err != nil {
		return openClawToolsCatalogResult{}, fmt.Errorf("OpenClaw tools.catalog connect failed: %w", err)
	}
	defer conn.Close()
	params := map[string]any{"includePlugins": true}
	if trimmed := strings.TrimSpace(adapter.AgentID); trimmed != "" {
		params["agentId"] = trimmed
	}
	trimmedRequestID := strings.TrimSpace(requestID)
	if trimmedRequestID == "" {
		trimmedRequestID = "tools-catalog-1"
	}
	err = conn.WriteJSON(openClawRequest{
		Type:   "req",
		ID:     trimmedRequestID,
		Method: "tools.catalog",
		Params: params,
	})
	if err != nil {
		return openClawToolsCatalogResult{}, fmt.Errorf("OpenClaw tools.catalog request failed: %w", err)
	}
	var response openClawResponse
	err = readOpenClawResponse(conn, trimmedRequestID, &response)
	if err != nil {
		return openClawToolsCatalogResult{}, fmt.Errorf("OpenClaw tools.catalog response failed: %w", err)
	}
	if errText := response.errorString(); errText != "" {
		return openClawToolsCatalogResult{}, fmt.Errorf("OpenClaw tools.catalog error: %s", errText)
	}
	if !response.isResponseOK() {
		return openClawToolsCatalogResult{}, fmt.Errorf("OpenClaw tools.catalog response not ok")
	}
	catalog, err := openClawToolsCatalogFromResult(response.payload())
	if err != nil {
		return openClawToolsCatalogResult{}, fmt.Errorf("OpenClaw tools.catalog invalid: %w", err)
	}
	return catalog, nil
}

func (adapter OpenClawAdapter) StreamOrPollRun(ctx context.Context, nativeRunID string, handle RunEventHandler) (RunResult, error) {
	return adapter.openClawStreamOrPollRun(ctx, nativeRunID, handle)
}

func (adapter OpenClawAdapter) WaitRun(ctx context.Context, nativeRunID string) (RunResult, error) {
	return adapter.StreamOrPollRun(ctx, nativeRunID, nil)
}

func (adapter OpenClawAdapter) StartRun(runRequest RunRequest) (string, error) {
	assignmentID := strings.TrimSpace(runRequest.AssignmentID)
	if assignmentID == "" {
		return "", fmt.Errorf("OpenClaw assignment id required")
	}
	nativeRunID := assignmentID
	connectCtx, cancel := context.WithTimeout(context.Background(), openClawSetupRetryBudget)
	defer cancel()
	agentID := strings.TrimSpace(adapter.AgentID)
	if agentID == "" || adapter.NativeMCPServer == "" || adapter.NativeMCPNamespace == "" || runRequest.NativeMCPServerName != adapter.NativeMCPServer || runRequest.NativeMCPToolNamespace != adapter.NativeMCPNamespace {
		return "", fmt.Errorf("OpenClaw selected agent and issued MCP scope required")
	}
	conversation := runRequest.ConversationID
	if conversation == "" {
		conversation = "assignment:" + assignmentID
	}
	session, err := adapter.PrepareOwnedMCPSession(connectCtx, "conversation", conversation)
	if err != nil {
		return "", err
	}
	params := openClawAgentSubmission{AgentID: agentID, IdempotencyKey: nativeRunID, Message: strings.TrimSpace(runRequest.FullyComposedPrompt), SessionKey: session.Key, ExpectedExistingSessionID: session.ID, ExpectedExistingSessionLifecycleRevision: session.Revision}
	request := openClawRequest{
		Type:   "req",
		ID:     assignmentID,
		Method: "agent",
		Params: params,
	}
	response, err := adapter.callNative(connectCtx, request)
	if err != nil {
		return "", fmt.Errorf("OpenClaw agent dispatch: %w", err)
	}
	if errText := response.errorString(); errText != "" {
		return "", fmt.Errorf("OpenClaw agent error: %s", errText)
	}
	if !response.isResponseOK() {
		return "", fmt.Errorf("OpenClaw agent response not ok")
	}
	var accepted openClawRunResult
	if payload := response.payload(); len(payload) > 0 {
		_ = json.Unmarshal(payload, &accepted)
	}
	status := strings.ToLower(strings.TrimSpace(accepted.Status))
	if status != "" && status != "accepted" && status != "in_flight" && status != "running" {
		return "", fmt.Errorf("OpenClaw agent rejected with status %q", accepted.Status)
	}
	if accepted.RunID != "" {
		return accepted.RunID, nil
	}
	return "", fmt.Errorf("OpenClaw response missing native run ID")
}

func (adapter OpenClawAdapter) CancelRun(nativeRunID string) error {

	connectCtx, cancel := context.WithTimeout(context.Background(), openClawSetupRetryBudget)
	defer cancel()
	request := openClawRequest{
		Type:   "req",
		ID:     "cancel-" + strings.TrimSpace(nativeRunID),
		Method: "sessions.abort",
		Params: openClawStopRun{RunID: strings.TrimSpace(nativeRunID)},
	}
	response, err := adapter.callNative(connectCtx, request)
	if err != nil {
		return fmt.Errorf("OpenClaw assigned stop: %w", err)
	}
	if errText := response.errorString(); errText != "" {
		return fmt.Errorf("OpenClaw cancel error: %s", errText)
	}
	if !response.isResponseOK() {
		return fmt.Errorf("OpenClaw cancel response not ok")
	}
	return nil
}

func (adapter OpenClawAdapter) Diagnose() Detection {
	return adapter.Detect()
}

func (adapter OpenClawAdapter) dial(ctx context.Context) (*websocket.Conn, error) {
	dialer := adapter.Dialer
	if dialer == nil {
		dialer = websocket.DefaultDialer
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	conn, _, err := dialer.DialContext(ctx, adapter.GatewayURL, http.Header{})
	if err != nil {
		return nil, fmt.Errorf("connect OpenClaw Gateway: %w", err)
	}
	return conn, nil
}

func (adapter OpenClawAdapter) hasAuth() bool {
	return adapter.Token != "" || adapter.Password != "" || adapter.DeviceToken != ""
}

func (adapter OpenClawAdapter) connectOperator(conn *websocket.Conn, ctx context.Context) error {
	setOpenClawDeadline(conn, ctx, 10*time.Second)
	var challenge openClawResponse
	if err := conn.ReadJSON(&challenge); err != nil {
		return fmt.Errorf("read OpenClaw connect challenge: %w", err)
	}
	if !challenge.isEvent("connect.challenge") {
		return fmt.Errorf("expected OpenClaw connect.challenge, got %q", firstNonEmpty(challenge.Event, challenge.Method, challenge.Type))
	}
	auth := map[string]string{}
	switch {
	case adapter.DeviceToken != "":
		auth["deviceToken"] = adapter.DeviceToken
	case adapter.Token != "":
		auth["token"] = adapter.Token
	case adapter.Password != "":
		auth["password"] = adapter.Password
	default:
		return openClawAuthError{message: "OpenClaw operator auth missing"}
	}
	request := openClawRequest{
		Type:   "req",
		ID:     "ps-connect",
		Method: "connect",
		Params: map[string]any{
			"minProtocol": minOpenClawProtocolVersion,
			"maxProtocol": maxOpenClawProtocolVersion,
			"client": map[string]string{
				"id":       "gateway-client",
				"version":  "dev",
				"platform": runtime.GOOS,
				"mode":     "backend",
			},
			"role":   "operator",
			"scopes": []string{"operator.read", "operator.write"},
			"auth":   auth,
		},
	}
	if err := conn.WriteJSON(request); err != nil {
		return fmt.Errorf("write OpenClaw connect: %w", err)
	}
	setOpenClawDeadline(conn, ctx, 10*time.Second)
	var hello openClawResponse
	if err := conn.ReadJSON(&hello); err != nil {
		return fmt.Errorf("read OpenClaw hello-ok: %w", err)
	}
	if errText := hello.errorString(); errText != "" {
		if retryAfter, retryable := hello.retryableStartupSidecars(); retryable {
			_ = conn.Close()
			return openClawRetryableError{info: openClawErrorInfo{
				Code:       "UNAVAILABLE",
				Reason:     "startup-sidecars",
				Message:    errText,
				RetryAfter: retryAfter,
			}}
		}
		return openClawAuthError{message: "OpenClaw operator credential rejected"}
	}
	payload := hello.payload()
	payloadType := openClawPayloadType(payload)
	if !hello.isResponseOK() {
		if retryAfter, retryable := hello.retryableStartupSidecars(); retryable {
			_ = conn.Close()
			return openClawRetryableError{info: openClawErrorInfo{
				Code:       "UNAVAILABLE",
				Reason:     "startup-sidecars",
				Message:    firstNonEmpty(hello.errorString(), "OpenClaw connect response not ok"),
				RetryAfter: retryAfter,
			}}
		}
		return fmt.Errorf("OpenClaw connect response not ok")
	}
	helloResult, err := openClawHelloFromResult(payload)
	if err != nil && payloadType != "hello-ok" && hello.Method != "hello-ok" && hello.Type != "hello-ok" {
		return fmt.Errorf("expected OpenClaw hello-ok, got %q", firstNonEmpty(payloadType, hello.Event, hello.Method, hello.Type))
	}
	if err != nil {
		return err
	}
	if !helloResult.hasScope("operator.read") || !helloResult.hasScope("operator.write") {
		return openClawAuthError{message: "OpenClaw operator.read and operator.write scopes required"}
	}
	missing := helloResult.Features.missingRequiredMethods()
	if len(missing) > 0 {
		return fmt.Errorf("%s missing", strings.Join(missing, ","))
	}
	if helloResult.Auth.DeviceToken != "" && adapter.DeviceTokenSink != nil {
		if err := adapter.DeviceTokenSink(helloResult.Auth.DeviceToken); err != nil {
			return fmt.Errorf("store OpenClaw device token: %w", err)
		}
	}
	return nil
}

type openClawAuthError struct {
	message string
}

func (err openClawAuthError) Error() string {
	return err.message
}

func setOpenClawDeadline(conn *websocket.Conn, ctx context.Context, fallback time.Duration) {
	deadline := time.Now().Add(fallback)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	_ = conn.SetReadDeadline(deadline)
	_ = conn.SetWriteDeadline(deadline)
}

type openClawRequest struct {
	Type   string `json:"type,omitempty"`
	ID     string `json:"id"`
	Method string `json:"method"`
	Params any    `json:"params,omitempty"`
}

// These aliases expose the existing typed in-process transport seam to helper
// owners without introducing a second wire representation.
type OpenClawRequest = openClawRequest
type OpenClawResponse = openClawResponse

type openClawResponse struct {
	OK      *bool           `json:"ok,omitempty"`
	Type    string          `json:"type,omitempty"`
	ID      string          `json:"id"`
	Event   string          `json:"event,omitempty"`
	Method  string          `json:"method,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   any             `json:"error,omitempty"`
}

func (response openClawResponse) payload() json.RawMessage {
	if len(response.Payload) > 0 {
		return response.Payload
	}
	return response.Result
}

func (response openClawResponse) isEvent(event string) bool {
	return response.Type == "event" && response.Event == event || response.Type == event || response.Method == event
}

func readOpenClawResponse(conn *websocket.Conn, requestID string, response *openClawResponse) error {
	for {
		var next openClawResponse
		if err := conn.ReadJSON(&next); err != nil {
			return err
		}
		if next.Type == "event" && next.ID == "" {
			continue
		}
		if requestID == "" || next.ID == requestID {
			*response = next
			return nil
		}
	}
}

func (response openClawResponse) isResponseOK() bool {
	if response.OK != nil && !*response.OK {
		return false
	}
	if response.Type == "res" {
		return response.OK != nil && *response.OK
	}
	return response.Type == "" || response.Type == "hello-ok" || response.Type == "hello"
}

func (response openClawResponse) errorString() string {
	switch value := response.Error.(type) {
	case nil:
		return ""
	case string:
		return strings.TrimSpace(value)
	case map[string]any:
		for _, key := range []string{"message", "reason", "code"} {
			if raw, ok := value[key]; ok && strings.TrimSpace(fmt.Sprint(raw)) != "" {
				return strings.TrimSpace(fmt.Sprint(raw))
			}
		}
	}
	return strings.TrimSpace(fmt.Sprint(response.Error))
}

func openClawPayloadType(raw json.RawMessage) string {
	var envelope struct {
		Type string `json:"type"`
	}
	_ = json.Unmarshal(raw, &envelope)
	return strings.TrimSpace(envelope.Type)
}

type openClawRunResult struct {
	RunID  string `json:"runId"`
	Status string `json:"status"`
	Output string `json:"output"`
	Error  string `json:"error"`
}

type openClawHello struct {
	Protocol int              `json:"protocol"`
	Role     string           `json:"role"`
	Scopes   []string         `json:"scopes"`
	Features openClawFeatures `json:"features"`
	Auth     struct {
		DeviceToken string `json:"deviceToken"`
	} `json:"auth"`
}

type openClawAgent struct {
	ID       string `json:"id"`
	Enabled  *bool  `json:"enabled"`
	Disabled bool   `json:"disabled"`
}

type openClawFeatures struct {
	methods map[string]struct{}
}

func openClawFeaturesFromResult(raw json.RawMessage) (openClawFeatures, error) {
	var envelope struct {
		Methods any `json:"methods"`
	}
	if len(raw) == 0 {
		return openClawFeatures{}, fmt.Errorf("features missing")
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return openClawFeatures{}, err
	}
	return openClawFeaturesFromAny(envelope.Methods)
}

func openClawHelloFromResult(raw json.RawMessage) (openClawHello, error) {
	var hello openClawHello
	if len(raw) == 0 {
		return hello, fmt.Errorf("hello-ok result missing")
	}
	var envelope struct {
		Protocol int `json:"protocol"`
		Features struct {
			Methods any `json:"methods"`
		} `json:"features"`
		Auth struct {
			DeviceToken string   `json:"deviceToken"`
			Role        string   `json:"role"`
			Scopes      []string `json:"scopes"`
		} `json:"auth"`
		Role   string   `json:"role"`
		Scopes []string `json:"scopes"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return hello, err
	}
	if envelope.Protocol < minOpenClawProtocolVersion || envelope.Protocol > maxOpenClawProtocolVersion {
		return hello, fmt.Errorf("OpenClaw protocol %d unsupported", envelope.Protocol)
	}
	features, err := openClawFeaturesFromAny(envelope.Features.Methods)
	if err != nil {
		return hello, err
	}
	hello.Protocol = envelope.Protocol
	hello.Role = strings.TrimSpace(firstNonEmpty(envelope.Role, envelope.Auth.Role))
	hello.Scopes = envelope.Scopes
	if len(hello.Scopes) == 0 {
		hello.Scopes = envelope.Auth.Scopes
	}
	hello.Features = features
	hello.Auth.DeviceToken = strings.TrimSpace(envelope.Auth.DeviceToken)
	return hello, nil
}

func openClawFeaturesFromAny(value any) (openClawFeatures, error) {
	methods := map[string]struct{}{}
	switch value := value.(type) {
	case []any:
		for _, entry := range value {
			method := strings.TrimSpace(fmt.Sprint(entry))
			if method != "" {
				methods[method] = struct{}{}
			}
		}
	case map[string]any:
		for key, rawEnabled := range value {
			enabled, ok := rawEnabled.(bool)
			if ok && enabled {
				methods[strings.TrimSpace(key)] = struct{}{}
			}
		}
	default:
		return openClawFeatures{}, fmt.Errorf("features.methods missing")
	}
	return openClawFeatures{methods: methods}, nil
}

func openClawToolsCatalogFromResult(raw json.RawMessage) (openClawToolsCatalogResult, error) {
	var catalog openClawToolsCatalogResult
	if len(raw) == 0 {
		return catalog, fmt.Errorf("catalog missing")
	}
	if err := json.Unmarshal(raw, &catalog); err != nil {
		return catalog, err
	}
	return catalog, nil
}

func openClawSkillsStatusFromResult(raw json.RawMessage) (openClawSkillsStatusResult, error) {
	if len(raw) == 0 {
		return openClawSkillsStatusResult{}, fmt.Errorf("skills status missing")
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return openClawSkillsStatusResult{}, fmt.Errorf("skills status missing")
	}
	var array []openClawSkillStatus
	if err := json.Unmarshal(raw, &array); err == nil {
		return openClawSkillsStatusResult{Skills: array}, nil
	}
	var envelope struct {
		Skills *[]openClawSkillStatus `json:"skills"`
		Items  *[]openClawSkillStatus `json:"items"`
		Data   *[]openClawSkillStatus `json:"data"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return openClawSkillsStatusResult{}, err
	}
	skills, ok := firstOpenClawSkillList(envelope.Skills, envelope.Items, envelope.Data)
	if !ok {
		return openClawSkillsStatusResult{}, fmt.Errorf("skills status missing known skill list")
	}
	return openClawSkillsStatusResult{Skills: skills}, nil
}

func firstOpenClawSkillList(values ...*[]openClawSkillStatus) ([]openClawSkillStatus, bool) {
	for _, value := range values {
		if value != nil {
			return *value, true
		}
	}
	return nil, false
}

func (catalog openClawToolsCatalogResult) nativeCapabilitySummaries(nativeMCPServerName string) []NativeCapability {
	const maxOpenClawCapabilityGroups = 20
	out := []NativeCapability{}
	seen := map[string]bool{}
	for _, group := range catalog.Groups {
		if group.matchesNativeMCPServer(nativeMCPServerName) {
			continue
		}
		toolCount := len(group.Tools)
		if toolCount == 0 {
			continue
		}
		id := boundedCapabilityText(firstNonEmpty(group.PluginID, group.ID), 96)
		label := boundedCapabilityText(firstNonEmpty(group.Label, group.ID, group.PluginID), 80)
		if id == "" || label == "" || seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, NativeCapability{
			Source:       NativeCapabilitySourceOpenClawToolsCatalog,
			Kind:         NativeCapabilityKindToolGroup,
			CapabilityID: id,
			Label:        label,
			Summary:      boundedCapabilityText(fmt.Sprintf("%s (%d OpenClaw tools)", label, toolCount), 160),
		})
		if len(out) >= maxOpenClawCapabilityGroups {
			break
		}
	}
	return out
}

func (status openClawSkillsStatusResult) nativeCapabilitySummaries(nativeMCPServerName string) []NativeCapability {
	const maxOpenClawSkillCapabilities = 40
	out := []NativeCapability{}
	seen := map[string]bool{}
	for _, skill := range status.Skills {
		if !skill.ready() {
			continue
		}
		if skill.matchesNativeMCPServer(nativeMCPServerName) {
			continue
		}
		id := boundedCapabilityText(firstNonEmpty(skill.ID, skill.Key, skill.Slug, skill.Name), 96)
		label := boundedCapabilityText(firstNonEmpty(skill.Label, skill.Title, skill.Name, skill.Slug, skill.ID), 80)
		if id == "" || label == "" || seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, NativeCapability{
			Source:       NativeCapabilitySourceOpenClawReadySkills,
			Kind:         NativeCapabilityKindSkill,
			CapabilityID: id,
			Label:        label,
			Summary:      boundedCapabilityText(firstNonEmpty(skill.Summary, skill.Description, label), 160),
		})
		if len(out) >= maxOpenClawSkillCapabilities {
			break
		}
	}
	return out
}

func (skill openClawSkillStatus) ready() bool {
	if skill.Enabled != nil && !*skill.Enabled {
		return false
	}
	if hasOpenClawMissingRequirements(skill.MissingRequirements) || hasOpenClawMissingRequirements(skill.Missing) {
		return false
	}
	if skill.Ready != nil {
		return *skill.Ready
	}
	switch strings.ToLower(strings.TrimSpace(skill.Status)) {
	case "ready":
		return true
	default:
		return false
	}
}

func (skill openClawSkillStatus) matchesNativeMCPServer(nativeMCPServerName string) bool {
	target := strings.ToLower(strings.TrimSpace(nativeMCPServerName))
	if target == "" {
		return false
	}
	for _, value := range []string{
		skill.ID,
		skill.Key,
		skill.Slug,
		skill.Name,
		skill.Label,
		skill.Title,
		skill.Source,
		skill.SourceID,
		skill.SourceName,
		skill.PluginID,
		skill.PluginName,
		skill.MCPServerName,
	} {
		trimmed := strings.ToLower(strings.TrimSpace(value))
		if trimmed == target || trimmed == "plugin:"+target {
			return true
		}
	}
	return false
}

func hasOpenClawMissingRequirements(values []string) bool {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return true
		}
	}
	return false
}

func (group openClawToolsCatalogGroup) matchesNativeMCPServer(nativeMCPServerName string) bool {
	target := strings.TrimSpace(nativeMCPServerName)
	if target == "" {
		return false
	}
	return strings.TrimSpace(group.PluginID) == target || strings.TrimSpace(group.Label) == target || strings.TrimSpace(group.ID) == "plugin:"+target
}

func boundedCapabilityText(value string, limit int) string {
	trimmed := strings.TrimSpace(value)
	if limit <= 0 {
		return trimmed
	}
	count := 0
	for idx := range trimmed {
		if count == limit {
			return strings.TrimSpace(trimmed[:idx])
		}
		count++
	}
	return trimmed
}

func (hello openClawHello) hasScope(scope string) bool {
	for _, candidate := range hello.Scopes {
		if strings.TrimSpace(candidate) == scope {
			return true
		}
	}
	return false
}

func openClawAgentsFromResult(raw json.RawMessage) ([]openClawAgent, error) {
	var envelope struct {
		Agents []openClawAgent `json:"agents"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, err
	}
	return envelope.Agents, nil
}

func (adapter OpenClawAdapter) validateAgentSelection(agents []openClawAgent) error {
	if adapter.AgentID != "" {
		for _, agent := range agents {
			if strings.TrimSpace(agent.ID) == adapter.AgentID && openClawAgentUsable(agent) {
				return nil
			}
		}
		return fmt.Errorf("configured OpenClaw agent %q not found", adapter.AgentID)
	}
	usable := 0
	for _, agent := range agents {
		if openClawAgentUsable(agent) {
			usable++
		}
	}
	if usable == 1 {
		return nil
	}
	if usable == 0 {
		return fmt.Errorf("no usable OpenClaw agents")
	}
	return fmt.Errorf("agent_selection_required")
}

func openClawAgentUsable(agent openClawAgent) bool {
	if strings.TrimSpace(agent.ID) == "" || agent.Disabled {
		return false
	}
	return agent.Enabled == nil || *agent.Enabled
}

func openClawRunResultFromResponse(raw json.RawMessage) (openClawRunResult, bool, error) {
	var result openClawRunResult
	err := json.Unmarshal(raw, &result)
	if err != nil {
		return openClawRunResult{}, false, fmt.Errorf("decode OpenClaw wait result: %w", err)
	}
	switch strings.ToLower(strings.TrimSpace(result.Status)) {
	case "completed", "success", "succeeded", "failed", "error", "cancelled", "canceled", "aborted", "timeout":
		return result, true, nil
	default:
		return result, false, nil
	}
}

func openClawErrorIsTimeout(value string) bool {
	return strings.Contains(strings.ToLower(value), "timeout")
}

func openClawConnectErrorIsCapability(err error) bool {
	message := strings.ToLower(err.Error())
	return strings.Contains(message, " missing") || strings.Contains(message, "protocol") || strings.Contains(message, "features.")
}

func openClawConnectErrorIsAuth(err error) bool {
	var authErr openClawAuthError
	if errors.As(err, &authErr) {
		return true
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "unauthorized") ||
		strings.Contains(message, "forbidden") ||
		strings.Contains(message, "invalid token") ||
		strings.Contains(message, "invalid auth") ||
		strings.Contains(message, "invalid credential") ||
		strings.Contains(message, "authentication")
}

func (features openClawFeatures) missingRequiredMethods() []string {
	required := []string{"health", "status", "agents.list", "agent", "agent.wait", "sessions.abort"}
	missing := []string{}
	for _, method := range required {
		if _, ok := features.methods[method]; !ok {
			missing = append(missing, method)
		}
	}
	return missing
}

func (adapter OpenClawAdapter) callNative(ctx context.Context, request openClawRequest) (openClawResponse, error) {
	if adapter.CallNative != nil {
		return adapter.CallNative(ctx, request)
	}
	conn, err := adapter.connectOperatorWithRetry(ctx)
	if err != nil {
		return openClawResponse{}, err
	}
	defer conn.Close()
	err = conn.WriteJSON(request)
	if err != nil {
		return openClawResponse{}, fmt.Errorf("write native gateway request: %w", err)
	}
	var response openClawResponse
	err = readOpenClawResponse(conn, request.ID, &response)
	if err != nil {
		return openClawResponse{}, fmt.Errorf("read native gateway response: %w", err)
	}
	return response, nil
}

type openClawAgentSubmission struct {
	AgentID                                  string `json:"agentId"`
	IdempotencyKey                           string `json:"idempotencyKey"`
	Message                                  string `json:"message"`
	SessionKey                               string `json:"sessionKey"`
	ExpectedExistingSessionID                string `json:"expectedExistingSessionId"`
	ExpectedExistingSessionLifecycleRevision string `json:"expectedExistingSessionLifecycleRevision,omitempty"`
}
type openClawStopRun struct {
	RunID string `json:"runId"`
}
