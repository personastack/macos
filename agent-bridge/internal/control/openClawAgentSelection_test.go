package control

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/pairing"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
)

type nativeAgentFixtureSecrets struct{}

func (nativeAgentFixtureSecrets) Get(string) (string, error) { return "", nil }
func (nativeAgentFixtureSecrets) Set(string, string) error   { return nil }
func (nativeAgentFixtureSecrets) Delete(string) error        { return nil }

func TestNativeOpenClawActualProfileChoiceEnrollmentAndResolution(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	root := filepath.Join(home, ".openclaw-work")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "openclaw.json")
	document := `{"agents":{"list":[{"id":"research","name":"Research"},{"id":"writer"}]}}`
	if err := os.WriteFile(path, []byte(document), 0600); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(t.TempDir(), "private", "state.json")
	disk := config.NewFileStoreWithSecrets(statePath, nativeAgentFixtureSecrets{}).WithInventorySeed("seed")
	c := &Controller{Store: disk, Seed: "seed", Environments: func() ([]Environment, error) {
		return []Environment{{EnvironmentID: "https://app.test", GatewayBaseURL: "https://gateway.test"}}, nil
	}, Discover: func(kind runtime.AdapterKind, seed string) ([]targetinventory.Profile, []error) {
		return targetinventory.DiscoverAt(home, "fixture", 501, 20, kind, seed)
	}}
	calls := 0
	c.Exchange = func(_ context.Context, _ Environment, p pairing.Request) (pairing.Result, error) {
		calls++
		return pairing.Result{Binding: config.Binding{ConnectionID: "eac_connection", PersonaID: "persona", RuntimeKind: p.RuntimeKind, ConnectionGeneration: 1}}, nil
	}
	discovered := request(t, c, "discover", `{"environment_id":"https://app.test","runtime_kind":"openclaw"}`)
	if discovered.Error != nil || len(discovered.Result.Profiles) != 1 || len(discovered.Result.Profiles[0].OpenClawAgents) != 2 {
		t.Fatalf("discovery %+v", discovered)
	}
	profile := discovered.Result.Profiles[0]
	scope := PreparePayload{EnvironmentID: "https://app.test", WorkspaceID: "ws_" + strings.Repeat("a", 32), PersonaID: "persona", RuntimeKind: "openclaw", ProfileCandidateID: profile.ProfileCandidateID, DocumentID: uuid.NewString()}
	marshal := func(v any) string {
		raw, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}
	denied := request(t, c, "prepare", marshal(scope))
	if denied.Error == nil || len(c.preparations) != 0 {
		t.Fatal("ambiguous profile prepared without native choice")
	}
	scope.OpenClawAgentCandidateID = profile.OpenClawAgents[1].AgentCandidateID
	prepared := request(t, c, "prepare", marshal(scope))
	if prepared.Error != nil {
		t.Fatal(prepared.Error)
	}
	enrollment := EnrollPayload{PreparationID: prepared.Result.PreparationID, DocumentID: scope.DocumentID, Code: "one-use-fixture"}
	changed := enrollment
	changed.DocumentID = uuid.NewString()
	denied = request(t, c, "enroll", marshal(changed))
	if denied.Error == nil || calls != 0 || len(disk.ListBindings()) != 0 {
		t.Fatal("changed document caused pairing or persistence")
	}
	changedConfig := `{"agents":{"list":[{"id":"research"}]}}`
	if err := os.WriteFile(path, []byte(changedConfig), 0600); err != nil {
		t.Fatal(err)
	}
	denied = request(t, c, "enroll", marshal(enrollment))
	if denied.Error == nil || calls != 0 || len(disk.ListBindings()) != 0 {
		t.Fatal("changed profile caused pairing or persistence")
	}
	if raw, _ := os.ReadFile(path); string(raw) != changedConfig {
		t.Fatal("denial mutated changed native config")
	}
	if err := os.WriteFile(path, []byte(document), 0600); err != nil {
		t.Fatal(err)
	}
	enrolled := request(t, c, "enroll", marshal(enrollment))
	if enrolled.Error != nil {
		t.Fatal(enrolled.Error)
	}
	reloaded := config.NewFileStoreWithSecrets(statePath, nativeAgentFixtureSecrets{})
	bindings := reloaded.ListBindings()
	if len(bindings) != 1 || bindings[0].SelectedOpenClawAgentID != "writer" {
		t.Fatalf("native choice lost %+v", bindings)
	}
	status := request(t, c, "status", `{"binding_key":{"environment_id":"https://app.test","connection_id":"eac_connection"}}`)
	if status.Error != nil || len(status.Result.Connections) != 1 {
		t.Fatal("native retained status missing")
	}
	retained := status.Result.Connections[0]
	if retained.ConnectionGeneration != 1 || retained.PreparedTarget == nil || retained.PreparedTarget.WorkspaceID != scope.WorkspaceID || retained.PreparedTarget.AccountCandidateID != bindings[0].AccountCandidateID || retained.PreparedTarget.ProfileCandidateID != bindings[0].ProfileCandidateID || retained.PreparedTarget.RuntimeKind != "openclaw" {
		t.Fatalf("retained scope changed %+v", retained)
	}
	nativeProfiles, _ := targetinventory.DiscoverAt(home, "fixture", 501, 20, runtime.AdapterKindOpenClaw, "seed")
	target := &externalagentprotocol.RuntimeTarget{RuntimeKind: externalagentprotocol.RuntimeKindOpenClaw, AccountCandidateID: bindings[0].AccountCandidateID, ProfileCandidateID: bindings[0].ProfileCandidateID}
	resolved, err := targetinventory.ResolveProfiles(runtime.AdapterKindOpenClaw, target, nativeProfiles, bindings[0].SelectedOpenClawAgentID)
	if err != nil || resolved.OpenClawAgentID != "writer" {
		t.Fatalf("dispatch resolution %s %v", resolved.OpenClawAgentID, err)
	}
	foreign := scope
	foreign.PersonaID = "other"
	foreign.OpenClawAgentCandidateID = profile.OpenClawAgents[0].AgentCandidateID
	denied = request(t, c, "prepare", marshal(foreign))
	if denied.Error == nil || calls != 1 || len(disk.ListBindings()) != 1 {
		t.Fatal("agents split one physical profile into two persona owners")
	}
	raw, _ := os.ReadFile(path)
	if string(raw) != document {
		t.Fatal("native discovery/enrollment changed runtime config before selected API target")
	}
}

