package mcp

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

type verifyContractRoundTripper func(*http.Request) (*http.Response, error)

func (roundTripper verifyContractRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return roundTripper(request)
}

func TestDesktopAgentBridgeVerifyBindingLiveContractMapsMCPHandshake(t *testing.T) {
	t.Parallel()

	requests := []struct {
		method       string
		body         string
		sessionID    string
		protocol     string
		responseCode int
		responseBody string
	}{
		{
			method:       http.MethodPost,
			body:         `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"personastack-agent-bridge","version":"verify"}}}`,
			responseCode: http.StatusOK,
			responseBody: `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{}}}`,
		},
		{
			method:       http.MethodPost,
			body:         `{"jsonrpc":"2.0","method":"notifications/initialized"}`,
			sessionID:    "session-1",
			protocol:     defaultMCPProtocolVersion,
			responseCode: http.StatusAccepted,
		},
		{
			method:       http.MethodPost,
			body:         `{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`,
			sessionID:    "session-1",
			protocol:     defaultMCPProtocolVersion,
			responseCode: http.StatusOK,
			responseBody: `{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}`,
		},
	}
	call := 0
	client := &http.Client{Transport: verifyContractRoundTripper(func(request *http.Request) (*http.Response, error) {
		if call >= len(requests) {
			t.Fatalf("unexpected request %s %s", request.Method, request.URL)
		}
		want := requests[call]
		call++
		if request.URL.String() != "https://mcp.example.test/mcp" {
			t.Fatalf("URL = %q", request.URL)
		}
		if request.Method != want.method {
			t.Fatalf("method = %q, want %q", request.Method, want.method)
		}
		if request.Header.Get("Authorization") != "Bearer mcp-token" {
			t.Fatalf("authorization = %q", request.Header.Get("Authorization"))
		}
		if request.Header.Get("Content-Type") != "application/json" || request.Header.Get("Accept") != "application/json, text/event-stream" {
			t.Fatalf("content negotiation headers = %+v", request.Header)
		}
		if request.Header.Get("MCP-Session-Id") != want.sessionID || request.Header.Get("MCP-Protocol-Version") != want.protocol {
			t.Fatalf("MCP session headers = %+v", request.Header)
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		if !jsonRawMessagesEqual(body, []byte(want.body)) {
			t.Fatalf("request body = %s, want %s", body, want.body)
		}
		headers := make(http.Header)
		headers.Set("Content-Type", "application/json")
		if call == 1 {
			headers.Set("MCP-Session-Id", "session-1")
		}
		return &http.Response{
			StatusCode: want.responseCode,
			Header:     headers,
			Body:       io.NopCloser(bytes.NewBufferString(want.responseBody)),
			Request:    request,
		}, nil
	})}

	result := VerifyBindingLive(context.Background(), config.Binding{
		PersonaMCPURL:   "https://mcp.example.test/mcp",
		PersonaMCPToken: "mcp-token",
	}, client)
	want := LiveVerifyResult{OK: true, Note: "PersonaStack MCP endpoint verified"}
	if result != want {
		t.Fatalf("VerifyBindingLive() = %+v, want %+v", result, want)
	}
	if call != len(requests) {
		t.Fatalf("request count = %d, want %d", call, len(requests))
	}
}

func TestDesktopAgentBridgeVerifyBindingLiveContractRejectsMissingCredentialWithoutRequest(t *testing.T) {
	t.Parallel()

	client := &http.Client{Transport: verifyContractRoundTripper(func(request *http.Request) (*http.Response, error) {
		t.Fatalf("unexpected request %s %s", request.Method, request.URL)
		return nil, nil
	})}
	result := VerifyBindingLive(context.Background(), config.Binding{PersonaMCPURL: "https://mcp.example.test/mcp"}, client)
	want := LiveVerifyResult{Note: "PersonaStack MCP credential missing", DiagnosticCode: "mcp_token_missing"}
	if result != want {
		t.Fatalf("VerifyBindingLive() = %+v, want %+v", result, want)
	}
}

func TestDesktopAgentBridgeVerifyBindingLiveContractStopsAfterAuthenticationRejection(t *testing.T) {
	t.Parallel()

	call := 0
	client := &http.Client{Transport: verifyContractRoundTripper(func(request *http.Request) (*http.Response, error) {
		call++
		if request.Method != http.MethodPost || request.URL.String() != "https://mcp.example.test/mcp" {
			t.Fatalf("request = %s %s", request.Method, request.URL)
		}
		if request.Header.Get("Authorization") != "Bearer rejected-token" {
			t.Fatalf("authorization = %q", request.Header.Get("Authorization"))
		}
		return &http.Response{
			StatusCode: http.StatusUnauthorized,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(bytes.NewBufferString(`{"error":"invalid token"}`)),
			Request:    request,
		}, nil
	})}

	result := VerifyBindingLive(context.Background(), config.Binding{
		PersonaMCPURL:   "https://mcp.example.test/mcp",
		PersonaMCPToken: "rejected-token",
	}, client)
	if result.OK || result.DiagnosticCode != "mcp_token_rejected" {
		t.Fatalf("VerifyBindingLive() = %+v", result)
	}
	if call != 1 {
		t.Fatalf("request count = %d, want 1", call)
	}
}

func TestDesktopAgentBridgeDirectMCPRejectsErrorOrMalformedSuccessBothRuntimes(t *testing.T) {
	t.Parallel()
	const core = `{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"my_persona_info"},{"name":"baseline_prompt"}]}}`
	for _, kind := range []runtime.AdapterKind{runtime.AdapterKindHermes, runtime.AdapterKindOpenClaw} {
		t.Run(kind.String(), func(t *testing.T) {
			t.Parallel()
			for _, tc := range []struct {
				name, response string
				stage          int
				ok             bool
			}{
				{name: "success", response: core, stage: 3, ok: true},
				{name: "null error is not failure", response: `{"jsonrpc":"2.0","id":2,"error":null,"result":{"tools":[{"name":"my_persona_info"},{"name":"baseline_prompt"}]}}`, stage: 3, ok: true},
				{name: "initialize error with result", response: `{"jsonrpc":"2.0","id":1,"error":{"code":-32000},"result":{}}`, stage: 1},
				{name: "tools error with result", response: `{"jsonrpc":"2.0","id":2,"error":{"code":-32000},"result":{"tools":[{"name":"my_persona_info"},{"name":"baseline_prompt"}]}}`, stage: 3},
				{name: "tools error only", response: `{"jsonrpc":"2.0","id":2,"error":{"code":-32000}}`, stage: 3},
				{name: "malformed tools", response: `{"jsonrpc":"2.0","id":2,`, stage: 3},
				{name: "result missing", response: `{"jsonrpc":"2.0","id":2}`, stage: 3},
			} {
				t.Run(tc.name, func(t *testing.T) {
					t.Parallel()
					calls := 0
					client := &http.Client{Transport: verifyContractRoundTripper(func(req *http.Request) (*http.Response, error) {
						calls++
						if calls > tc.stage || req.Method != http.MethodPost || req.URL.String() != "https://mcp.example.test/mcp" || req.Header.Get("Authorization") != "Bearer token" {
							t.Fatal("unplanned direct MCP request")
						}
						status, response := http.StatusOK, `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}`
						if calls == 2 {
							status, response = http.StatusAccepted, ""
						}
						if calls == tc.stage {
							response = tc.response
						}
						return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(bytes.NewBufferString(response)), Request: req}, nil
					})}
					result := VerifyBindingLive(context.Background(), config.Binding{RuntimeKind: kind, PersonaMCPURL: "https://mcp.example.test/mcp", PersonaMCPToken: "token"}, client)
					if result.OK != tc.ok || calls != tc.stage || (!tc.ok && result.DiagnosticCode != "runtime_error") {
						t.Fatalf("direct result %+v calls%d", result, calls)
					}
				})
			}
		})
	}
}

