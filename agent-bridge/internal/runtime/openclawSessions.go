package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
)

// OpenClawSessionIdentity is native metadata retained privately for exact reads.
// It does not contain a transcript or become PersonaStack conversation authority.
type OpenClawSessionIdentity struct {
	Key      string `json:"key"`
	ID       string `json:"id"`
	Revision string `json:"revision,omitempty"`
}

type openClawCreateSession struct {
	Key            string `json:"key"`
	AgentID        string `json:"agentId"`
	IdempotencyKey string `json:"idempotencyKey"`
}
type openClawSessionEntry struct {
	Key      string `json:"key"`
	ID       string `json:"sessionId"`
	AgentID  string `json:"agentId"`
	Revision string `json:"lifecycleRevision"`
}
type openClawDescribeSession struct {
	Key     string `json:"key"`
	AgentID string `json:"agentId"`
}

func (adapter OpenClawAdapter) OwnedSessionKey(purpose, conversation string) string {
	if adapter.SessionOwner == "" || adapter.AgentID == "" || adapter.NativeMCPNamespace == "" {
		return ""
	}
	raw, _ := json.Marshal([]string{adapter.SessionOwner, adapter.NativeMCPNamespace, purpose, conversation})
	return fmt.Sprintf("agent:%s:personastack:%x", adapter.AgentID, sha256.Sum256(raw))
}

func (adapter OpenClawAdapter) appsAvailable() error {
	if adapter.MCPAppsEnabled == nil {
		return fmt.Errorf("mcp_apps_disabled: selected profile MCP Apps authority required")
	}
	enabled, err := adapter.MCPAppsEnabled()
	if err != nil {
		return err
	}
	if !enabled {
		return fmt.Errorf("mcp_apps_disabled: enable MCP Apps through native setup")
	}
	return nil
}

// PrepareOwnedMCPSession performs the supported no-model create/discover/read path.
// Call only for native-consented setup or an admitted PersonaStack assignment.
func (adapter OpenClawAdapter) PrepareOwnedMCPSession(ctx context.Context, purpose, conversation string) (OpenClawSessionIdentity, error) {
	if err := adapter.appsAvailable(); err != nil {
		return OpenClawSessionIdentity{}, err
	}
	key := adapter.OwnedSessionKey(purpose, conversation)
	if key == "" || adapter.NativeMCPServer == "" {
		return OpenClawSessionIdentity{}, fmt.Errorf("selected OpenClaw session and MCP authority required")
	}
	response, err := adapter.callNative(ctx, openClawRequest{Type: "req", ID: "mcp-session-create", Method: "sessions.create", Params: openClawCreateSession{Key: key, AgentID: adapter.AgentID, IdempotencyKey: key}})
	if err != nil || !response.isResponseOK() || response.errorString() != "" {
		return OpenClawSessionIdentity{}, fmt.Errorf("selected OpenClaw empty session creation unavailable")
	}
	var created struct {
		OK         bool                 `json:"ok"`
		Key        string               `json:"key"`
		ID         string               `json:"sessionId"`
		RunStarted *bool                `json:"runStarted"`
		Entry      openClawSessionEntry `json:"entry"`
	}
	err = json.Unmarshal(response.payload(), &created)
	if err != nil || !created.OK || created.Key != key || strings.TrimSpace(created.ID) == "" || created.RunStarted == nil || *created.RunStarted || created.Entry.ID != created.ID {
		return OpenClawSessionIdentity{}, fmt.Errorf("OpenClaw empty session returned invalid or foreign identity")
	}
	identity := OpenClawSessionIdentity{Key: created.Key, ID: created.ID, Revision: created.Entry.Revision}
	response, err = adapter.callNative(ctx, openClawRequest{Type: "req", ID: "mcp-session-discover", Method: "mcp.app.discover", Params: openClawEffectiveMCPParams{AgentID: adapter.AgentID, SessionKey: identity.Key}})
	if err != nil || !response.isResponseOK() || response.errorString() != "" {
		return OpenClawSessionIdentity{}, fmt.Errorf("selected OpenClaw MCP Apps discovery unavailable; gateway restart may be required")
	}
	verified := adapter.VerifyOwnedMCPSession(ctx, adapter.NativeMCPServer, identity)
	if !verified.OK {
		return OpenClawSessionIdentity{}, fmt.Errorf("%s", verified.Note)
	}
	return identity, nil
}

func (adapter OpenClawAdapter) readOwnedSession(ctx context.Context, expected OpenClawSessionIdentity) bool {
	response, err := adapter.callNative(ctx, openClawRequest{Type: "req", ID: "mcp-session-describe", Method: "sessions.describe", Params: openClawDescribeSession{Key: expected.Key, AgentID: adapter.AgentID}})
	if err != nil || !response.isResponseOK() || response.errorString() != "" {
		return false
	}
	var described struct {
		Session *openClawSessionEntry `json:"session"`
	}
	err = json.Unmarshal(response.payload(), &described)
	return err == nil && described.Session != nil && described.Session.Key == expected.Key && described.Session.ID == expected.ID && described.Session.AgentID == adapter.AgentID && described.Session.Revision == expected.Revision
}

// VerifyOwnedMCPSession reads only native metadata and effective tools. The two
// describe reads reject a reset/replacement while tools.effective is projected.
// Native dispatch additionally enforces expectedExistingSessionId/revision.
func (adapter OpenClawAdapter) VerifyOwnedMCPSession(ctx context.Context, server string, identity OpenClawSessionIdentity) OpenClawMCPVerificationResult {
	if err := adapter.appsAvailable(); err != nil {
		return OpenClawMCPVerificationResult{Note: err.Error()}
	}
	if identity.ID == "" || !strings.HasPrefix(identity.Key, "agent:"+adapter.AgentID+":personastack:") || !adapter.readOwnedSession(ctx, identity) {
		return OpenClawMCPVerificationResult{Note: "selected OpenClaw owned session is missing, reset or foreign"}
	}
	result := adapter.VerifyMCPCatalogInSession(ctx, server, identity.Key)
	if result.OK && !adapter.readOwnedSession(ctx, identity) {
		return OpenClawMCPVerificationResult{Note: "selected OpenClaw owned session changed during verification"}
	}
	return result
}
