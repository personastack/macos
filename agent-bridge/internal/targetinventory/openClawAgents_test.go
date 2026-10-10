package targetinventory

import (
	"encoding/json"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeOpenClawAgentDiscoveryAndSelection(t *testing.T) {
	t.Parallel()
	for _, document := range []string{`{"agents":{"list":[{"id":"research","name":"Research"},{"id":"writer"}]}}`, `{"agents":{"entries":{"research":{"name":"Research"},"writer":{}}}}`} {
		home := t.TempDir()
		root := filepath.Join(home, ".openclaw-work")
		if err := os.Mkdir(root, 0700); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(root, "openclaw.json")
		if err := os.WriteFile(path, []byte(document), 0600); err != nil {
			t.Fatal(err)
		}
		profiles, warnings := DiscoverAt(home, "fixture", 501, 20, runtime.AdapterKindOpenClaw, "seed")
		if len(profiles) != 1 || len(warnings) != 0 || len(profiles[0].OpenClawAgents) != 2 {
			t.Fatalf("discovery %+v %v", profiles, warnings)
		}
		profile := profiles[0]
		if _, err := SelectOpenClawAgent(profile, ""); err == nil {
			t.Fatal("ambiguous profile silently selected main")
		}
		selected, err := SelectOpenClawAgent(profile, profile.OpenClawAgents[1].CandidateID)
		if err != nil || selected.Resolved.OpenClawAgentID != "writer" {
			t.Fatalf("selection %+v %v", selected, err)
		}
		target := &externalagentprotocol.RuntimeTarget{RuntimeKind: externalagentprotocol.RuntimeKindOpenClaw, AccountCandidateID: profile.AccountCandidateID, ProfileCandidateID: profile.CandidateID}
		resolved, err := ResolveProfiles(runtime.AdapterKindOpenClaw, target, profiles, "writer")
		if err != nil || resolved.OpenClawAgentID != "writer" {
			t.Fatal("persisted choice lost", err)
		}
		if _, err = ResolveProfiles(runtime.AdapterKindOpenClaw, target, profiles, "main"); err == nil {
			t.Fatal("missing main guessed")
		}
		if err = os.WriteFile(path, []byte(`{"agents":{"list":[{"id":"writer"}]}}`), 0600); err != nil {
			t.Fatal(err)
		}
		changed, _ := DiscoverAt(home, "fixture", 501, 20, runtime.AdapterKindOpenClaw, "seed")
		if changed[0].CandidateID != profile.CandidateID {
			t.Fatal("agent change split physical profile")
		}
		if _, err = SelectOpenClawAgent(changed[0], profile.OpenClawAgents[1].CandidateID); err == nil {
			t.Fatal("stale native choice accepted")
		}
	}
}
func TestNativeOpenClawNoAgentAndInvalidAgentRefuseSelection(t *testing.T) {
	t.Parallel()
	for _, document := range []string{`{"agents":{"list":[]}}`, `{"agents":{"entries":{}}}`, `{"agents":{"list":null}}`, `{"agents":{"list":[{"id":"../foreign"}]}}`, `{"agents":{"list":[{"id":"work"},{"id":"work"}]}}`, `{agents:{list:[{id:"research"}]}}`} {
		home := t.TempDir()
		root := filepath.Join(home, ".openclaw")
		_ = os.Mkdir(root, 0700)
		_ = os.WriteFile(filepath.Join(root, "openclaw.json"), []byte(document), 0600)
		profiles, _ := DiscoverAt(home, "fixture", 501, 20, runtime.AdapterKindOpenClaw, "seed")
		if len(profiles) > 0 {
			if _, err := SelectOpenClawAgent(profiles[0], ""); err == nil {
				t.Fatal("invalid agent auto-selected")
			}
		}
	}
}

func TestNativeOpenClawImplicitMainOnlyWithoutRoster(t *testing.T) {
	t.Parallel()
	for _, document := range []string{`{}`, `{"agents":{"defaults":{"workspace":"/fixture"}}}`} {
		home := t.TempDir()
		root := filepath.Join(home, ".openclaw")
		_ = os.Mkdir(root, 0700)
		_ = os.WriteFile(filepath.Join(root, "openclaw.json"), []byte(document), 0600)
		profiles, warnings := DiscoverAt(home, "fixture", 501, 20, runtime.AdapterKindOpenClaw, "seed")
		if len(profiles) != 1 || len(warnings) != 0 || len(profiles[0].OpenClawAgents) != 1 {
			t.Fatalf("implicit native default %+v %v", profiles, warnings)
		}
		chosen, err := SelectOpenClawAgent(profiles[0], profiles[0].OpenClawAgents[0].CandidateID)
		if err != nil || chosen.Resolved.OpenClawAgentID != "main" {
			t.Fatal("native default lost", err)
		}
	}
}

func TestNativeOpenClawAgentLabelsAndLimits(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	root := filepath.Join(home, ".openclaw")
	_ = os.Mkdir(root, 0700)
	path := filepath.Join(root, "openclaw.json")
	_ = os.WriteFile(path, []byte(`{"agents":{"entries":{"research":{"name":"Worker"},"writer":{"name":"Worker"}}}}`), 0600)
	profiles, warnings := DiscoverAt(home, "fixture", 501, 20, runtime.AdapterKindOpenClaw, "seed")
	if len(warnings) != 0 || profiles[0].OpenClawAgents[0].Label != "Worker (research)" || profiles[0].OpenClawAgents[1].Label != "Worker (writer)" {
		t.Fatal("duplicate labels not disambiguated")
	}
	longLabel, _ := json.Marshal(struct {
		Agents struct {
			List []openClawAgentEntry `json:"list"`
		} `json:"agents"`
	}{Agents: struct {
		List []openClawAgentEntry `json:"list"`
	}{List: []openClawAgentEntry{{ID: "research", Name: strings.Repeat("x", 257)}}}})
	_ = os.WriteFile(path, longLabel, 0600)
	profiles, warnings = DiscoverAt(home, "fixture", 501, 20, runtime.AdapterKindOpenClaw, "seed")
	if len(warnings) != 1 || profiles[0].ConflictCode != "native_config_unsupported" || len(profiles[0].OpenClawAgents) != 0 {
		t.Fatal("overlong native label was accepted")
	}
}
