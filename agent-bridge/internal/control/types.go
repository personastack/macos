package control

import (
	"encoding/json"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
	"time"
)

const Version = 1
const MaxBytes = 256 * 1024

type Request struct {
	Version   int             `json:"version"`
	RequestID string          `json:"request_id"`
	Operation string          `json:"operation"`
	Payload   json.RawMessage `json:"payload"`
}
type Response struct {
	Version   int     `json:"version"`
	RequestID string  `json:"request_id"`
	Result    *Result `json:"result,omitempty"`
	Error     *Error  `json:"error,omitempty"`
}
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

type NativeOpenClawAgent struct {
	AgentCandidateID string `json:"agent_candidate_id"`
	Label            string `json:"label"`
}
type Profile struct {
	OpenClawAgents           []NativeOpenClawAgent `json:"openclaw_agents,omitempty"`
	SelectedAgentCandidateID string                `json:"selected_agent_candidate_id,omitempty"`
	ProfileCandidateID       string                `json:"profile_candidate_id"`
	AccountCandidateID       string                `json:"account_candidate_id"`
	Label                    string                `json:"label"`
	RuntimeKind              string                `json:"runtime_kind"`
	ConflictCode             string                `json:"conflict_code,omitempty"`
}

// PreparedTarget remains on private native IPC. The page never receives this retry authority.
type PreparedTarget struct {
	WorkspaceID        string `json:"workspace_id"`
	AccountCandidateID string `json:"account_candidate_id"`
	ProfileCandidateID string `json:"profile_candidate_id"`
	RuntimeKind        string `json:"runtime_kind"`
}
type Connection struct {
	PreparedTarget       *PreparedTarget   `json:"prepared_target,omitempty"`
	ConnectionGeneration int64             `json:"connection_generation"`
	BindingKey           config.BindingKey `json:"binding_key"`
	PersonaID            string            `json:"persona_id"`
	RuntimeKind          string            `json:"runtime_kind"`
	ReadinessState       string            `json:"readiness_state"`
	ActiveRunID          string            `json:"active_run_id,omitempty"`
	DiagnosticCode       string            `json:"diagnostic_code,omitempty"`
	DiagnosticMessage    string            `json:"diagnostic_message,omitempty"`
}
type Result struct {
	ProfileLabel          string             `json:"profile_label,omitempty"`
	ProfileConfigPath     string             `json:"profile_config_path,omitempty"`
	LegacyEntryKey        string             `json:"legacy_entry_key,omitempty"`
	BackupDirectory       string             `json:"backup_directory,omitempty"`
	Cancelled             *bool              `json:"cancelled,omitempty"`
	PendingMigrationCount int                `json:"pending_migration_count"`
	MigrationPending      bool               `json:"migration_pending,omitempty"`
	WasPaused             *bool              `json:"was_paused,omitempty"`
	PauseVersion          *int64             `json:"pause_version,omitempty"`
	MigrationID           string             `json:"migration_id,omitempty"`
	LegacyServiceScope    string             `json:"legacy_service_scope,omitempty"`
	Operation             string             `json:"-"`
	Profiles              []Profile          `json:"profiles,omitempty"`
	DiscoveryStatus       string             `json:"discovery_status,omitempty"`
	PreparationID         string             `json:"preparation_id,omitempty"`
	DevicePublicKey       string             `json:"device_public_key,omitempty"`
	ProfileCandidateID    string             `json:"profile_candidate_id,omitempty"`
	ExpiresAt             *time.Time         `json:"expires_at,omitempty"`
	ExistingBindingKey    *config.BindingKey `json:"existing_binding_key,omitempty"`
	BindingKey            *config.BindingKey `json:"binding_key,omitempty"`
	PersonaID             string             `json:"persona_id,omitempty"`
	Connections           []Connection       `json:"connections,omitempty"`
	ActiveRunIDs          []string           `json:"active_run_ids,omitempty"`
	Quiesced              *bool              `json:"quiesced,omitempty"`
	Disconnected          *bool              `json:"disconnected,omitempty"`
	Disabled              *bool              `json:"disabled,omitempty"`
}
type DiscoverPayload struct {
	EnvironmentID string `json:"environment_id"`
	RuntimeKind   string `json:"runtime_kind"`
}
type PreparePayload struct {
	OpenClawAgentCandidateID string `json:"openclaw_agent_candidate_id,omitempty"`
	EnvironmentID            string `json:"environment_id"`
	WorkspaceID              string `json:"workspace_id"`
	PersonaID                string `json:"persona_id"`
	RuntimeKind              string `json:"runtime_kind"`
	ProfileCandidateID       string `json:"profile_candidate_id"`
	DocumentID               string `json:"document_id"`
}
type EnrollPayload struct {
	MigrationID   string `json:"migration_id,omitempty"`
	PreparationID string `json:"preparation_id"`
	Code          string `json:"code"`
	DocumentID    string `json:"document_id"`
}
type BindingPayload struct {
	BindingKey *config.BindingKey `json:"binding_key,omitempty"`
}
type RepairPayload struct {
	BindingKey              config.BindingKey `json:"binding_key"`
	ConnectionGeneration    int64             `json:"connection_generation"`
	TargetSelectionRevision int64             `json:"target_selection_revision"`
	PreparationID           string            `json:"preparation_id,omitempty"`
	RestartConfirmed        bool              `json:"restart_confirmed"`
	OpenClawAppsConfirmed   bool              `json:"openclaw_apps_confirmed"`
	HermesHostConfirmed     bool              `json:"hermes_host_confirmed"`
}
type RevocationReadback struct {
	EnvironmentID        string              `json:"environment_id"`
	WorkspaceID          string              `json:"workspace_id"`
	PersonaID            string              `json:"persona_id"`
	ConnectionID         config.ConnectionID `json:"connection_id"`
	ConnectionGeneration int64               `json:"connection_generation"`
	BindingAbsent        bool                `json:"binding_absent"`
}
type DisconnectPayload struct {
	BindingKey           config.BindingKey  `json:"binding_key"`
	WorkspaceID          string             `json:"workspace_id"`
	PersonaID            string             `json:"persona_id"`
	ConnectionGeneration int64              `json:"connection_generation"`
	RevocationReadback   RevocationReadback `json:"revocation_readback"`
}
type Environment struct {
	EnvironmentID  string `json:"environment_id"`
	GatewayBaseURL string `json:"gateway_base_url"`
}
type preparation struct {
	Scope                 PreparePayload
	Profile               targetinventory.Profile
	PublicKey, PrivateKey []byte
	ExpiresAt             time.Time
}