type directMCPEnvelopeFixture struct {
	name, contentType, response string
	kind                        runtime.AdapterKind
	stage                       int
	valid                       bool
}

func directMCPEnvelopeFixtures() []directMCPEnvelopeFixture {
	fixtures := []directMCPEnvelopeFixture{}
	for _, stage := range []int{1, 3} {
		id, result := 1, `{"protocolVersion":"2025-11-25"}`
		if stage == 3 {
			id, result = 2, `{"tools":[{"name":"my_persona_info"},{"name":"baseline_prompt"}]}`
		}
		envelopes := []struct {
			name, response string
			valid          bool
		}{
			{"valid", fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"result":%s}`, id, result), true},
			{"wrong id", fmt.Sprintf(`{"jsonrpc":"2.0","id":99,"result":%s}`, result), false},
			{"missing id", fmt.Sprintf(`{"jsonrpc":"2.0","result":%s}`, result), false},
			{"wrong protocol", fmt.Sprintf(`{"jsonrpc":"1.0","id":%d,"result":%s}`, id, result), false},
			{"missing protocol", fmt.Sprintf(`{"id":%d,"result":%s}`, id, result), false},
			{"notification", fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"notifications/progress","result":%s}`, id, result), false},
			{"null result", fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"result":null}`, id), false},
		}
		for _, kind := range []runtime.AdapterKind{runtime.AdapterKindHermes, runtime.AdapterKindOpenClaw} {
			for _, contentType := range []string{"application/json", "text/event-stream"} {
				for _, envelope := range envelopes {
					fixtures = append(fixtures, directMCPEnvelopeFixture{fmt.Sprintf("%s/%s/stage%d/%s", kind.String(), contentType, stage, envelope.name), contentType, envelope.response, kind, stage, envelope.valid})
				}
			}
		}
	}
	return fixtures
}

func TestDesktopAgentBridgeDirectMCPRejectsUncorrelatedEnvelope(t *testing.T) {
	t.Parallel()
	for _, fixture := range directMCPEnvelopeFixtures() {
		t.Run(fixture.name, func(t *testing.T) {
			t.Parallel()
			calls, wantCalls := 0, fixture.stage
			if fixture.valid {
				wantCalls = 3
			}
			client := &http.Client{Transport: verifyContractRoundTripper(func(req *http.Request) (*http.Response, error) {
				calls++
				if calls > wantCalls || req.Method != http.MethodPost || req.URL.String() != "https://mcp.example.test/mcp" || req.Header.Get("Authorization") != "Bearer token" {
					t.Fatal("unplanned direct MCP request")
				}
				response := `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}`
				status, contentType := http.StatusOK, fixture.contentType
				switch calls {
				case 2:
					status, response, contentType = http.StatusAccepted, "", "application/json"
				case 3:
					response = `{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"my_persona_info"},{"name":"baseline_prompt"}]}}`
				}
				if calls == fixture.stage {
					response = fixture.response
				}
				if contentType == "text/event-stream" {
					response = "data: " + response + "\n\n"
				}
				return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": []string{contentType}}, Body: io.NopCloser(strings.NewReader(response)), Request: req}, nil
			})}
			result := VerifyBindingLive(context.Background(), config.Binding{RuntimeKind: fixture.kind, PersonaMCPURL: "https://mcp.example.test/mcp", PersonaMCPToken: "token"}, client)
			if result.OK != fixture.valid || calls != wantCalls || (!fixture.valid && result.DiagnosticCode != "runtime_error") {
				t.Fatalf("response verification: %+v calls%d", result, calls)
			}
		})
	}
}
