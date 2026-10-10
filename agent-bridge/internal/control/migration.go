package control

import (
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/mcp"
	"os"
	"path/filepath"
	"time"
)

type migration struct {
	Scope      PreparePayload
	DocumentID string
	Capture    config.MigrationCapture
	ExpiresAt  time.Time
}

func (c *Controller) prepareMigration(p MigrationPreparePayload) (Result, error) {
	environment, err := c.environment(p.EnvironmentID)
	if err != nil {
		return Result{}, err
	}
	if !validWorkspaceID(p.WorkspaceID) || !validPersonaID(p.PersonaID) || !validUUID(p.DocumentID) || p.ConnectionID == "" || p.ConnectionGeneration <= 0 {
		return Result{}, issue("scope_changed", "Exact legacy hosted identity required.")
	}
	k, err := kind(p.RuntimeKind)
	if err != nil {
		return Result{}, err
	}
	profiles, _ := c.profiles(k)
	var selectedPath string
	for _, profile := range profiles {
		if profile.CandidateID == p.ProfileCandidateID {
			selectedPath = profile.Resolved.ConfigPath
		}
	}
	if selectedPath == "" {
		return Result{}, issue("scope_changed", "Selected profile is unavailable.")
	}
	reader := c.LegacyRead
	if reader == nil {
		reader = readLegacyUserBinding
	}
	legacy, err := reader(environment, p)
	if err != nil {
		return Result{}, issue("migration_required", "Legacy credentials are unavailable. Keep the old connection until setup can be checked.")
	}
	if legacy.ConnectionID != p.ConnectionID || string(legacy.PersonaID) != p.PersonaID || legacy.ConnectionGeneration != p.ConnectionGeneration || legacy.RuntimeKind != k || legacy.ActiveRunID != "" {
		return Result{}, issue("scope_changed", "Legacy connection changed or still has an assigned run.")
	}
	legacy.NativeConfigPath = selectedPath
	legacy.InventorySeed = c.Seed
	directory := c.MigrationDirectory
	if directory == "" {
		support, err := DefaultDirectory()
		if err != nil {
			return Result{}, err
		}
		directory = filepath.Join(support, "migration")
	}
	if err := EnsurePrivateDirectory(directory); err != nil {
		return Result{}, err
	}
	if len(c.migrations) >= 32 {
		return Result{}, issue("busy", "Too many active migrations.")
	}
	id := uuid.NewString()
	capture, err := mcp.CaptureLegacy(legacy, id, filepath.Join(directory, id+".native-config"))
	if err != nil {
		return Result{}, issue("cleanup_required", "Legacy native MCP entry could not be verified. Keep the old connection.")
	}
	if c.migrations == nil {
		c.migrations = map[string]migration{}
	}
	c.migrations[id] = migration{Scope: p.PreparePayload, DocumentID: p.DocumentID, Capture: capture, ExpiresAt: c.now().Add(30 * time.Minute)}
	return Result{MigrationID: id, LegacyServiceScope: string(externalagentprotocol.ServiceScopeUserLaunchAgent), ProfileCandidateID: p.ProfileCandidateID}, nil
}
func readLegacyUserBinding(environment Environment, p MigrationPreparePayload) (config.Binding, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return config.Binding{}, err
	}
	paths := []string{filepath.Join(home, "Library", "Application Support", "personastack", "connector", "state.json"), filepath.Join(home, "Library", "Application Support", "PersonaStack", "Connector", "state.json")}
	websocket, err := externalagentprotocol.ResolveWebsocketURL(environment.GatewayBaseURL)
	if err != nil {
		return config.Binding{}, err
	}
	var matches []config.Binding
	for _, path := range paths {
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 || !ownedFile(info) {
			return config.Binding{}, fmt.Errorf("unsafe legacy user state")
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return config.Binding{}, err
		}
		var state config.State
		if err = json.Unmarshal(raw, &state); err != nil {
			return config.Binding{}, err
		}
		for _, binding := range state.Bindings {
			if binding.ConnectionID == p.ConnectionID && binding.GatewayWebsocketURL == websocket {
				matches = append(matches, binding)
			}
		}
	}
	if len(matches) != 1 {
		return config.Binding{}, fmt.Errorf("legacy binding missing or ambiguous")
	}
	binding := matches[0]
	// Read only the established Connector Keychain namespace. Never copy its identity.
	token, err := (config.KeychainStore{Service: "personastack-connector"}).Get(string(binding.ConnectionID) + ":persona-mcp-token")
	if err != nil {
		return config.Binding{}, err
	}
	binding.PersonaMCPToken = token
	return binding, nil
}