func (r Result) MarshalJSON() ([]byte, error) {
	switch r.Operation {
	case "discover":
		if r.Profiles == nil {
			r.Profiles = []Profile{}
		}
		return json.Marshal(struct {
			Profiles        []Profile `json:"profiles"`
			DiscoveryStatus string    `json:"discovery_status"`
		}{r.Profiles, r.DiscoveryStatus})
	case "status", "check", "repair":
		if r.Connections == nil {
			r.Connections = []Connection{}
		}
		return json.Marshal(struct {
			Connections           []Connection `json:"connections"`
			PendingMigrationCount int          `json:"pending_migration_count"`
		}{r.Connections, r.PendingMigrationCount})
	case "quiesce", "resume":
		if r.ActiveRunIDs == nil {
			r.ActiveRunIDs = []string{}
		}
		return json.Marshal(struct {
			ActiveRunIDs []string `json:"active_run_ids"`
			Quiesced     *bool    `json:"quiesced"`
		}{r.ActiveRunIDs, r.Quiesced})
	default:
		type plain Result
		return json.Marshal(plain(r))
	}
}

type MigrationPreparePayload struct {
	WasPaused    *bool  `json:"was_paused"`
	PauseVersion *int64 `json:"pause_version"`
	PreparePayload
	ConnectionID         config.ConnectionID `json:"connection_id"`
	ConnectionGeneration int64               `json:"connection_generation"`
}

type MigrationAbsenceReadback struct {
	EnvironmentID string `json:"environment_id"`
	WorkspaceID   string `json:"workspace_id"`
	PersonaID     string `json:"persona_id"`
	BindingAbsent bool   `json:"binding_absent"`
}
type MigrationRepairPayload struct {
	PauseVersion *int64 `json:"pause_version"`
	PreparePayload
	RevocationReadback MigrationAbsenceReadback `json:"revocation_readback"`
}

type LegacyPresenceReadback struct {
	EnvironmentID        string              `json:"environment_id"`
	WorkspaceID          string              `json:"workspace_id"`
	PersonaID            string              `json:"persona_id"`
	ConnectionID         config.ConnectionID `json:"connection_id"`
	ConnectionGeneration int64               `json:"connection_generation"`
	BindingPresent       bool                `json:"binding_present"`
}
type MigrationCancelPayload struct {
	MigrationID           string                 `json:"migration_id"`
	DocumentID            string                 `json:"document_id"`
	LegacyBindingReadback LegacyPresenceReadback `json:"legacy_binding_readback"`
}

type MigrationHelpPayload struct {
	PreparePayload
	RevocationReadback MigrationAbsenceReadback `json:"revocation_readback"`
}
