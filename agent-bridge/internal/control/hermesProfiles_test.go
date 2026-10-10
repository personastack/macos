package control

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/pairing"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
)

func TestDesktopAgentBridgeHermesProfilesEnrollWithoutInheritedHostPermission(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	for _, name := range []string{"default", "writer", "reader", "standalone"} {
		root := filepath.Join(home, ".hermes")
		if name != "default" {
			root = filepath.Join(root, "profiles", name)
		}
		if err := os.MkdirAll(root, 0700); err != nil {
			t.Fatal(err)
		}
		doc := "mcp_servers: {}\n"
		if name == "standalone" {
			doc += "gateway:\n  standalone: true\n"
		}
		if err := os.WriteFile(filepath.Join(root, "config.yaml"), []byte(doc), 0600); err != nil {
			t.Fatal(err)
		}
	}
	statePath := filepath.Join(t.TempDir(), "private", "state.json")
	store := config.NewFileStoreWithSecrets(statePath, nativeAgentFixtureSecrets{}).WithInventorySeed("seed")
	c := &Controller{Store: store, Seed: "seed", Environments: func() ([]Environment, error) {
		return []Environment{{EnvironmentID: "https://app.test", GatewayBaseURL: "https://gateway.test"}}, nil
	}, Discover: func(kind runtime.AdapterKind, seed string) ([]targetinventory.Profile, []error) {
		return targetinventory.DiscoverAt(home, "fixture", os.Geteuid(), os.Getegid(), kind, seed)
	}}
	calls := 0
	expectedPersona := ""
	c.Exchange = func(_ context.Context, env Environment, p pairing.Request) (pairing.Result, error) {
		calls++
		if env.EnvironmentID != "https://app.test" || p.RuntimeKind != runtime.AdapterKindHermes || p.DesktopPreparation == nil {
			t.Fatal("unplanned pairing scope")
		}
		return pairing.Result{Binding: config.Binding{EnvironmentID: env.EnvironmentID, PersonaID: config.PersonaID(expectedPersona), ConnectionID: config.ConnectionID("connection-" + expectedPersona), ConnectionGeneration: 1, RuntimeKind: p.RuntimeKind, RuntimeLaunchAllowed: true}}, nil
	}
	marshal := func(v any) string {
		raw, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}
	discovered := request(t, c, "discover", `{"environment_id":"https://app.test","runtime_kind":"hermes"}`)
	if discovered.Error != nil || len(discovered.Result.Profiles) != 4 {
		t.Fatalf("discovery %+v", discovered)
	}
	for _, profile := range discovered.Result.Profiles {
		if profile.Label == "Default" {
			continue
		}
		scope := PreparePayload{EnvironmentID: "https://app.test", WorkspaceID: "ws_" + strings.Repeat("a", 32), PersonaID: "persona-" + profile.Label, RuntimeKind: "hermes", ProfileCandidateID: profile.ProfileCandidateID, DocumentID: uuid.NewString()}
		before := calls
		prepared := request(t, c, "prepare", marshal(scope))
		if profile.Label == "standalone" {
			if prepared.Error == nil || calls != before {
				t.Fatal("unserved profile prepared or exchanged")
			}
			continue
		}
		if prepared.Error != nil {
			t.Fatal(prepared.Error)
		}
		expectedPersona = scope.PersonaID
		enrolled := request(t, c, "enroll", marshal(EnrollPayload{PreparationID: prepared.Result.PreparationID, DocumentID: scope.DocumentID, Code: "one-use-fixture"}))
		if enrolled.Error != nil {
			t.Fatal(enrolled.Error)
		}
		reloaded := config.NewFileStoreWithSecrets(statePath, nativeAgentFixtureSecrets{}).WithInventorySeed("seed")
		b, ok := reloaded.BindingKey(*enrolled.Result.BindingKey)
		expectedHome, err := filepath.EvalSymlinks(filepath.Join(home, ".hermes", "profiles", profile.Label))
		if err != nil {
			t.Fatal(err)
		}
		if !ok || b.NativeProfileName != profile.Label || b.RuntimeLaunchAllowed || b.TargetSelectionRevision != 0 || b.HermesHome != expectedHome {
			t.Fatalf("prepared profile or native permission crossed persisted owner %+v", b)
		}
		scope.PersonaID = "another-persona"
		scope.DocumentID = uuid.NewString()
		denied := request(t, c, "prepare", marshal(scope))
		if denied.Error == nil || denied.Error.Code != "profile_in_use" || calls != before+1 {
			t.Fatal("one physical profile enrolled for two personas")
		}
	}
	if calls != 2 || len(store.ListBindings()) != 2 {
		t.Fatal("shared host collapsed two distinct profile bindings")
	}
}
