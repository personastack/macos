package control

import (
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/mcp"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
	"os"
	"path/filepath"
	"time"
)

type migration struct {
	LegacyGeneration int64
	Scope            PreparePayload
	DocumentID       string
	Capture          config.MigrationCapture
	ExpiresAt        time.Time
}

func (c *Controller) prepareMigration(p MigrationPreparePayload) (Result, error) {
	environment, err := c.environment(p.EnvironmentID)
	if err != nil {
		return Result{}, err
	}
	if !validWorkspaceID(p.WorkspaceID) || !validPersonaID(p.PersonaID) || !validUUID(p.DocumentID) || p.ConnectionID == "" || p.ConnectionGeneration <= 0 || p.WasPaused == nil || p.PauseVersion == nil || *p.PauseVersion < 0 {
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
			chosen, choiceError := targetinventory.SelectOpenClawAgent(profile, p.OpenClawAgentCandidateID)
			if choiceError != nil {
				return Result{}, issue("scope_changed", "Selected native dispatch agent changed.")
			}
			selectedPath = chosen.Resolved.ConfigPath
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
	capture.WasPaused = *p.WasPaused
	capture.PauseVersion = *p.PauseVersion
	if c.migrations == nil {
		c.migrations = map[string]migration{}
	}
	c.migrations[id] = migration{LegacyGeneration: p.ConnectionGeneration, Scope: p.PreparePayload, DocumentID: p.DocumentID, Capture: capture, ExpiresAt: c.now().Add(30 * time.Minute)}
	return Result{MigrationID: id, LegacyServiceScope: string(externalagentprotocol.ServiceScopeUserLaunchAgent), ProfileCandidateID: p.ProfileCandidateID, WasPaused: &capture.WasPaused, PauseVersion: &capture.PauseVersion}, nil
}
func readLegacyMetadata(environment Environment) ([]config.Binding, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	paths := []string{filepath.Join(home, "Library", "Application Support", "personastack", "connector", "state.json"), filepath.Join(home, "Library", "Application Support", "PersonaStack", "Connector", "state.json")}
	_, err = externalagentprotocol.ResolveWebsocketURL(environment.GatewayBaseURL)
	if err != nil {
		return nil, err
	}
	var matches []config.Binding
	for _, path := range paths {
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 || !ownedFile(info) {
			return nil, fmt.Errorf("unsafe legacy user state")
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var state config.State
		if err = json.Unmarshal(raw, &state); err != nil {
			return nil, err
		}
		for _, binding := range state.Bindings {
			matches = append(matches, binding)
		}
	}
	return matches, nil
}
func readLegacyUserBinding(environment Environment, p MigrationPreparePayload) (config.Binding, error) {
	bindings, err := readLegacyMetadata(environment)
	if err != nil {
		return config.Binding{}, err
	}
	websocket, err := externalagentprotocol.ResolveWebsocketURL(environment.GatewayBaseURL)
	if err != nil {
		return config.Binding{}, err
	}
	var matches []config.Binding
	for _, binding := range bindings {
		if binding.ConnectionID == p.ConnectionID && binding.GatewayWebsocketURL == websocket {
			matches = append(matches, binding)
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

// migrationHelp reports manual inspection locations only. It never reads Keychain
// secrets, captures ownership, resets configuration, or recreates expired custody.
func (c *Controller) migrationHelp(p MigrationHelpPayload) (Result, error) {
	environment, err := c.environment(p.EnvironmentID)
	if err != nil {
		return Result{}, err
	}
	r := p.RevocationReadback
	if !validWorkspaceID(p.WorkspaceID) || !validPersonaID(p.PersonaID) || !validUUID(p.DocumentID) || !r.BindingAbsent || r.EnvironmentID != p.EnvironmentID || r.WorkspaceID != p.WorkspaceID || r.PersonaID != p.PersonaID {
		return Result{}, issue("scope_changed", "Current native absence readback is required.")
	}
	k, err := kind(p.RuntimeKind)
	if err != nil {
		return Result{}, err
	}
	profiles, _ := c.profiles(k)
	var path, label string
	for _, profile := range profiles {
		if profile.CandidateID == p.ProfileCandidateID {
			path, label = profile.Resolved.ConfigPath, profile.Label
		}
	}
	if path == "" {
		return Result{}, issue("scope_changed", "Selected profile is unavailable.")
	}
	entry, err := c.legacyEntryForScope(environment, p.PreparePayload, path)
	if err != nil {
		return Result{}, err
	}
	if entry == "" {
		return Result{}, issue("cleanup_required", "No exact legacy metadata entry is available. Keep the persona paused and inspect the selected profile manually.")
	}
	directory := c.MigrationDirectory
	if directory == "" {
		support, err := DefaultDirectory()
		if err != nil {
			return Result{}, err
		}
		directory = filepath.Join(support, "migration")
	}
	return Result{ProfileLabel: label, ProfileConfigPath: path, LegacyEntryKey: entry, BackupDirectory: directory}, nil
}

// RepairMigration rebinds an unconsumed capture after native authenticated absence
// readback. It does not recreate a missing capture or adopt a native entry.
func (c *Controller) repairMigration(p MigrationRepairPayload) (Result, error) {
	if _, err := c.environment(p.EnvironmentID); err != nil {
		return Result{}, err
	}
	if !validWorkspaceID(p.WorkspaceID) || !validPersonaID(p.PersonaID) || !validUUID(p.DocumentID) {
		return Result{}, issue("scope_changed", "Native migration scope is invalid.")
	}
	k, err := kind(p.RuntimeKind)
	if err != nil {
		return Result{}, err
	}
	readback := p.RevocationReadback
	if !readback.BindingAbsent || readback.EnvironmentID != p.EnvironmentID || readback.WorkspaceID != p.WorkspaceID || readback.PersonaID != p.PersonaID {
		return Result{}, issue("scope_changed", "Current native revocation readback is required.")
	}
	profiles, _ := c.profiles(k)
	available := false
	for _, profile := range profiles {
		if profile.CandidateID == p.ProfileCandidateID {
			available = true
		}
	}
	if !available {
		return Result{}, issue("scope_changed", "Captured migration profile is unavailable.")
	}
	id := ""
	for candidate, migration := range c.migrations {
		scope := migration.Scope
		if scope.EnvironmentID == p.EnvironmentID && scope.WorkspaceID == p.WorkspaceID && scope.PersonaID == p.PersonaID && scope.RuntimeKind == p.RuntimeKind && scope.ProfileCandidateID == p.ProfileCandidateID && scope.OpenClawAgentCandidateID == p.OpenClawAgentCandidateID && c.now().Before(migration.ExpiresAt) {
			if id != "" {
				return Result{}, issue("scope_changed", "Multiple migration captures require a fresh check.")
			}
			id = candidate
		}
	}
	if id == "" {
		return Result{}, issue("scope_changed", "No current migration capture is available. Check migration before enrolling.")
	}
	migration := c.migrations[id]
	if p.PauseVersion == nil || *p.PauseVersion != migration.Capture.PauseVersion {
		return Result{}, issue("scope_changed", "Persona pause state changed. Check migration again.")
	}
	migration.Scope.DocumentID = p.DocumentID
	migration.DocumentID = p.DocumentID
	c.migrations[id] = migration
	return Result{MigrationID: id, LegacyServiceScope: string(externalagentprotocol.ServiceScopeUserLaunchAgent), ProfileCandidateID: p.ProfileCandidateID, WasPaused: &migration.Capture.WasPaused, PauseVersion: &migration.Capture.PauseVersion}, nil
}

func (c *Controller) cancelMigration(p MigrationCancelPayload) (Result, error) {
	capture, ok := c.migrations[p.MigrationID]
	if !ok || capture.DocumentID != p.DocumentID {
		return Result{}, issue("scope_changed", "Exact pending migration document required.")
	}
	r := p.LegacyBindingReadback
	s := capture.Scope
	if !r.BindingPresent || r.EnvironmentID != s.EnvironmentID || r.WorkspaceID != s.WorkspaceID || r.PersonaID != s.PersonaID || r.ConnectionID != capture.Capture.LegacyConnectionID || r.ConnectionGeneration != capture.LegacyGeneration {
		return Result{}, issue("scope_changed", "Current native proof that the old connection still exists is required.")
	}
	delete(c.migrations, p.MigrationID)
	cancelled := true
	return Result{Cancelled: &cancelled}, nil
}

func (c *Controller) legacyEntryForScope(environment Environment, scope PreparePayload, path string) (string, error) {
	reader := c.LegacyMetadataRead
	if reader == nil {
		reader = readLegacyMetadata
	}
	bindings, err := reader(environment)
	if err != nil {
		return "", issue("cleanup_required", "Known legacy user metadata is unavailable.")
	}
	k, err := kind(scope.RuntimeKind)
	if err != nil {
		return "", err
	}
	websocket, err := externalagentprotocol.ResolveWebsocketURL(environment.GatewayBaseURL)
	if err != nil {
		return "", err
	}
	var entry string
	for _, binding := range bindings {
		if binding.RuntimeKind != k {
			continue
		}
		binding.NativeConfigPath = path
		if !mcp.LegacyEntryMatchesMetadata(binding) {
			continue
		}
		if binding.GatewayWebsocketURL != websocket || string(binding.PersonaID) != scope.PersonaID || (binding.WorkspaceID != "" && binding.WorkspaceID != scope.WorkspaceID) {
			return "", issue("profile_in_use", "This profile contains a legacy connection for another persona.")
		}
		if entry != "" {
			return "", issue("cleanup_required", "Legacy native entry is ambiguous. Inspect known backup files manually.")
		}
		entry = binding.NativeMCPServer
	}
	return entry, nil
}
