package control

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/pairing"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
)

func request(t *testing.T, c *Controller, operation string, payload string) Response {
	t.Helper()
	raw := `{"version":1,"request_id":"` + uuid.NewString() + `","operation":"` + operation + `","payload":` + payload + `}`
	return c.Dispatch(context.Background(), []byte(raw))
}
func fixture(t *testing.T) (*Controller, *config.MemoryStore, []targetinventory.Profile) {
	t.Helper()
	store := config.EmptyStore()
	profiles := []targetinventory.Profile{}
	for i, k := range []runtime.AdapterKind{runtime.AdapterKindHermes, runtime.AdapterKindHermes, runtime.AdapterKindOpenClaw} {
		label := []string{"one", "two", "three"}[i]
		profiles = append(profiles, targetinventory.Profile{CandidateID: "rt_" + label, AccountCandidateID: "rt_account", Label: label, Kind: k, Resolved: targetinventory.ResolvedTarget{StateRoot: "/fixture/" + label, ConfigPath: "/fixture/" + label + "/config", PhysicalID: "physical_" + label}})
	}
	profiles[2].OpenClawAgents = []targetinventory.OpenClawAgent{{CandidateID: "rt_agent", ID: "research", Label: "Research"}}
	c := &Controller{Store: &store, Seed: "seed", Now: func() time.Time { return time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC) }, Environments: func() ([]Environment, error) {
		return []Environment{{EnvironmentID: "https://app.test", GatewayBaseURL: "https://gateway.test"}}, nil
	}, Discover: func(k runtime.AdapterKind, seed string) ([]targetinventory.Profile, []error) {
		result := []targetinventory.Profile{}
		for _, p := range profiles {
			if p.Kind == k {
				result = append(result, p)
			}
		}
		return result, nil
	}}
	return c, &store, profiles
}
func prepare(t *testing.T, c *Controller, profile targetinventory.Profile, persona, workspace, document string) Response {
	t.Helper()
	raw, _ := json.Marshal(PreparePayload{EnvironmentID: "https://app.test", WorkspaceID: workspace, PersonaID: persona, RuntimeKind: profile.Kind.String(), ProfileCandidateID: profile.CandidateID, DocumentID: document})
	return request(t, c, "prepare", string(raw))
}
func TestDesktopAgentBridgeThreeProfileControlWorkflow(t *testing.T) {
	t.Parallel()
	c, store, profiles := fixture(t)
	workspace := "ws_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	documents := []string{}
	personas := []string{}
	keys := []config.BindingKey{}
	exchangeCount := 0
	c.Exchange = func(ctx context.Context, environment Environment, p pairing.Request) (pairing.Result, error) {
		exchangeCount++
		if environment.GatewayBaseURL != "https://gateway.test" || !p.ConfigureMCP || len(p.PrivateKey) != 64 || p.DesktopPreparation.DevicePublicKey != base64.StdEncoding.EncodeToString(p.PrivateKey[32:]) {
			t.Fatal("wrong exact pairing claims")
		}
		return pairing.Result{Binding: config.Binding{ConnectionID: config.ConnectionID(uuid.NewString()), PersonaID: config.PersonaID(personas[exchangeCount-1]), RuntimeKind: p.RuntimeKind, ConnectionGeneration: 1, PersonaMCPToken: "secret-token", BridgePrivateKey: base64.StdEncoding.EncodeToString(p.PrivateKey)}}, nil
	}
	for _, profile := range profiles {
		persona := uuid.NewString()
		document := uuid.NewString()
		personas = append(personas, persona)
		documents = append(documents, document)
		prepared := prepare(t, c, profile, persona, workspace, document)
		if prepared.Error != nil {
			t.Fatal(prepared.Error)
		}
		public, err := base64.StdEncoding.DecodeString(prepared.Result.DevicePublicKey)
		if err != nil || len(public) != 32 {
			t.Fatal("prepared key format")
		}
		payload, _ := json.Marshal(EnrollPayload{PreparationID: prepared.Result.PreparationID, Code: "one-use-code", DocumentID: document})
		enrolled := request(t, c, "enroll", string(payload))
		if enrolled.Error != nil {
			t.Fatal(enrolled.Error)
		}
		keys = append(keys, *enrolled.Result.BindingKey)
	}
	if len(store.ListBindings()) != 3 {
		t.Fatal("binding siblings lost")
	}
	first, _ := store.BindingKey(keys[0])
	first.ActiveRunID = "assigned-first"
	_ = store.SaveBinding(first)
	status := request(t, c, "status", `{}`)
	raw, _ := json.Marshal(status)
	if strings.Contains(string(raw), "secret-token") || strings.Contains(string(raw), "PrivateKey") || strings.Contains(string(raw), "/fixture/") {
		t.Fatal("native status leaks secrets/path")
	}
	quiesced := request(t, c, "quiesce", `{}`)
	if quiesced.Error != nil || len(quiesced.Result.ActiveRunIDs) != 1 {
		t.Fatal("accepted work not retained on quiesce")
	}
	stopCalls := 0
	c.Stop = func() error { stopCalls++; return nil }
	stopped := request(t, c, "stop_background", `{}`)
	if stopped.Error == nil || stopped.Error.Code != "busy" || stopCalls != 0 {
		t.Fatal("busy stop changed service")
	}
	first.ActiveRunID = ""
	first.Quiesced = true
	_ = store.SaveBinding(first)
	deleted := keys[1]
	target, _ := store.BindingKey(deleted)
	cleanupCalls := 0
	c.Cleanup = func(b config.Binding) error {
		cleanupCalls++
		if b.Key() != deleted {
			t.Fatal("cleanup affected sibling")
		}
		return nil
	}
	wrong := DisconnectPayload{BindingKey: deleted, WorkspaceID: workspace, PersonaID: string(target.PersonaID), ConnectionGeneration: 1, RevocationReadback: RevocationReadback{EnvironmentID: "https://app.test", WorkspaceID: workspace, PersonaID: string(target.PersonaID), ConnectionID: deleted.ConnectionID, ConnectionGeneration: 1, BindingAbsent: false}}
	body, _ := json.Marshal(wrong)
	denied := request(t, c, "disconnect", string(body))
	if denied.Error == nil || cleanupCalls != 0 || len(store.ListBindings()) != 3 {
		t.Fatal("unproven revoke removed custody")
	}
	wrong.RevocationReadback.BindingAbsent = true
	body, _ = json.Marshal(wrong)
	done := request(t, c, "disconnect", string(body))
	if done.Error != nil || cleanupCalls != 1 || len(store.ListBindings()) != 2 {
		t.Fatal("targeted disconnect failed")
	}
	repeat := prepare(t, c, profiles[0], personas[0], workspace, documents[0])
	if repeat.Error != nil || repeat.Result.ExistingBindingKey == nil || *repeat.Result.ExistingBindingKey != keys[0] {
		t.Fatal("repeat setup did not manage binding")
	}
}
func TestDesktopAgentBridgePreparationIsolation(t *testing.T) {
	t.Parallel()
	c, store, profiles := fixture(t)
	persona := uuid.NewString()
	workspace := "ws_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	document := uuid.NewString()
	prepared := prepare(t, c, profiles[0], persona, workspace, document)
	exchanges := 0
	c.Exchange = func(context.Context, Environment, pairing.Request) (pairing.Result, error) {
		exchanges++
		t.Fatal("unplanned pairing exchange")
		return pairing.Result{}, nil
	}
	for _, row := range []EnrollPayload{{PreparationID: uuid.NewString(), Code: "code", DocumentID: document}, {PreparationID: prepared.Result.PreparationID, Code: "code", DocumentID: uuid.NewString()}} {
		raw, _ := json.Marshal(row)
		result := request(t, c, "enroll", string(raw))
		if result.Error == nil || result.Error.Code != "scope_changed" {
			t.Fatal("foreign prepared scope accepted")
		}
	}
	c.Now = func() time.Time { return time.Date(2026, 10, 10, 12, 6, 0, 0, time.UTC) }
	raw, _ := json.Marshal(EnrollPayload{PreparationID: prepared.Result.PreparationID, Code: "code", DocumentID: document})
	result := request(t, c, "enroll", string(raw))
	if result.Error == nil || exchanges != 0 || len(store.ListBindings()) != 0 {
		t.Fatal("expired preparation mutated")
	}
}
func TestDesktopAgentBridgeConcurrentProfileReservation(t *testing.T) {
	t.Parallel()
	c, _, profiles := fixture(t)
	workspace := "ws_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	var wg sync.WaitGroup
	responses := make(chan Response, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			responses <- prepare(t, c, profiles[0], uuid.NewString(), workspace, uuid.NewString())
		}()
	}
	wg.Wait()
	close(responses)
	accepted, conflicts := 0, 0
	for response := range responses {
		if response.Error == nil {
			accepted++
		} else if response.Error.Code == "profile_in_use" {
			conflicts++
		} else {
			t.Fatal(response.Error)
		}
	}
	if accepted != 1 || conflicts != 1 {
		t.Fatal("profile reservation race")
	}
}
func TestDesktopAgentBridgeControlDenials(t *testing.T) {
	t.Parallel()
	c, store, _ := fixture(t)
	for _, raw := range []string{`{"version":2,"request_id":"` + uuid.NewString() + `","operation":"status","payload":{}}`, `{"version":1,"request_id":"` + uuid.NewString() + `","operation":"status","payload":{"extra":true}}`, `{"version":1,"request_id":"` + uuid.NewString() + `","operation":"status","payload":{},"extra":true}`, strings.Repeat("x", MaxBytes+1)} {
		response := c.Dispatch(context.Background(), []byte(raw))
		if response.Error == nil || response.Result != nil || len(store.ListBindings()) != 0 {
			t.Fatal("invalid request admitted")
		}
	}
	for _, operation := range []string{"status", "discover", "quiesce"} {
		payload := `{}`
		if operation == "discover" {
			payload = `{"environment_id":"https://app.test","runtime_kind":"hermes"}`
		}
		response := request(t, c, operation, payload)
		raw, _ := json.Marshal(response)
		expected := map[string]string{"status": `"connections":[]`, "quiesce": `"active_run_ids":[]`, "discover": `"profiles":[`}[operation]
		if !strings.Contains(string(raw), expected) {
			t.Fatalf("required array omitted: %s", raw)
		}
	}
}
func TestDesktopAgentBridgeUnsafeEnvironmentFile(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	path := directory + "/environments.json"
	err := os.WriteFile(path, []byte(`[]`), 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := LoadEnvironments(directory); err == nil {
		t.Fatal("world-readable native environment file accepted")
	}
}

func TestDesktopAgentBridgeMigrationCaptureScope(t *testing.T) {
	t.Parallel()
	c, _, profiles := fixture(t)
	root := t.TempDir()
	path := root + "/config.yaml"
	raw := "mcp_servers:\n  old-issued:\n    transport: streamable-http\n    url: https://mcp.test/mcp\n    headers:\n      Authorization: Bearer old-secret\n"
	if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	profiles[0].Resolved.ConfigPath = path
	c.Discover = func(k runtime.AdapterKind, seed string) ([]targetinventory.Profile, []error) {
		return profiles[:1], nil
	}
	c.MigrationDirectory = root + "/private"
	workspace := "ws_" + strings.Repeat("a", 32)
	document := uuid.NewString()
	scope := PreparePayload{EnvironmentID: "https://app.test", WorkspaceID: workspace, PersonaID: "persona", RuntimeKind: "hermes", ProfileCandidateID: profiles[0].CandidateID, DocumentID: document}
	calls := 0
	c.LegacyRead = func(environment Environment, p MigrationPreparePayload) (config.Binding, error) {
		calls++
		if environment.GatewayBaseURL != "https://gateway.test" || p.ConnectionID != "old" {
			t.Fatal("wrong legacy custody")
		}
		return config.Binding{ConnectionID: "old", PersonaID: "persona", ConnectionGeneration: 2, RuntimeKind: runtime.AdapterKindHermes, NativeMCPServer: "old-issued", NativeMCPNamespace: "mcp_old", PersonaMCPURL: "https://mcp.test/mcp", PersonaMCPToken: "old-secret"}, nil
	}
	wasPaused, pauseVersion := false, int64(0)
	payload, _ := json.Marshal(MigrationPreparePayload{PreparePayload: scope, ConnectionID: "old", ConnectionGeneration: 2, WasPaused: &wasPaused, PauseVersion: &pauseVersion})
	result := request(t, c, "migration_prepare", string(payload))
	if result.Error != nil || result.Result.MigrationID == "" || result.Result.LegacyServiceScope != "user_launch_agent" {
		t.Fatalf("capture %+v", result)
	}
	setup := prepare(t, c, profiles[0], "persona", workspace, document)
	if setup.Error != nil {
		t.Fatal(setup.Error)
	}
	c.Exchange = func(ctx context.Context, env Environment, p pairing.Request) (pairing.Result, error) {
		return pairing.Result{Binding: config.Binding{ConnectionID: "new", PersonaID: "persona", RuntimeKind: runtime.AdapterKindHermes}}, nil
	}
	enroll, _ := json.Marshal(EnrollPayload{PreparationID: setup.Result.PreparationID, Code: "code", DocumentID: document, MigrationID: result.Result.MigrationID})
	enrolled := request(t, c, "enroll", string(enroll))
	if enrolled.Error != nil {
		t.Fatal(enrolled.Error)
	}
	binding, _ := c.Store.Binding("new")
	if binding.Migration == nil || binding.Migration.LegacyConnectionID != "old" || calls != 1 {
		t.Fatal("capture not held by exact new binding")
	}
	after, _ := os.ReadFile(path)
	if string(after) != raw {
		t.Fatal("capture/enroll changed native config before target selection")
	}
}

func TestDesktopAgentBridgeInterruptedMigrationRepair(t *testing.T) {
	t.Parallel()
	c, _, profiles := fixture(t)
	workspace := "ws_" + strings.Repeat("b", 32)
	oldDocument, newDocument := uuid.NewString(), uuid.NewString()
	scope := PreparePayload{EnvironmentID: "https://app.test", WorkspaceID: workspace, PersonaID: "persona", RuntimeKind: "hermes", ProfileCandidateID: profiles[0].CandidateID, DocumentID: oldDocument}
	c.migrations = map[string]migration{"captured": {Scope: scope, DocumentID: oldDocument, Capture: config.MigrationCapture{ID: "captured", LegacyConnectionID: "old", WasPaused: true, PauseVersion: 7}, ExpiresAt: c.now().Add(time.Minute)}}
	currentPauseVersion := int64(7)
	p := MigrationRepairPayload{PauseVersion: &currentPauseVersion, PreparePayload: scope, RevocationReadback: MigrationAbsenceReadback{EnvironmentID: scope.EnvironmentID, WorkspaceID: workspace, PersonaID: "persona", BindingAbsent: true}}
	p.DocumentID = newDocument
	foreign := prepare(t, c, profiles[0], "another-persona", workspace, newDocument)
	if foreign.Error == nil || foreign.Error.Code != "profile_in_use" {
		t.Fatal("foreign persona capture claim admitted")
	}
	pending := prepare(t, c, profiles[0], "persona", workspace, newDocument)
	if pending.Error != nil || !pending.Result.MigrationPending || pending.Result.PreparationID != "" {
		t.Fatal("interrupted migration bypassed pending gate")
	}
	currentPauseVersion = 8
	stale, _ := json.Marshal(p)
	staleResult := request(t, c, "migration_repair", string(stale))
	if staleResult.Error == nil || c.migrations["captured"].DocumentID != oldDocument {
		t.Fatal("changed pause version rebound capture")
	}
	currentPauseVersion = 7
	raw, _ := json.Marshal(p)
	result := request(t, c, "migration_repair", string(raw))
	if result.Error != nil || result.Result.MigrationID != "captured" || result.Result.WasPaused == nil || !*result.Result.WasPaused || result.Result.PauseVersion == nil || *result.Result.PauseVersion != 7 || c.migrations["captured"].Scope.DocumentID != newDocument {
		t.Fatalf("repair %+v", result)
	}

	fresh := prepare(t, c, profiles[0], "persona", workspace, newDocument)
	if fresh.Error != nil || fresh.Result.MigrationPending || fresh.Result.PreparationID == "" {
		t.Fatal("repaired capture did not reopen ordinary prepare")
	}
	p.ProfileCandidateID = profiles[1].CandidateID
	raw, _ = json.Marshal(p)
	result = request(t, c, "migration_repair", string(raw))
	if result.Error == nil {
		t.Fatal("foreign profile repair admitted")
	}
	if c.migrations["captured"].DocumentID != newDocument {
		t.Fatal("foreign repair changed capture")
	}
	p.ProfileCandidateID = profiles[0].CandidateID
	p.RevocationReadback.PersonaID = "foreign"
	raw, _ = json.Marshal(p)
	result = request(t, c, "migration_repair", string(raw))
	if result.Error == nil {
		t.Fatal("foreign readback admitted")
	}
	p.RevocationReadback.PersonaID = "persona"
	capture := c.migrations["captured"]
	capture.ExpiresAt = c.now().Add(-time.Second)
	c.migrations["captured"] = capture
	raw, _ = json.Marshal(p)
	result = request(t, c, "migration_repair", string(raw))
	if result.Error == nil || len(c.migrations) != 0 {
		t.Fatal("expired capture renewed")
	}
	result = request(t, c, "migration_repair", string(raw))
	if result.Error == nil {
		t.Fatal("missing capture synthesized")
	}
}

func TestDesktopAgentBridgePendingMigrationUpdateGate(t *testing.T) {
	t.Parallel()
	c, store, _ := fixture(t)
	c.migrations = map[string]migration{"pending": {ExpiresAt: c.now().Add(time.Minute)}}
	status := request(t, c, "status", `{}`)
	raw, _ := json.Marshal(status)
	if !strings.Contains(string(raw), `"pending_migration_count":1`) {
		t.Fatalf("missing finite pending count %s", raw)
	}
	blocked := request(t, c, "quiesce", `{}`)
	if blocked.Error == nil || blocked.Error.Code != "busy" {
		t.Fatal("update quiesce lost pending capture")
	}
	delete(c.migrations, "pending")
	binding := config.Binding{EnvironmentID: "https://app.test", ConnectionID: "enrolled", Migration: &config.MigrationCapture{ID: "bound"}}
	store.SaveBinding(binding)
	status = request(t, c, "status", `{}`)
	if status.Result.PendingMigrationCount != 1 {
		t.Fatal("bound uninstalled migration omitted")
	}
	config.UpdateBinding(store, binding, func(latest *config.Binding) error { latest.Migration = nil; return nil })
	status = request(t, c, "status", `{}`)
	raw, _ = json.Marshal(status)
	if !strings.Contains(string(raw), `"pending_migration_count":0`) {
		t.Fatal("completed migration blocks update")
	}
}

func TestDesktopAgentBridgeCancelMigrationBeforeRevocation(t *testing.T) {
	t.Parallel()
	c, _, profiles := fixture(t)
	document := uuid.NewString()
	scope := PreparePayload{EnvironmentID: "https://app.test", WorkspaceID: "ws_" + strings.Repeat("c", 32), PersonaID: "persona", RuntimeKind: "hermes", ProfileCandidateID: profiles[0].CandidateID, DocumentID: document}
	c.migrations = map[string]migration{"pending": {LegacyGeneration: 2, Scope: scope, DocumentID: document, Capture: config.MigrationCapture{LegacyConnectionID: "old"}, ExpiresAt: c.now().Add(time.Minute)}}
	p := MigrationCancelPayload{MigrationID: "pending", DocumentID: document, LegacyBindingReadback: LegacyPresenceReadback{EnvironmentID: scope.EnvironmentID, WorkspaceID: scope.WorkspaceID, PersonaID: "persona", ConnectionID: "old", ConnectionGeneration: 2, BindingPresent: false}}
	raw, _ := json.Marshal(p)
	denied := request(t, c, "migration_cancel", string(raw))
	if denied.Error == nil || len(c.migrations) != 1 {
		t.Fatal("revoked migration discarded")
	}
	p.LegacyBindingReadback.BindingPresent = true
	raw, _ = json.Marshal(p)
	cancelled := request(t, c, "migration_cancel", string(raw))
	if cancelled.Error != nil || cancelled.Result.Cancelled == nil || !*cancelled.Result.Cancelled || len(c.migrations) != 0 {
		t.Fatal("unrevoked capture not cancelled")
	}
}

func TestDesktopAgentBridgeManualMigrationHelpAndResetGate(t *testing.T) {
	t.Parallel()
	c, store, profiles := fixture(t)
	root := t.TempDir()
	path := root + "/config.yaml"
	original := "mcp_servers:\n  old-issued:\n    transport: streamable-http\n    url: https://mcp.test/mcp\n    headers:\n      Authorization: Bearer never-return-this\n"
	if err := os.WriteFile(path, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	profiles[0].Resolved.ConfigPath = path
	c.Discover = func(k runtime.AdapterKind, seed string) ([]targetinventory.Profile, []error) {
		return profiles[:1], nil
	}
	c.MigrationDirectory = root + "/backups"
	websocket, err := externalagentprotocol.ResolveWebsocketURL("https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	legacy := config.Binding{ConnectionID: "old", PersonaID: "persona", RuntimeKind: runtime.AdapterKindHermes, NativeMCPServer: "old-issued", PersonaMCPURL: "https://mcp.test/mcp", GatewayWebsocketURL: websocket}
	c.LegacyMetadataRead = func(e Environment) ([]config.Binding, error) {
		if e.EnvironmentID != "https://app.test" {
			t.Fatal("wrong environment")
		}
		return []config.Binding{legacy}, nil
	}
	scope := PreparePayload{EnvironmentID: "https://app.test", WorkspaceID: "ws_" + strings.Repeat("d", 32), PersonaID: "persona", RuntimeKind: "hermes", ProfileCandidateID: profiles[0].CandidateID, DocumentID: uuid.NewString()}
	p := MigrationHelpPayload{PreparePayload: scope, RevocationReadback: MigrationAbsenceReadback{EnvironmentID: scope.EnvironmentID, WorkspaceID: scope.WorkspaceID, PersonaID: scope.PersonaID}}
	raw, _ := json.Marshal(p)
	denied := request(t, c, "migration_help", string(raw))
	if denied.Error == nil || denied.Error.Code != "scope_changed" {
		t.Fatal("missing native absence accepted")
	}
	gate := prepare(t, c, profiles[0], scope.PersonaID, scope.WorkspaceID, scope.DocumentID)
	if gate.Error == nil || gate.Error.Code != "migration_required" || len(c.preparations) != 0 {
		t.Fatal("fresh enrollment allowed over uncaptured legacy entry")
	}
	p.RevocationReadback.BindingAbsent = true
	raw, _ = json.Marshal(p)
	result := request(t, c, "migration_help", string(raw))
	if result.Error != nil || result.Result.ProfileConfigPath != path || result.Result.LegacyEntryKey != "old-issued" || result.Result.BackupDirectory != c.MigrationDirectory {
		t.Fatalf("wrong native-only guidance: %+v", result)
	}
	encoded, _ := json.Marshal(result)
	if strings.Contains(string(encoded), "never-return-this") || len(store.ListBindings()) != 0 {
		t.Fatal("secret exposure or mutation")
	}
	after, _ := os.ReadFile(path)
	if string(after) != original {
		t.Fatal("help mutated native configuration")
	}
	legacy.PersonaID = "foreign"
	foreign := request(t, c, "migration_help", string(raw))
	if foreign.Error == nil || foreign.Error.Code != "profile_in_use" {
		t.Fatal("foreign metadata scope accepted")
	}
	legacy.PersonaID = "persona"
	if err := os.WriteFile(path, []byte("mcp_servers: {}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	reset := prepare(t, c, profiles[0], scope.PersonaID, scope.WorkspaceID, scope.DocumentID)
	if reset.Error != nil || reset.Result.PreparationID == "" {
		t.Fatalf("manual reset did not clear prepare gate: %+v", reset)
	}
}

func TestDesktopAgentBridgeInterruptedPreparationRetryFencesOldDocument(t *testing.T) {
	t.Parallel()
	c, _, profiles := fixture(t)
	workspace := "ws_" + strings.Repeat("f", 32)
	oldDoc, newDoc := uuid.NewString(), uuid.NewString()
	first := prepare(t, c, profiles[0], "persona", workspace, oldDoc)
	if first.Error != nil {
		t.Fatal(first.Error)
	}
	retry := prepare(t, c, profiles[0], "persona", workspace, newDoc)
	if retry.Error != nil || retry.Result.PreparationID == first.Result.PreparationID {
		t.Fatal("interrupted setup did not get fresh proof")
	}
	old, _ := json.Marshal(EnrollPayload{PreparationID: first.Result.PreparationID, Code: "code", DocumentID: oldDoc})
	denied := request(t, c, "enroll", string(old))
	if denied.Error == nil || denied.Error.Code != "scope_changed" {
		t.Fatal("old document proof remained usable")
	}
	foreign := prepare(t, c, profiles[0], "other", workspace, uuid.NewString())
	if foreign.Error == nil || foreign.Error.Code != "profile_in_use" {
		t.Fatal("foreign interrupted setup reused reservation")
	}
}

func TestDesktopAgentBridgeNativeStatusAndRepairExposeReconnectRequired(t *testing.T) {
	t.Parallel()
	for _, fault := range []string{"missing", "rejected", "gateway_auth", "keychain_denied"} {
		t.Run(fault, func(t *testing.T) {
			t.Parallel()
			c, store, _ := fixture(t)
			b := config.Binding{EnvironmentID: "https://app.test", PersonaID: "persona", ConnectionID: "connection", ConnectionGeneration: 2, PersonaMCPToken: "present", ReadinessState: runtime.AdapterStateAuthMissing}
			if fault == "missing" {
				b.PersonaMCPToken = ""
			}
			if fault == "rejected" {
				b.ReadinessDiagnosticCode = "mcp_token_rejected"
			}
			if fault == "keychain_denied" {
				b.PersonaMCPToken = ""
				b.HasPersonaMCPToken = true
				b.PersonaMCPSecretUnavailable = true
			}
			if err := store.SaveBinding(b); err != nil {
				t.Fatal(err)
			}
			checks, repairs := 0, 0
			c.Check = func(context.Context, config.Binding) (runtime.Detection, error) {
				checks++
				return runtime.Detection{State: runtime.AdapterStateAuthMissing, DiagnosticCode: "credential_unavailable"}, nil
			}
			c.Repair = func(context.Context, config.Binding, bool) error { repairs++; return nil }
			key := b.Key()
			payload, _ := json.Marshal(BindingPayload{BindingKey: &key})
			for _, operation := range []string{"status", "check"} {
				result := request(t, c, operation, string(payload))
				if result.Error != nil || len(result.Result.Connections) != 1 {
					t.Fatal("missing native connection")
				}
				row := result.Result.Connections[0]
				if fault != "gateway_auth" && fault != "keychain_denied" && row.DiagnosticCode != "reconnect_required" {
					t.Fatal("persona MCP fault lost reconnect instruction")
				}
				if fault == "gateway_auth" && row.DiagnosticCode == "reconnect_required" {
					t.Fatal("runtime credential fault conflated with persona MCP")
				}
			}
			repair, _ := json.Marshal(RepairPayload{BindingKey: key, RestartConfirmed: true})
			result := request(t, c, "repair", string(repair))
			if fault == "keychain_denied" {
				if result.Error == nil || result.Error.Code != "credential_unavailable" || checks != 0 || repairs != 0 {
					t.Fatal("Keychain denial was repaired or mistaken for credential replacement")
				}
			} else if fault != "gateway_auth" {
				if result.Error == nil || result.Error.Code != "reconnect_required" || checks != 0 || repairs != 0 {
					t.Fatal("custody fault performed repair/check mutation")
				}
			} else if result.Error != nil || checks != 1 || repairs != 1 {
				t.Fatal("runtime repair incorrectly blocked by MCP custody")
			}
		})
	}
}

func TestDesktopAgentBridgeRepairReportsAdmissionAndSelectionConflict(t *testing.T) {
	t.Parallel()
	for _, code := range []string{"busy", "scope_changed"} {
		t.Run(code, func(t *testing.T) {
			t.Parallel()
			c, store, _ := fixture(t)
			b := config.Binding{EnvironmentID: "https://app.test", ConnectionID: "connection", PersonaMCPToken: "token"}
			if err := store.SaveBinding(b); err != nil {
				t.Fatal(err)
			}
			calls := 0
			c.Repair = func(context.Context, config.Binding, bool) error {
				calls++
				return fmt.Errorf("%s: current state changed", code)
			}
			raw, _ := json.Marshal(RepairPayload{BindingKey: b.Key(), RestartConfirmed: true})
			result := request(t, c, "repair", string(raw))
			if result.Error == nil || result.Error.Code != code || calls != 1 {
				t.Fatalf("Repair conflict mapped to unsafe cleanup: %+v", result)
			}
		})
	}
}
