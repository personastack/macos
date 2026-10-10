package control

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/mcp"
	"github.com/personastack/macos/agent-bridge/internal/pairing"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
)

type Controller struct {
	Store              config.WritableStore
	Seed               string
	Environments       func() ([]Environment, error)
	Discover           func(runtime.AdapterKind, string) ([]targetinventory.Profile, []error)
	Exchange           func(context.Context, Environment, pairing.Request) (pairing.Result, error)
	Check              func(context.Context, config.Binding) (runtime.Detection, error)
	Repair             func(context.Context, config.Binding, bool) error
	Cleanup            func(config.Binding) error
	Now                func() time.Time
	Stop               func() error
	Shutdown           func()
	mu                 sync.Mutex
	preparations       map[string]preparation
	migrations         map[string]migration
	LegacyRead         func(Environment, MigrationPreparePayload) (config.Binding, error)
	MigrationDirectory string
}

func strict(raw []byte, destination interface{}) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	err := decoder.Decode(destination)
	if err != nil {
		return fmt.Errorf("decode private control: %w", err)
	}
	var extra json.RawMessage
	err = decoder.Decode(&extra)
	if err != io.EOF {
		return fmt.Errorf("one control payload required")
	}
	return nil
}
func (c *Controller) Dispatch(ctx context.Context, raw []byte) Response {
	request := Request{}
	response := Response{Version: Version}
	if len(raw) > MaxBytes {
		return failed(response, "invalid_request", "request exceeds limit")
	}
	err := strict(raw, &request)
	response.RequestID = request.RequestID
	if err != nil {
		return failed(response, "invalid_request", "invalid control envelope")
	}
	if request.Version != Version {
		return failed(response, "unsupported_version", "unsupported control protocol")
	}
	if !validUUID(request.RequestID) || len(request.Payload) == 0 || bytes.Equal(request.Payload, []byte("null")) {
		return failed(response, "invalid_request", "request ID and payload required")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.preparations == nil {
		c.preparations = map[string]preparation{}
	}
	c.expirePreparations()
	result, err := c.perform(ctx, request)
	if err != nil {
		code := "invalid_request"
		if classified, ok := err.(*Error); ok {
			code = classified.Code
		}
		return failed(response, code, diagnostic(err))
	}
	result.Operation = request.Operation
	response.Result = &result
	encoded, err := json.Marshal(response)
	if err != nil || len(encoded) > MaxBytes {
		return failed(response, "invalid_request", "response exceeds limit")
	}
	return response
}
func failed(response Response, code, message string) Response {
	response.Error = &Error{Code: code, Message: message}
	return response
}
func diagnostic(err error) string {
	if classified, ok := err.(*Error); ok {
		return classified.Message
	}
	return "Local operation failed. Check this profile and try again."
}
func validUUID(value string) bool      { _, err := uuid.Parse(value); return err == nil }
func issue(code, message string) error { return &Error{Code: code, Message: message} }
func (c *Controller) now() time.Time {
	if c.Now != nil {
		return c.Now().UTC()
	}
	return time.Now().UTC()
}
func (c *Controller) expirePreparations() {
	for id, p := range c.migrations {
		if !c.now().Before(p.ExpiresAt) {
			delete(c.migrations, id)
		}
	}
	for id, p := range c.preparations {
		if !c.now().Before(p.ExpiresAt) {
			delete(c.preparations, id)
		}
	}
}
func kind(value string) (runtime.AdapterKind, error) {
	switch value {
	case "hermes":
		return runtime.AdapterKindHermes, nil
	case "openclaw":
		return runtime.AdapterKindOpenClaw, nil
	default:
		return 0, issue("runtime_unsupported", "Choose Hermes or OpenClaw.")
	}
}
func (c *Controller) environment(id string) (Environment, error) {
	normalized, err := config.NormalizeEnvironment(id)
	if err != nil || normalized != id {
		return Environment{}, issue("scope_changed", "Approved environment required.")
	}
	environments, err := c.Environments()
	if err != nil {
		return Environment{}, issue("scope_changed", "Native environment configuration unavailable.")
	}
	for _, environment := range environments {
		if environment.EnvironmentID == id {
			return environment, nil
		}
	}
	return Environment{}, issue("scope_changed", "Environment is not approved by the desktop app.")
}
func (c *Controller) profiles(k runtime.AdapterKind) ([]targetinventory.Profile, []error) {
	if c.Discover != nil {
		return c.Discover(k, c.Seed)
	}
	return targetinventory.Profiles(k, c.Seed)
}
func (c *Controller) perform(ctx context.Context, r Request) (Result, error) {
	switch r.Operation {
	case "migration_prepare":
		p := MigrationPreparePayload{}
		if err := strict(r.Payload, &p); err != nil {
			return Result{}, err
		}
		return c.prepareMigration(p)
	case "discover":
		p := DiscoverPayload{}
		err := strict(r.Payload, &p)
		if err != nil {
			return Result{}, err
		}
		return c.discover(p)
	case "prepare":
		p := PreparePayload{}
		err := strict(r.Payload, &p)
		if err != nil {
			return Result{}, err
		}
		return c.prepare(p)
	case "enroll":
		p := EnrollPayload{}
		err := strict(r.Payload, &p)
		if err != nil {
			return Result{}, err
		}
		return c.enroll(ctx, p)
	case "status", "check":
		p := BindingPayload{}
		err := strict(r.Payload, &p)
		if err != nil {
			return Result{}, err
		}
		return c.status(ctx, p, r.Operation == "check")
	case "repair":
		p := RepairPayload{}
		err := strict(r.Payload, &p)
		if err != nil {
			return Result{}, err
		}
		return c.repair(ctx, p)
	case "disconnect":
		p := DisconnectPayload{}
		err := strict(r.Payload, &p)
		if err != nil {
			return Result{}, err
		}
		return c.disconnect(p)
	case "quiesce", "resume":
		p := BindingPayload{}
		err := strict(r.Payload, &p)
		if err != nil {
			return Result{}, err
		}
		return c.quiesce(p, r.Operation == "quiesce")
	case "stop_background":
		p := struct{}{}
		err := strict(r.Payload, &p)
		if err != nil {
			return Result{}, err
		}
		return c.stopBackground()
	default:
		return Result{}, issue("invalid_request", "Unknown local operation.")
	}
}
func (c *Controller) discover(p DiscoverPayload) (Result, error) {
	_, err := c.environment(p.EnvironmentID)
	if err != nil {
		return Result{}, err
	}
	k, err := kind(p.RuntimeKind)
	if err != nil {
		return Result{}, err
	}
	profiles, warnings := c.profiles(k)
	result := Result{Profiles: []Profile{}, DiscoveryStatus: "complete"}
	if len(warnings) > 0 {
		result.DiscoveryStatus = "degraded"
	}
	for _, profile := range profiles {
		row := Profile{ProfileCandidateID: profile.CandidateID, AccountCandidateID: profile.AccountCandidateID, Label: profile.Label, RuntimeKind: k.String()}
		if _, occupied := c.boundProfile(profile); occupied {
			row.ConflictCode = "profile_in_use"
		}
		result.Profiles = append(result.Profiles, row)
	}
	return result, nil
}
func (c *Controller) boundProfile(profile targetinventory.Profile) (config.Binding, bool) {
	for _, binding := range c.Store.ListBindings() {
		if binding.RuntimeKind != profile.Kind {
			continue
		}
		physical := targetinventory.ResolvedTarget{StateRoot: binding.NativeStateRoot, ConfigPath: binding.NativeConfigPath}
		if targetinventory.SharedPhysicalTarget(profile.Resolved, physical) {
			return binding, true
		}
	}
	return config.Binding{}, false
}
func (c *Controller) prepare(p PreparePayload) (Result, error) {
	_, err := c.environment(p.EnvironmentID)
	if err != nil {
		return Result{}, err
	}
	if !validPersonaID(p.PersonaID) || !validWorkspaceID(p.WorkspaceID) || !validUUID(p.DocumentID) {
		return Result{}, issue("invalid_request", "Native persona/workspace/document scope required.")
	}
	k, err := kind(p.RuntimeKind)
	if err != nil {
		return Result{}, err
	}
	profiles, _ := c.profiles(k)
	for _, profile := range profiles {
		if profile.CandidateID != p.ProfileCandidateID {
			continue
		}
		if bound, exists := c.boundProfile(profile); exists {
			if bound.EnvironmentID == p.EnvironmentID && string(bound.PersonaID) == p.PersonaID && bound.WorkspaceID == p.WorkspaceID {
				key := bound.Key()
				return Result{ExistingBindingKey: &key}, nil
			}
			return Result{}, issue("profile_in_use", "This profile is connected to another persona.")
		}
		for _, reserved := range c.preparations {
			if reserved.Profile.Kind == k && targetinventory.SharedPhysicalTarget(profile.Resolved, reserved.Profile.Resolved) {
				return Result{}, issue("profile_in_use", "This profile has an active setup.")
			}
		}
		if len(c.preparations) >= 128 {
			return Result{}, issue("busy", "Too many active native setups.")
		}
		publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return Result{}, issue("credential_unavailable", "Could not prepare the native key.")
		}
		id := uuid.NewString()
		expires := c.now().Add(5 * time.Minute)
		c.preparations[id] = preparation{Scope: p, Profile: profile, PublicKey: publicKey, PrivateKey: privateKey, ExpiresAt: expires}
		return Result{PreparationID: id, DevicePublicKey: base64.StdEncoding.EncodeToString(publicKey), ProfileCandidateID: profile.CandidateID, ExpiresAt: &expires}, nil
	}
	return Result{}, issue("scope_changed", "Selected profile is no longer available.")
}
func (c *Controller) enroll(ctx context.Context, p EnrollPayload) (Result, error) {
	prepared, ok := c.preparations[p.PreparationID]
	if !ok || prepared.Scope.DocumentID != p.DocumentID || strings.TrimSpace(p.Code) == "" {
		return Result{}, issue("scope_changed", "Prepared native scope expired or changed.")
	}
	environment, err := c.environment(prepared.Scope.EnvironmentID)
	if err != nil {
		return Result{}, err
	}
	if _, occupied := c.boundProfile(prepared.Profile); occupied {
		return Result{}, issue("profile_in_use", "Profile is already connected.")
	}
	var captured *config.MigrationCapture
	if p.MigrationID != "" {
		capture, ok := c.migrations[p.MigrationID]
		if !ok || capture.DocumentID != p.DocumentID || capture.Scope != prepared.Scope || !c.now().Before(capture.ExpiresAt) {
			return Result{}, issue("scope_changed", "Migration capture no longer matches this setup.")
		}
		copy := capture.Capture
		captured = &copy
	}
	k, _ := kind(prepared.Scope.RuntimeKind)
	proof := externalagentprotocol.DesktopPreparation{PreparationID: p.PreparationID, DevicePublicKey: base64.StdEncoding.EncodeToString(prepared.PublicKey), ProfileCandidateID: prepared.Profile.CandidateID}
	request := pairing.Request{Code: p.Code, RuntimeKind: k, ConfigureMCP: true, PrivateKey: prepared.PrivateKey, DesktopPreparation: &proof}
	var paired pairing.Result
	if c.Exchange != nil {
		paired, err = c.Exchange(ctx, environment, request)
	} else {
		paired, err = (pairing.Client{GatewayBaseURL: environment.GatewayBaseURL}).Exchange(ctx, request)
	}
	if err != nil {
		return Result{}, issue("credential_unavailable", "Native enrollment failed. Authorize setup again.")
	}
	binding := paired.Binding
	if string(binding.PersonaID) != prepared.Scope.PersonaID || binding.RuntimeKind != k || binding.ConnectionID == "" {
		return Result{}, issue("scope_changed", "Enrollment response changed prepared persona/profile.")
	}
	binding.EnvironmentID = environment.EnvironmentID
	binding.WorkspaceID = prepared.Scope.WorkspaceID
	binding.ProfileCandidateID = prepared.Profile.CandidateID
	binding.AccountCandidateID = prepared.Profile.AccountCandidateID
	binding.InventorySeed = c.Seed
	binding.PhysicalProfileID = prepared.Profile.Resolved.PhysicalID
	binding.NativeStateRoot = prepared.Profile.Resolved.StateRoot
	binding.NativeConfigPath = prepared.Profile.Resolved.ConfigPath
	binding.NativeProfileName = prepared.Profile.Resolved.ProfileName
	binding.HermesHome = prepared.Profile.Resolved.HermesHome
	binding.OpenClawAgentID = prepared.Profile.Resolved.OpenClawAgentID

	binding.Migration = captured
	err = c.Store.SaveBinding(binding)
	if err != nil {
		return Result{}, issue("credential_unavailable", "Could not save native enrollment credentials.")
	}
	delete(c.preparations, p.PreparationID)
	if p.MigrationID != "" {
		delete(c.migrations, p.MigrationID)
	}
	key := binding.Key()
	return Result{BindingKey: &key, PersonaID: string(binding.PersonaID)}, nil
}
func (c *Controller) owned(key config.BindingKey) (config.Binding, error) {
	b, ok := config.BindingFor(c.Store, config.Binding{EnvironmentID: key.EnvironmentID, ConnectionID: key.ConnectionID})
	if !ok {
		return config.Binding{}, issue("scope_changed", "Connection no longer belongs to this helper.")
	}
	return b, nil
}
func (c *Controller) selected(payload BindingPayload) ([]config.Binding, error) {
	if payload.BindingKey != nil {
		b, err := c.owned(*payload.BindingKey)
		if err != nil {
			return nil, err
		}
		return []config.Binding{b}, nil
	}
	return c.Store.ListBindings(), nil
}
func (c *Controller) status(ctx context.Context, p BindingPayload, probe bool) (Result, error) {
	bindings, err := c.selected(p)
	if err != nil {
		return Result{}, err
	}
	result := Result{Connections: []Connection{}}
	for _, b := range bindings {
		row := Connection{BindingKey: b.Key(), PersonaID: string(b.PersonaID), RuntimeKind: b.RuntimeKind.String(), ReadinessState: b.ReadinessState.String(), ActiveRunID: b.ActiveRunID}
		if b.Quiesced {
			row.ReadinessState = "unavailable"
			row.DiagnosticCode = "busy"
		}
		if probe {
			if c.Check == nil {
				row.ReadinessState = "unavailable"
				row.DiagnosticCode = "runtime_unsupported"
			} else {
				detection, err := c.Check(ctx, b)
				if err != nil {
					row.ReadinessState = "unavailable"
					row.DiagnosticCode = "runtime_conflict"
				} else {
					row.ReadinessState = detection.State.String()
					row.DiagnosticCode = detection.DiagnosticCode
				}
			}
		}
		result.Connections = append(result.Connections, row)
	}
	return result, nil
}
func (c *Controller) repair(ctx context.Context, p RepairPayload) (Result, error) {
	b, err := c.owned(p.BindingKey)
	if err != nil {
		return Result{}, err
	}
	if p.PreparationID != "" {
		return Result{}, issue("scope_changed", "Credential renewal requires the authorized enrollment flow.")
	}
	if c.Repair == nil {
		return Result{}, issue("runtime_unsupported", "Repair is not available.")
	}
	err = c.Repair(ctx, b, p.RestartConfirmed)
	if err != nil {
		return Result{}, issue("cleanup_required", "Profile needs repair. Existing files and credentials were preserved.")
	}
	return c.status(ctx, BindingPayload{BindingKey: &p.BindingKey}, false)
}
func (c *Controller) disconnect(p DisconnectPayload) (Result, error) {
	b, err := c.owned(p.BindingKey)
	if err != nil {
		return Result{}, err
	}
	proof := p.RevocationReadback
	if p.WorkspaceID != b.WorkspaceID || p.PersonaID != string(b.PersonaID) || p.ConnectionGeneration != b.ConnectionGeneration || !proof.BindingAbsent || proof.EnvironmentID != b.EnvironmentID || proof.WorkspaceID != b.WorkspaceID || proof.PersonaID != string(b.PersonaID) || proof.ConnectionID != b.ConnectionID || proof.ConnectionGeneration != b.ConnectionGeneration {
		return Result{}, issue("scope_changed", "Exact authorized revoke readback is required.")
	}
	if b.ActiveRunID != "" {
		return Result{}, issue("busy", "Stop the assigned run before disconnecting.")
	}
	cleanup := c.Cleanup
	if cleanup == nil {
		cleanup = mcp.RemoveOwned
	}
	err = cleanup(b)
	if err != nil {
		return Result{}, issue("cleanup_required", "Native MCP entry changed. Remove the owned entry manually.")
	}
	err = config.DeleteBindingFor(c.Store, b)
	if err != nil {
		return Result{}, issue("credential_unavailable", "Could not remove this connection's credentials.")
	}
	done := true
	return Result{Disconnected: &done}, nil
}
func (c *Controller) quiesce(p BindingPayload, value bool) (Result, error) {
	bindings, err := c.selected(p)
	if err != nil {
		return Result{}, err
	}
	result := Result{ActiveRunIDs: []string{}, Quiesced: &value}
	for _, b := range bindings {
		err = config.UpdateBinding(c.Store, b, func(latest *config.Binding) error { latest.Quiesced = value; b = *latest; return nil })
		if err != nil {
			return Result{}, issue("credential_unavailable", "Could not change native admission state.")
		}
		if b.ActiveRunID != "" {
			result.ActiveRunIDs = append(result.ActiveRunIDs, b.ActiveRunID)
		}
	}
	return result, nil
}
func (c *Controller) stopBackground() (Result, error) {
	admission, err := c.quiesce(BindingPayload{}, true)
	if err != nil {
		return Result{}, err
	}
	if len(admission.ActiveRunIDs) > 0 {
		return Result{}, issue("busy", "Stop assigned runs before disabling background agents.")
	}
	if c.Stop != nil {
		err := c.Stop()
		if err != nil {
			return Result{}, err
		}
	}
	disabled := true
	return Result{Disabled: &disabled}, nil
}

func validPersonaID(value string) bool {
	if len(value) == 0 || len(value) > 128 {
		return false
	}
	for _, char := range value {
		if !(char >= 'a' && char <= 'z') && !(char >= 'A' && char <= 'Z') && !(char >= '0' && char <= '9') && char != '-' && char != '_' {
			return false
		}
	}
	return true
}
func validWorkspaceID(value string) bool {
	if len(value) != 35 || !strings.HasPrefix(value, "ws_") {
		return false
	}
	for _, char := range value[3:] {
		if !(char >= '0' && char <= '9') && !(char >= 'a' && char <= 'f') {
			return false
		}
	}
	return true
}
