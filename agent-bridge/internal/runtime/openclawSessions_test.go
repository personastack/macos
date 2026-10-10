package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func sessionFixtureAdapter(t *testing.T, failure string) (OpenClawAdapter, *int) {
	t.Helper()
	calls := 0
	adapter := OpenClawAdapter{AgentID: "selected-agent", SessionOwner: "https://app.example\x00connection", NativeMCPServer: "issued", NativeMCPNamespace: "mcp_issued", MCPAppsEnabled: func() (bool, error) { return true, nil }}
	key := ""
	methods := []string{"sessions.create", "mcp.app.discover", "sessions.describe", "tools.effective", "sessions.describe", "agent"}
	adapter.CallNative = func(ctx context.Context, request openClawRequest) (openClawResponse, error) {
		if calls >= len(methods) || request.Method != methods[calls] {
			t.Fatalf("unplanned native RPC %s at %d", request.Method, calls)
		}
		calls++
		raw, _ := json.Marshal(request.Params)
		ok := true
		response := openClawResponse{OK: &ok, Type: "res", ID: request.ID}
		switch request.Method {
		case "sessions.create":
			var params openClawCreateSession
			decoder := json.NewDecoder(strings.NewReader(string(raw)))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&params); err != nil {
				t.Fatal("no-model create contained turn/title/policy fields", err)
			}
			key = params.Key
			if params.AgentID != adapter.AgentID || params.IdempotencyKey != key || !strings.HasPrefix(key, "agent:selected-agent:personastack:") {
				t.Fatal("unowned native session created")
			}
			if failure == "auth" {
				return openClawResponse{}, fmt.Errorf("operator denied")
			}
			returned := key
			if failure == "foreign key" {
				returned = "agent:main:main"
			}
			started := failure == "model started"
			response.Payload = json.RawMessage(fmt.Sprintf(`{"ok":true,"key":%q,"sessionId":"native-session","entry":{"sessionId":"native-session","lifecycleRevision":"revision-1"},"runStarted":%t}`, returned, started))
		case "mcp.app.discover":
			if string(raw) != fmt.Sprintf(`{"agentId":"selected-agent","sessionKey":%q}`, key) {
				t.Fatal("foreign discovery session")
			}
			if failure == "discover" {
				response.Error = "MCP Apps disabled"
			} else {
				response.Payload = json.RawMessage(`{"servers":[],"onboarding":[]}`)
			}
		case "sessions.describe":
			if string(raw) != fmt.Sprintf(`{"key":%q,"agentId":"selected-agent"}`, key) {
				t.Fatal("metadata read lost selected session")
			}
			id, agent, revision := "native-session", "selected-agent", "revision-1"
			if failure == "foreign agent" {
				agent = "main"
			}
			if failure == "reset" && calls == 5 {
				id = "replacement-session"
			}
			if failure == "revision" && calls == 5 {
				revision = "revision-2"
			}
			response.Payload = json.RawMessage(fmt.Sprintf(`{"session":{"key":%q,"sessionId":%q,"agentId":%q,"lifecycleRevision":%q}}`, key, id, agent, revision))
			if failure == "missing" {
				response.Payload = json.RawMessage(`{"session":null}`)
			}
		case "tools.effective":
			if string(raw) != fmt.Sprintf(`{"agentId":"selected-agent","sessionKey":%q}`, key) {
				t.Fatal("effective check used another session")
			}
			response.Payload = json.RawMessage(`{"agentId":"selected-agent","groups":[{"source":"mcp","tools":[{"source":"mcp","pluginId":"bundle-mcp","mcpServer":"issued","mcpToolName":"get_persona"}]}]}`)
			if failure == "denied" {
				response.Payload = json.RawMessage(`{"agentId":"selected-agent","groups":[{"source":"mcp","tools":[{"source":"mcp","pluginId":"bundle-mcp","mcpServer":"issued","mcpToolName":"get_persona","deniedBySession":true}]}]}`)
			}
			if failure == "cold" {
				response.Payload = json.RawMessage(`{"agentId":"selected-agent","groups":[],"notices":[{"id":"mcp-not-yet-connected","servers":["issued"]}]}`)
			}
			if failure == "absent" {
				response.Payload = json.RawMessage(`{"agentId":"selected-agent","groups":[]}`)
			}
		case "agent":
			var params openClawAgentSubmission
			if err := json.Unmarshal(raw, &params); err != nil {
				t.Fatal(err)
			}
			if params.AgentID != adapter.AgentID || params.SessionKey != key || params.ExpectedExistingSessionID != "native-session" || params.ExpectedExistingSessionLifecycleRevision != "revision-1" || params.IdempotencyKey != "assignment-a" || params.Message != "composed wake" {
				t.Fatal("verified session authority lost during model dispatch")
			}
			response.Payload = json.RawMessage(`{"status":"accepted","runId":"native-a"}`)
		}
		return response, nil
	}
	return adapter, &calls
}

func TestDesktopAgentBridgeOpenClawAssignedSessionRefusal(t *testing.T) {
	t.Parallel()
	for _, failure := range []string{"", "auth", "foreign key", "model started", "discover", "foreign agent", "missing", "reset", "revision", "denied", "cold", "absent"} {
		t.Run(failure, func(t *testing.T) {
			t.Parallel()
			adapter, calls := sessionFixtureAdapter(t, failure)
			id, err := adapter.StartRun(RunRequest{AssignmentID: "assignment-a", ConversationID: "api-conversation", FullyComposedPrompt: "composed wake", NativeMCPServerName: "issued", NativeMCPToolNamespace: "mcp_issued"})
			if failure == "" {
				if err != nil || id != "native-a" || *calls != 6 {
					t.Fatalf("supported session dispatch failed: %s %v calls=%d", id, err, *calls)
				}
				return
			}
			if err == nil || id != "" || *calls >= 6 {
				t.Fatalf("unproven session dispatched model: %s %v calls=%d", id, err, *calls)
			}
		})
	}
}

func TestDesktopAgentBridgeOpenClawPrivateOwnedSessionIsolation(t *testing.T) {
	t.Parallel()
	adapter, _ := sessionFixtureAdapter(t, "")
	first := adapter.OwnedSessionKey("conversation", "API-a")
	if first != adapter.OwnedSessionKey("conversation", "API-a") || first == adapter.OwnedSessionKey("setup", "") || first == adapter.OwnedSessionKey("conversation", "API-b") {
		t.Fatal("native conversation purpose/identity conflated")
	}
	other := adapter
	other.SessionOwner = "https://other.example\x00connection"
	if first == other.OwnedSessionKey("conversation", "API-a") {
		t.Fatal("cross-environment session reused")
	}
	other = adapter
	other.NativeMCPNamespace = "other-issued-namespace"
	if first == other.OwnedSessionKey("conversation", "API-a") {
		t.Fatal("cross-namespace session reused")
	}
}

func TestDesktopAgentBridgeOpenClawAppsDisabledZeroNativeCalls(t *testing.T) {
	t.Parallel()
	adapter, calls := sessionFixtureAdapter(t, "")
	adapter.MCPAppsEnabled = func() (bool, error) { return false, nil }
	_, err := adapter.StartRun(RunRequest{AssignmentID: "assignment-a", FullyComposedPrompt: "composed wake", NativeMCPServerName: "issued", NativeMCPToolNamespace: "mcp_issued"})
	if err == nil || *calls != 0 {
		t.Fatal("disabled Apps triggered a session or model call")
	}
}
