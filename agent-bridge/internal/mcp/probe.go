package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"

	"github.com/personastack/macos/agent-bridge/internal/config"
)

var ErrMissingBinding = errors.New("missing binding")
var ErrMissingMCPToken = errors.New("missing persona mcp token")

const defaultMCPProtocolVersion = "2025-11-25"

type probeHTTPClient struct {
	httpClient *http.Client
}

type probeSession struct {
	sessionID       string
	protocolVersion string
	initialized     bool
}

type lockedLineWriter struct {
	mu     sync.Mutex
	writer io.Writer
}

type rpcMessage struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
}

type initializeResult struct {
	ProtocolVersion string `json:"protocolVersion"`
}

func mcpTokenForBinding(binding config.Binding) string {
	return strings.TrimSpace(binding.PersonaMCPToken)
}

func (proxy probeHTTPClient) httpClientOrDefault() *http.Client {
	if proxy.httpClient != nil {
		return proxy.httpClient
	}
	return http.DefaultClient
}

func (proxy probeHTTPClient) forward(ctx context.Context, mcpURL string, token string, payload []byte, session *probeSession, output *lockedLineWriter) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var message rpcMessage
	if err := json.Unmarshal(payload, &message); err != nil {
		return nil, fmt.Errorf("decode MCP probe message: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, mcpURL, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Authorization", "Bearer "+token)
	if session.sessionID != "" {
		req.Header.Set("MCP-Session-Id", session.sessionID)
	}
	if session.initialized || session.sessionID != "" {
		req.Header.Set("MCP-Protocol-Version", session.protocolVersion)
	}
	resp, err := proxy.httpClientOrDefault().Do(req)
	if err != nil {
		return nil, fmt.Errorf("post mcp request: %w", err)
	}
	defer resp.Body.Close()
	progressOutput := output
	if resp.StatusCode >= 300 {
		progressOutput = nil
	}
	raw, err := readMCPHTTPResponse(resp, message.ID, toolCallProgressToken(message.Method, payload), progressOutput)
	if err != nil {
		return nil, fmt.Errorf("read mcp response: %w", err)
	}
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("mcp status %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	session.updateFromResponseHeaders(resp.Header)
	session.updateFromMessages(message, raw)
	return raw, nil
}

func readMCPHTTPResponse(resp *http.Response, requestID json.RawMessage, progressToken json.RawMessage, output *lockedLineWriter) ([]byte, error) {
	if strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "text/event-stream") {
		return readSSEJSONPayloads(resp.Body, requestID, progressToken, output)
	}
	return io.ReadAll(resp.Body)
}

func (writer *lockedLineWriter) writeLine(payload []byte) error {
	if writer == nil || writer.writer == nil || len(payload) == 0 {
		return nil
	}
	writer.mu.Lock()
	defer writer.mu.Unlock()
	if _, err := writer.writer.Write(payload); err != nil {
		return fmt.Errorf("write mcp response: %w", err)
	}
	if payload[len(payload)-1] != '\n' {
		if _, err := writer.writer.Write([]byte("\n")); err != nil {
			return fmt.Errorf("write mcp response newline: %w", err)
		}
	}
	return nil
}

type sseEvent struct {
	ID    string
	Event string
	Data  []string
}

func (event sseEvent) dataPayload() []byte {
	return []byte(strings.Join(event.Data, "\n"))
}

func toolCallProgressToken(method string, payload []byte) json.RawMessage {
	if method != "tools/call" {
		return nil
	}
	var request struct {
		Params struct {
			Meta struct {
				ProgressToken json.RawMessage `json:"progressToken"`
			} `json:"_meta"`
		} `json:"params"`
	}
	if json.Unmarshal(payload, &request) != nil {
		return nil
	}
	token := request.Params.Meta.ProgressToken
	if len(token) == 0 || bytes.Equal(token, []byte("null")) || bytes.Equal(token, []byte(`""`)) {
		return nil
	}
	return token
}

func readSSEJSONPayloads(body io.Reader, requestID json.RawMessage, progressToken json.RawMessage, output *lockedLineWriter) ([]byte, error) {
	var response []byte
	err := readSSEStream(body, func(event sseEvent) error {
		payload := event.dataPayload()
		ok, err := event.isJSONRPCPayload()
		if err != nil {
			return err
		}
		if !ok {
			return nil
		}
		if progressTokenMatches(payload, progressToken) {
			if output != nil {
				return output.writeLine(payload)
			}
			return nil
		}
		if !jsonRPCPayloadMatchesRequestID(payload, requestID) {
			return nil
		}
		response = append(response, payload...)
		return io.EOF
	})
	if errors.Is(err, io.EOF) {
		return response, nil
	}
	if err == nil && len(response) == 0 {
		return nil, fmt.Errorf("mcp SSE response ended without JSON-RPC event matching request")
	}
	return response, err
}

