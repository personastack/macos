package control

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
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
	payload, _ := json.Marshal(MigrationPreparePayload{PreparePayload: scope, ConnectionID: "old", ConnectionGeneration: 2})
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
