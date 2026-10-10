package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

func TestDesktopAgentBridgeOpenClawProducerEffectiveMCPInventory(t *testing.T) {
	t.Parallel()
	allowed := `{"id":"mcp_issued_get_persona","label":"get_persona","description":"Read identity","rawDescription":"Read identity","source":"mcp","pluginId":"bundle-mcp","mcpServer":"issued","mcpToolName":"get_persona"}`
	for _, test := range []struct {
		name, payload string
		ok            bool
	}{
		{"allowed", `{"agentId":"writer","profile":"full","groups":[{"id":"mcp","source":"mcp","label":"MCP","tools":[` + allowed + `]}]}`, true},
		{"denied", `{"agentId":"writer","profile":"full","groups":[{"id":"mcp","source":"mcp","tools":[{"source":"mcp","pluginId":"bundle-mcp","mcpServer":"issued","mcpToolName":"get_persona","deniedBySession":true}]}]}`, false},
		{"absent", `{"agentId":"writer","profile":"full","groups":[]}`, false},
		{"unrelated", `{"agentId":"writer","groups":[{"source":"mcp","tools":[{"source":"mcp","pluginId":"bundle-mcp","mcpServer":"other","mcpToolName":"get_persona"}]}]}`, false},
		{"static plugin impostor", `{"agentId":"writer","groups":[{"source":"plugin","pluginId":"issued","tools":[{"source":"plugin","pluginId":"issued","id":"get_persona"}]}]}`, false},
		{"foreign agent", `{"agentId":"main","groups":[{"source":"mcp","tools":[` + allowed + `]}]}`, false},
		{"cold", `{"agentId":"writer","groups":[],"notices":[{"id":"mcp-not-yet-connected","severity":"info","servers":["issued"]}]}`, false},
		{"stale retained tools", `{"agentId":"writer","groups":[{"source":"mcp","tools":[` + allowed + `]}],"notices":[{"id":"mcp-stale-catalog","servers":["issued"]}]}`, false},
		{"unavailable retained tools", `{"agentId":"writer","groups":[{"source":"mcp","tools":[` + allowed + `]}],"notices":[{"id":"mcp-server-diagnostic:issued","severity":"warning","servers":["issued"]}]}`, false},
		{"omitted groups", `{"agentId":"writer"}`, false},
		{"malformed", `{`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			calls := 0
			adapter := OpenClawAdapter{AgentID: "writer", CallNative: func(_ context.Context, request openClawRequest) (openClawResponse, error) {
				calls++
				raw, _ := json.Marshal(request.Params)
				if request.Type != "req" || request.ID != "mcp-effective-1" || request.Method != "tools.effective" || string(raw) != `{"agentId":"writer","sessionKey":"agent:writer:personastack-fixture"}` {
					t.Fatalf("effective inventory lost private session/agent scope: %s %s", request.Method, raw)
				}
				ok := true
				return openClawResponse{OK: &ok, Payload: json.RawMessage(test.payload)}, nil
			}}
			result := adapter.VerifyMCPCatalogInSession(context.Background(), "issued", "agent:writer:personastack-fixture")
			if result.OK != test.ok || calls != 1 {
				t.Fatalf("producer inventory result %+v calls %d", result, calls)
			}
		})
	}
}

func TestDesktopAgentBridgeOpenClawEffectiveInventoryAuthorityFailures(t *testing.T) {
	t.Parallel()
	for _, scoped := range []bool{false, true} {
		t.Run(map[bool]string{false: "missing private session", true: "rejected selected credential"}[scoped], func(t *testing.T) {
			t.Parallel()
			calls := 0
			adapter := OpenClawAdapter{AgentID: "writer", CallNative: func(context.Context, openClawRequest) (openClawResponse, error) {
				calls++
				return openClawResponse{}, errors.New("authentication rejected")
			}}
			session := ""
			if scoped {
				session = "agent:writer:personastack-fixture"
			}
			result := adapter.VerifyMCPCatalogInSession(context.Background(), "issued", session)
			if result.OK || (calls == 1) != scoped {
				t.Fatal("unproven session/auth became effective native readiness")
			}
		})
	}
}
