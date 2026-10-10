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

type Profile struct {
	ProfileCandidateID string `json:"profile_candidate_id"`
	AccountCandidateID string `json:"account_candidate_id"`
	Label              string `json:"label"`
	RuntimeKind        string `json:"runtime_kind"`
	ConflictCode       string `json:"conflict_code,omitempty"`
}
type Connection struct {
	BindingKey        config.BindingKey `json:"binding_key"`
	PersonaID         string            `json:"persona_id"`
	RuntimeKind       string            `json:"runtime_kind"`
	ReadinessState    string            `json:"readiness_state"`
	ActiveRunID       string            `json:"active_run_id,omitempty"`
	DiagnosticCode    string            `json:"diagnostic_code,omitempty"`
	DiagnosticMessage string            `json:"diagnostic_message,omitempty"`
}
type Result struct {
	MigrationID        string             `json:"migration_id,omitempty"`
	LegacyServiceScope string             `json:"legacy_service_scope,omitempty"`
	Operation          string             `json:"-"`
	Profiles           []Profile          `json:"profiles,omitempty"`
	DiscoveryStatus    string             `json:"discovery_status,omitempty"`
	PreparationID      string             `json:"preparation_id,omitempty"`
	DevicePublicKey    string             `json:"device_public_key,omitempty"`
	ProfileCandidateID string             `json:"profile_candidate_id,omitempty"`
	ExpiresAt          *time.Time         `json:"expires_at,omitempty"`
	ExistingBindingKey *config.BindingKey `json:"existing_binding_key,omitempty"`
	BindingKey         *config.BindingKey `json:"binding_key,omitempty"`
	PersonaID          string             `json:"persona_id,omitempty"`
	Connections        []Connection       `json:"connections,omitempty"`
	ActiveRunIDs       []string           `json:"active_run_ids,omitempty"`
	Quiesced           *bool              `json:"quiesced,omitempty"`
	Disconnected       *bool              `json:"disconnected,omitempty"`
	Disabled           *bool              `json:"disabled,omitempty"`
}
type DiscoverPayload struct {
	EnvironmentID string `json:"environment_id"`
	RuntimeKind   string `json:"runtime_kind"`
}
type PreparePayload struct {
	EnvironmentID      string `json:"environment_id"`
	WorkspaceID        string `json:"workspace_id"`
	PersonaID          string `json:"persona_id"`
	RuntimeKind        string `json:"runtime_kind"`
	ProfileCandidateID string `json:"profile_candidate_id"`
	DocumentID         string `json:"document_id"`
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
	BindingKey       config.BindingKey `json:"binding_key"`
	PreparationID    string            `json:"preparation_id,omitempty"`
	RestartConfirmed bool              `json:"restart_confirmed"`
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
			Connections []Connection `json:"connections"`
		}{r.Connections})
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
	PreparePayload
	ConnectionID         config.ConnectionID `json:"connection_id"`
	ConnectionGeneration int64               `json:"connection_generation"`
}
