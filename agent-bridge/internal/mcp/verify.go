package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

type LiveVerifyResult struct {
	OK             bool
	Note           string
	DiagnosticCode string
}

func VerifyBindingLive(ctx context.Context, binding config.Binding, client *http.Client) LiveVerifyResult {
	mcpURL := strings.TrimSpace(binding.PersonaMCPURL)
	token := mcpTokenForBinding(binding)
	if mcpURL == "" || token == "" {
		return LiveVerifyResult{Note: "PersonaStack MCP credential missing", DiagnosticCode: "mcp_token_missing"}
	}
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	session := probeSession{protocolVersion: defaultMCPProtocolVersion}
	proxy := probeHTTPClient{httpClient: client}
	initialize := []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"` + defaultMCPProtocolVersion + `","capabilities":{},"clientInfo":{"name":"personastack-agent-bridge","version":"verify"}}}`)
	raw, err := proxy.forward(ctx, mcpURL, token, initialize, &session, nil)
	if err != nil {
		return LiveVerifyResult{Note: "initialize failed: " + err.Error(), DiagnosticCode: diagnosticCodeForMCPLiveError(err)}
	}
	if err := requireJSONRPCResult(raw, json.RawMessage("1")); err != nil {
		return LiveVerifyResult{Note: "initialize invalid: " + err.Error(), DiagnosticCode: "runtime_error"}
	}
	_, err = proxy.forward(ctx, mcpURL, token, []byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}`), &session, nil)
	if err != nil {
		return LiveVerifyResult{Note: "initialized notification failed: " + err.Error(), DiagnosticCode: diagnosticCodeForMCPLiveError(err)}
	}
	raw, err = proxy.forward(ctx, mcpURL, token, []byte(`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`), &session, nil)
	if err != nil {
		return LiveVerifyResult{Note: "tools/list failed: " + err.Error(), DiagnosticCode: diagnosticCodeForMCPLiveError(err)}
	}
	if err := requireJSONRPCResult(raw, json.RawMessage("2")); err != nil {
		return LiveVerifyResult{Note: "tools/list invalid: " + err.Error(), DiagnosticCode: "runtime_error"}
	}
	if binding.RuntimeKind == runtime.AdapterKindHermes {
		err = requireHermesPersonaTools(raw)
		if err != nil {
			return LiveVerifyResult{Note: err.Error(), DiagnosticCode: "capability_missing"}
		}
	}
	return LiveVerifyResult{OK: true, Note: "PersonaStack MCP endpoint verified"}
}

// These core producer names do not require stack membership. tell_persona is
// conditional and cannot be a prerequisite for a standalone persona.
func requireHermesPersonaTools(raw []byte) error {
	var response struct {
		Result struct {
			Tools *[]struct {
				Name string `json:"name"`
			} `json:"tools"`
		} `json:"result"`
	}
	err := json.Unmarshal(raw, &response)
	if err != nil || response.Result.Tools == nil {
		return fmt.Errorf("PersonaStack MCP tools/list is malformed")
	}
	identity, baseline := false, false
	for _, tool := range *response.Result.Tools {
		identity = identity || tool.Name == "my_persona_info"
		baseline = baseline || tool.Name == "baseline_prompt"
	}
	if !identity || !baseline {
		return fmt.Errorf("PersonaStack MCP core persona tools are unavailable")
	}
	return nil
}

func diagnosticCodeForMCPLiveError(err error) string {
	text := strings.ToLower(err.Error())
	switch {
	case strings.Contains(text, "status 401"), strings.Contains(text, "status 403"):
		return "mcp_token_rejected"
	case strings.Contains(text, "connection refused"), strings.Contains(text, "no such host"), strings.Contains(text, "timeout"), strings.Contains(text, "deadline exceeded"), strings.Contains(text, "post mcp request"):
		return "mcp_endpoint_unreachable"
	default:
		return "runtime_error"
	}
}

func requireJSONRPCResult(raw []byte, requestID json.RawMessage) error {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return fmt.Errorf("empty response")
	}
	var envelope struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Method  string          `json:"method"`
		Result  json.RawMessage `json:"result"`
		Error   json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return err
	}
	if envelope.JSONRPC != "2.0" || envelope.Method != "" || !jsonRawMessagesEqual(envelope.ID, requestID) {
		return fmt.Errorf("response does not match JSON-RPC request")
	}
	if len(envelope.Error) != 0 && !bytes.Equal(bytes.TrimSpace(envelope.Error), []byte("null")) {
		return fmt.Errorf("error response is not a successful result")
	}
	if len(envelope.Result) == 0 || bytes.Equal(bytes.TrimSpace(envelope.Result), []byte("null")) {
		return fmt.Errorf("missing result")
	}
	return nil
}
