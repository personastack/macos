package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"

	"github.com/gorilla/websocket"
	"strings"
	"testing"
	"time"
)

type desktopTransport func(*http.Request) (*http.Response, error)

func (f desktopTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func nativeResponse(r *http.Request, body string) *http.Response {
	return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: r}
}
func TestDesktopAgentBridgeHermesLifecycle(t *testing.T) {
	t.Parallel()
	calls := []string{}
	adapter := HermesAdapter{BaseURL: "http://127.0.0.1:25001", APIKey: "profile-a", Client: &http.Client{Transport: desktopTransport(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Authorization") != "Bearer profile-a" {
			t.Fatal("wrong profile auth")
		}
		calls = append(calls, r.Method+" "+r.URL.Path)
		switch r.Method + " " + r.URL.Path {
		case "POST /v1/runs":
			var body struct {
				Input   string `json:"input"`
				Session string `json:"session_id"`
				Server  string `json:"native_mcp_server"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body.Input != "composed wake" || body.Session != "run-a" || body.Server != "issued-server" || r.Header.Get("X-Hermes-Session-Key") != "" {
				t.Fatalf("bad run body %+v", body)
			}
			return nativeResponse(r, `{"run_id":"native-a"}`), nil
		case "GET /v1/runs/native-a/events":
			return nativeResponse(r, "data: {\"run_id\":\"native-a\",\"type\":\"output_delta\",\"data\":{\"delta\":\"hello\"}}\n\ndata: {\"run_id\":\"native-a\",\"type\":\"completed\",\"status\":\"completed\",\"output\":\"done\"}\n\n"), nil
		case "POST /v1/runs/native-a/stop":
			return nativeResponse(r, `{}`), nil
		case "GET /v1/runs/native-a":
			return nativeResponse(r, `{"status":"cancelled"}`), nil
		default:
			t.Fatalf("unplanned native call %s %s", r.Method, r.URL)
			return nil, nil
		}
	})}}
	id, err := adapter.StartRun(RunRequest{RunID: "run-a", AssignmentID: "assignment-a", FullyComposedPrompt: "composed wake", NativeMCPServerName: "issued-server"})
	if err != nil || id != "native-a" {
		t.Fatalf("start %s %v", id, err)
	}
	events := []RunEvent{}
	result, err := adapter.StreamOrPollRun(context.Background(), id, func(e RunEvent) error { events = append(events, e); return nil })
	if err != nil || result.Status != RunStatusSucceeded || len(events) < 1 {
		t.Fatalf("progress %+v %v %+v", result, err, events)
	}
	if err = adapter.CancelRun(id); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 4 {
		t.Fatalf("calls %v", calls)
	}
}
func TestDesktopAgentBridgeHermesIncompleteControl(t *testing.T) {
	t.Parallel()
	adapter := HermesAdapter{BaseURL: "http://127.0.0.1:25002", APIKey: "key", Client: &http.Client{Transport: desktopTransport(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/health", "/health/detailed", "/v1/models":
			return nativeResponse(r, `{}`), nil
		case "/v1/capabilities":
			return nativeResponse(r, `{"features":{"run_submission":true,"run_status":true,"run_events_sse":true,"run_stop":false}}`), nil
		default:
			t.Fatalf("unexpected %s", r.URL)
			return nil, nil
		}
	})}}
	if got := adapter.DetectContext(context.Background()); got.State != AdapterStateCapabilityMissing {
		t.Fatalf("incomplete native control ready %+v", got)
	}
}
func TestDesktopAgentBridgeOpenClawLifecycleAndIsolation(t *testing.T) {
	t.Parallel()
	adapter, calls := sessionFixtureAdapter(t, "")
	id, err := adapter.StartRun(RunRequest{AssignmentID: "assignment-a", FullyComposedPrompt: "composed wake", NativeMCPServerName: "issued", NativeMCPToolNamespace: "mcp_issued"})
	if err != nil || id != "native-a" || *calls != 6 {
		t.Fatalf("native id %s %v calls=%d", id, err, *calls)
	}
	adapter.CallNative = func(_ context.Context, request openClawRequest) (openClawResponse, error) {
		raw, _ := json.Marshal(request.Params)
		if request.Method != "sessions.abort" || string(raw) != `{"runId":"native-a"}` {
			t.Fatal("foreign native stop")
		}
		return openClawResponse{}, nil
	}
	events := []RunEvent{}
	session := openClawRPCSession{nativeRunID: id, agentID: adapter.AgentID, handle: func(e RunEvent) error { events = append(events, e); return nil }}
	for _, body := range []string{`{"runId":"foreign","agentId":"selected-agent","delta":"secret"}`, `{"runId":"native-a","agentId":"wrong","delta":"secret"}`, `{"delta":"secret"}`} {
		if err = session.handleBroadcast(openClawResponse{Event: "agent", Payload: json.RawMessage(body)}); err != nil {
			t.Fatal(err)
		}
	}
	if len(events) != 0 || session.outputBuilder.Len() != 0 {
		t.Fatal("foreign event mutated assigned run")
	}
	if err = session.handleBroadcast(openClawResponse{Event: "agent", Payload: json.RawMessage(`{"runId":"native-a","agentId":"selected-agent","delta":"visible"}`)}); err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 || session.outputBuilder.String() != "visible" {
		t.Fatalf("assigned events %+v", events)
	}
	if err = adapter.CancelRun(id); err != nil {
		t.Fatal(err)
	}
}

func TestDesktopAgentBridgeOpenClawPartialProgressRequiresExplicitTerminal(t *testing.T) {
	t.Parallel()
	for _, terminal := range []string{"completed", "failed", "cancelled"} {
		t.Run(terminal, func(t *testing.T) {
			t.Parallel()
			events := []RunEvent{}
			handle := func(e RunEvent) error { events = append(events, e); return nil }
			session := &openClawRPCSession{nativeRunID: "native-a", agentID: "selected", handle: handle}
			calls := 0
			result, err := waitForOpenClawRun(context.Background(), "native-a", handle, session, func(ctx context.Context, r openClawRequest) (openClawResponse, error) {
				calls++
				raw, _ := json.Marshal(r.Params)
				if r.Type != "req" || r.ID != "wait-native-a" || r.Method != "agent.wait" || string(raw) != `{"runId":"native-a","timeoutMs":30000}` {
					t.Fatalf("wrong native wait: %+v %s", r, raw)
				}
				switch calls {
				case 1:
					if err := session.handleBroadcast(openClawResponse{Event: "agent", Payload: json.RawMessage(`{"runId":"native-a","agentId":"selected","delta":"partial"}`)}); err != nil {
						t.Fatal(err)
					}
					return openClawResponse{Payload: json.RawMessage(`{"runId":"native-a","status":"timeout","output":"partial"}`)}, nil
				case 2:
					return openClawResponse{Error: "agent.wait timeout"}, nil
				case 3:
					return openClawResponse{Payload: json.RawMessage(`{"runId":"native-a","status":"running","output":"partial","error":"nonterminal detail"}`)}, nil
				case 4:
					return openClawResponse{Payload: json.RawMessage(`{"runId":"native-a","status":"` + terminal + `"}`)}, nil
				default:
					t.Fatal("unexpected wait after explicit terminal")
					return openClawResponse{}, nil
				}
			})
			want := RunStatusSucceeded
			if terminal == "failed" {
				want = RunStatusFailed
			}
			if terminal == "cancelled" {
				want = RunStatusCancelled
			}
			if err != nil || calls != 4 || result.Status != want || len(events) != 2 {
				t.Fatalf("premature terminal: result=%+v err=%v calls=%d events=%v", result, err, calls, events)
			}
			if terminal == "completed" && result.Output != "partial" {
				t.Fatal("explicit success lost partial output")
			}
		})
	}
}

func TestDesktopAgentBridgeOpenClawPartialProgressDeadlineCancelAndTransportError(t *testing.T) {
	t.Parallel()
	for _, mode := range []string{"deadline", "cancel", "transport_timeout", "foreign_terminal"} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
			defer cancel()
			session := &openClawRPCSession{nativeRunID: "assigned", handle: func(RunEvent) error { return nil }}
			calls := 0
			result, err := waitForOpenClawRun(ctx, "assigned", session.handle, session, func(ctx context.Context, r openClawRequest) (openClawResponse, error) {
				calls++
				if calls == 1 {
					session.appendOutput("partial")
					return openClawResponse{Payload: json.RawMessage(`{"status":"running","output":"partial"}`)}, nil
				}
				switch mode {
				case "deadline":
					<-ctx.Done()
					return openClawResponse{}, ctx.Err()
				case "cancel":
					cancel()
					return openClawResponse{}, ctx.Err()
				case "transport_timeout":
					return openClawResponse{}, errors.New("native transport timeout")
				case "foreign_terminal":
					return openClawResponse{Payload: json.RawMessage(`{"runId":"foreign","status":"completed"}`)}, nil
				default:
					t.Fatal("unplanned wait")
					return openClawResponse{}, nil
				}
			})
			if err == nil || result.Output != "" || calls != 2 {
				t.Fatalf("partial became success: %+v %v calls=%d", result, err, calls)
			}
			if mode == "deadline" && !errors.Is(err, context.DeadlineExceeded) {
				t.Fatal(err)
			}
			if mode == "cancel" && !errors.Is(err, context.Canceled) {
				t.Fatal(err)
			}
		})
	}
}

func TestDesktopAgentBridgeOpenClawColdMCPVerificationFailsClosed(t *testing.T) {
	t.Parallel()
	for _, server := range []string{"issued", ""} {
		t.Run(server, func(t *testing.T) {
			t.Parallel()
			adapter := OpenClawAdapter{AgentID: "writer", Token: "selected-profile-key", GatewayURL: "ws://127.0.0.1:25907",
				CallNative: func(context.Context, openClawRequest) (openClawResponse, error) {
					t.Fatal("readiness tried a static catalog, model run or guessed discovery RPC")
					return openClawResponse{}, nil
				},
				Dialer: &websocket.Dialer{NetDialContext: func(context.Context, string, string) (net.Conn, error) {
					t.Fatal("unsupported cold verification dialed a native runtime")
					return nil, nil
				}},
			}
			result := adapter.VerifyMCPCatalog(context.Background(), server)
			if result.OK || !strings.Contains(result.Note, "owned") {
				t.Fatalf("unproven cold native MCP became Ready: %+v", result)
			}
		})
	}
}