func progressTokenMatches(payload []byte, requestToken json.RawMessage) bool {
	if len(requestToken) == 0 {
		return false
	}
	var notification struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Method  string          `json:"method"`
		Params  struct {
			ProgressToken json.RawMessage `json:"progressToken"`
		} `json:"params"`
	}
	if json.Unmarshal(payload, &notification) != nil {
		return false
	}
	return notification.JSONRPC == "2.0" && len(notification.ID) == 0 && notification.Method == "notifications/progress" &&
		len(notification.Params.ProgressToken) > 0 && jsonRawMessagesEqual(notification.Params.ProgressToken, requestToken)
}

func jsonRPCPayloadMatchesRequestID(payload []byte, requestID json.RawMessage) bool {
	if len(requestID) == 0 {
		return true
	}
	var envelope struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		return false
	}
	if len(envelope.ID) == 0 || envelope.Method != "" {
		return false
	}
	return jsonRawMessagesEqual(envelope.ID, requestID)
}

func jsonRawMessagesEqual(left json.RawMessage, right json.RawMessage) bool {
	var leftBuffer bytes.Buffer
	if err := json.Compact(&leftBuffer, left); err != nil {
		return false
	}
	var rightBuffer bytes.Buffer
	if err := json.Compact(&rightBuffer, right); err != nil {
		return false
	}
	return bytes.Equal(leftBuffer.Bytes(), rightBuffer.Bytes())
}

func (event sseEvent) isJSONRPCPayload() (bool, error) {
	payload := event.dataPayload()
	if isJSONRPCPayload(payload) {
		return true, nil
	}
	if jsonRPCPayloadMalformed(payload) {
		return false, fmt.Errorf("mcp SSE event contained malformed JSON-RPC-looking payload")
	}
	return false, nil
}

func isJSONRPCPayload(payload []byte) bool {
	if !json.Valid(payload) {
		return false
	}
	var envelope struct {
		JSONRPC string `json:"jsonrpc"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		return false
	}
	return strings.TrimSpace(envelope.JSONRPC) != ""
}

func jsonRPCPayloadMalformed(payload []byte) bool {
	trimmed := bytes.TrimSpace(payload)
	if len(trimmed) == 0 {
		return false
	}
	if !json.Valid(trimmed) {
		return trimmed[0] == '{' || bytes.Contains(trimmed, []byte("jsonrpc"))
	}
	if trimmed[0] != '{' {
		return false
	}
	var envelope struct {
		JSONRPC *string         `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Method  string          `json:"method"`
		Result  json.RawMessage `json:"result"`
		Error   json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal(trimmed, &envelope); err != nil {
		return true
	}
	if envelope.JSONRPC != nil {
		return strings.TrimSpace(*envelope.JSONRPC) == ""
	}
	return len(envelope.ID) > 0 || strings.TrimSpace(envelope.Method) != "" || len(envelope.Result) > 0 || len(envelope.Error) > 0
}

func readSSEStream(body io.Reader, handle func(sseEvent) error) error {
	scanner := bufio.NewScanner(body)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	var event sseEvent
	var eventData []string
	flush := func() error {
		if len(eventData) == 0 {
			return nil
		}
		event.Data = eventData
		eventData = nil
		err := handle(event)
		event = sseEvent{}
		return err
	}
	for scanner.Scan() {
		line := strings.TrimSuffix(scanner.Text(), "\r")
		if line == "" {
			if err := flush(); err != nil {
				return err
			}
			continue
		}
		if strings.HasPrefix(line, ":") {
			continue
		}
		if strings.HasPrefix(line, "id:") {
			event.ID = strings.TrimSpace(strings.TrimPrefix(line, "id:"))
			continue
		}
		if strings.HasPrefix(line, "event:") {
			event.Event = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
			continue
		}
		if strings.HasPrefix(line, "data:") {
			eventData = append(eventData, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		}
	}
	if err := flush(); err != nil {
		return err
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return nil
}

func (session *probeSession) updateFromResponseHeaders(headers http.Header) {
	sessionID := strings.TrimSpace(headers.Get("MCP-Session-Id"))
	if sessionID != "" {
		session.sessionID = sessionID
	}
}

func (session *probeSession) updateFromMessages(request rpcMessage, response []byte) {
	if request.Method == "notifications/initialized" {
		session.initialized = true
		return
	}
	if request.Method != "initialize" || len(response) == 0 {
		return
	}
	var envelope rpcMessage
	if err := json.Unmarshal(response, &envelope); err != nil {
		return
	}
	var result initializeResult
	if err := json.Unmarshal(envelope.Result, &result); err != nil {
		return
	}
	if strings.TrimSpace(result.ProtocolVersion) != "" {
		session.protocolVersion = strings.TrimSpace(result.ProtocolVersion)
	}
}
