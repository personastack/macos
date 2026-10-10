package externalagentprotocol

// ClientKind distinguishes application-owned bridges from the retiring standalone distribution.
type ClientKind string

const (
	ClientKindStandaloneConnector ClientKind = "standalone_connector"
	ClientKindMacOSApp            ClientKind = "macos_app"
)

// DesktopPreparation binds a short-lived enrollment to the helper's key and opaque profile.
// The private key and native profile path never cross this boundary.
type DesktopPreparation struct {
	PreparationID      string `json:"preparation_id"`
	DevicePublicKey    string `json:"device_public_key"`
	ProfileCandidateID string `json:"profile_candidate_id"`
}

// PairingExchangeRequest is sent by Connector after the user runs the browser
// pairing command.
type PairingExchangeRequest struct {
	ClientKind                ClientKind          `json:"client_kind,omitempty"`
	ClientVersion             string              `json:"client_version,omitempty"`
	DesktopPreparation        *DesktopPreparation `json:"desktop_preparation,omitempty"`
	Code                      string              `json:"code"`
	RuntimeKind               RuntimeKind         `json:"runtime_kind"`
	ConnectorVersion          string              `json:"connector_version"`
	ProtocolVersion           string              `json:"protocol_version"`
	SupportedProtocolVersions []string            `json:"supported_protocol_versions,omitempty"`
	OS                        string              `json:"os,omitempty"`
	Arch                      string              `json:"arch,omitempty"`
	DevicePublicKey           string              `json:"device_public_key"`
	DeviceKeyProof            string              `json:"device_key_proof"`
	Hostname                  string              `json:"hostname,omitempty"`
	HostnameHash              string              `json:"hostname_hash"`
	GatewayWebsocketURL       string              `json:"gateway_websocket_url"`
	ConfigureMCP              bool                `json:"configure_mcp"`
}

type PairingExchangeErrorCode string

const (
	PairingExchangeErrorUnsupportedConnectorVersion PairingExchangeErrorCode = "unsupported_connector_version"
)

type PairingExchangeErrorResponse struct {
	ErrorCode               PairingExchangeErrorCode `json:"error_code"`
	Message                 string                   `json:"message"`
	MinimumConnectorVersion string                   `json:"minimum_connector_version,omitempty"`
	UpdateCommand           string                   `json:"update_command,omitempty"`
}

// PairingExchangeResponse returns the durable API-owned bridge binding.
type PairingExchangeResponse struct {
	ClientKind             ClientKind  `json:"client_kind,omitempty"`
	PersonaID              string      `json:"persona_id"`
	ConnectionID           string      `json:"connection_id"`
	CredentialID           string      `json:"credential_id"`
	RuntimeKind            RuntimeKind `json:"runtime_kind"`
	ConnectionGeneration   int64       `json:"connection_generation"`
	GatewayWebsocketURL    string      `json:"gateway_websocket_url"`
	NativeMCPServerName    string      `json:"native_mcp_server_name"`
	NativeMCPToolNamespace string      `json:"native_mcp_tool_namespace"`
	PersonaMCPURL          string      `json:"persona_mcp_url,omitempty"`
	PersonaMCPToken        string      `json:"persona_mcp_token,omitempty"`
}
