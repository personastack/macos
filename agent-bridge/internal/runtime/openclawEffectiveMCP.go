package runtime

import (
	"context"
	"encoding/json"
	"strings"
)

// This is the pinned tools.effective owner shape. Static tools.catalog entries
// intentionally cannot satisfy it.
type openClawEffectiveMCPInventory struct {
	AgentID string `json:"agentId"`
	Groups  *[]struct {
		Source string `json:"source"`
		Tools  []struct {
			Source          string `json:"source"`
			PluginID        string `json:"pluginId"`
			MCPServer       string `json:"mcpServer"`
			MCPToolName     string `json:"mcpToolName"`
			DeniedBySession bool   `json:"deniedBySession"`
		} `json:"tools"`
	} `json:"groups"`
	Notices []struct {
		ID      string   `json:"id"`
		Servers []string `json:"servers"`
	} `json:"notices"`
}

type openClawEffectiveMCPParams struct {
	AgentID    string `json:"agentId"`
	SessionKey string `json:"sessionKey"`
}

// VerifyMCPCatalogInSession only reads an already-existing native inventory.
// Its caller must supply the helper-owned, selected-agent session. It cannot
// create that session or discover its cold catalog. Consented setup and
// admitted dispatch own the separate no-model create/discover operation.
func (adapter OpenClawAdapter) VerifyMCPCatalogInSession(ctx context.Context, serverName, ownedSessionKey string) OpenClawMCPVerificationResult {
	if adapter.AgentID == "" || strings.TrimSpace(serverName) == "" || strings.TrimSpace(ownedSessionKey) == "" {
		return OpenClawMCPVerificationResult{Note: "selected native agent, server and owned session are required"}
	}
	response, err := adapter.callNative(ctx, openClawRequest{Type: "req", ID: "mcp-effective-1", Method: "tools.effective", Params: openClawEffectiveMCPParams{AgentID: adapter.AgentID, SessionKey: ownedSessionKey}})
	if err != nil || !response.isResponseOK() || response.errorString() != "" {
		return OpenClawMCPVerificationResult{Note: "selected OpenClaw effective MCP inventory unavailable"}
	}
	var inventory openClawEffectiveMCPInventory
	if err = json.Unmarshal(response.payload(), &inventory); err != nil || inventory.AgentID != adapter.AgentID || inventory.Groups == nil {
		return OpenClawMCPVerificationResult{Note: "selected OpenClaw effective MCP inventory invalid or foreign"}
	}
	if inventory.serverUnavailable(serverName) {
		return OpenClawMCPVerificationResult{Note: "selected OpenClaw MCP catalog is cold, stale or unavailable"}
	}
	for _, group := range *inventory.Groups {
		if group.Source != "mcp" {
			continue
		}
		for _, tool := range group.Tools {
			if tool.Source == "mcp" && tool.PluginID == "bundle-mcp" && tool.MCPServer == serverName && strings.TrimSpace(tool.MCPToolName) != "" && !tool.DeniedBySession {
				return OpenClawMCPVerificationResult{OK: true, Note: "selected native session exposes allowed PersonaStack MCP tools"}
			}
		}
	}
	return OpenClawMCPVerificationResult{Note: "selected native session has no allowed PersonaStack MCP tools"}
}

func (inventory openClawEffectiveMCPInventory) serverUnavailable(serverName string) bool {
	for _, notice := range inventory.Notices {
		if !strings.HasPrefix(notice.ID, "mcp-") {
			continue
		}
		if len(notice.Servers) == 0 {
			return true
		}
		for _, server := range notice.Servers {
			if server == serverName {
				return true
			}
		}
	}
	return false
}