func TestNativeRetainedTargetStatusIsScopedRedactedAndReadOnly(t *testing.T) {
	t.Parallel()
	c, store, _ := fixture(t)
	owner := config.Binding{EnvironmentID: "https://app.test", ConnectionID: "eac_owner", ConnectionGeneration: 7, PersonaID: "persona", WorkspaceID: "ws_" + strings.Repeat("a", 32), RuntimeKind: runtime.AdapterKindOpenClaw, AccountCandidateID: "rt_account_a", ProfileCandidateID: "rt_profile_a", SelectedOpenClawAgentID: "research", NativeStateRoot: "/private/owner", NativeConfigPath: "/private/owner/config", PersonaMCPToken: "private-mcp-secret", BridgePrivateKey: "private-bridge-secret"}
	sibling := owner
	sibling.ConnectionID = "eac_sibling"
	sibling.PersonaID = "other"
	sibling.NativeStateRoot = "/private/sibling"
	sibling.NativeConfigPath = "/private/sibling/config"
	sibling.ProfileCandidateID = "rt_profile_b"
	if err := store.SaveBinding(owner); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveBinding(sibling); err != nil {
		t.Fatal(err)
	}
	response := request(t, c, "status", `{"binding_key":{"environment_id":"https://app.test","connection_id":"eac_owner"}}`)
	if response.Error != nil || len(response.Result.Connections) != 1 {
		t.Fatal("scoped status failed")
	}
	row := response.Result.Connections[0]
	if row.ConnectionGeneration != 7 || row.PreparedTarget == nil || row.PreparedTarget.WorkspaceID != owner.WorkspaceID || row.PreparedTarget.AccountCandidateID != "rt_account_a" || row.PreparedTarget.ProfileCandidateID != "rt_profile_a" || row.PreparedTarget.RuntimeKind != "openclaw" {
		t.Fatalf("private target changed %+v", row)
	}
	raw, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"/private/owner", "/private/sibling", "private-mcp-secret", "private-bridge-secret", "SelectedOpenClawAgentID"} {
		if strings.Contains(string(raw), secret) {
			t.Fatal("private path or credential leaked into retry DTO")
		}
	}
	if !strings.Contains(string(raw), `"prepared_target":{"workspace_id":"`+owner.WorkspaceID+`","account_candidate_id":"rt_account_a","profile_candidate_id":"rt_profile_a","runtime_kind":"openclaw"}`) {
		t.Fatal("private producer field names changed")
	}
	actual, _ := store.BindingKey(sibling.Key())
	if actual != sibling {
		t.Fatal("scoped status mutated sibling")
	}
	actual, _ = store.BindingKey(owner.Key())
	if actual != owner {
		t.Fatal("scoped status mutated owner")
	}
}
