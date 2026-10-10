package targetinventory

import (
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"os"
	"path/filepath"
	"testing"
)

func TestDesktopAgentBridgeProfileAliases(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	for _, p := range []string{".hermes", ".hermes/profiles/work", ".openclaw-team"} {
		if err := os.MkdirAll(filepath.Join(home, p), 0700); err != nil {
			t.Fatal(err)
		}
		name := "config.yaml"
		if p == ".openclaw-team" {
			name = "openclaw.json"
		}
		if err := os.WriteFile(filepath.Join(home, p, name), []byte("{}"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	profiles, warnings := DiscoverAt(home, "user", 501, 20, runtime.AdapterKindHermes, "seed")
	if len(profiles) != 2 || len(warnings) != 0 {
		t.Fatalf("Hermes %+v %v", profiles, warnings)
	}
	claw, _ := DiscoverAt(home, "user", 501, 20, runtime.AdapterKindOpenClaw, "seed")
	if len(claw) != 1 || SharedPhysicalTarget(profiles[0].Resolved, claw[0].Resolved) {
		t.Fatal("runtime profiles not isolated")
	}
	if err := os.Symlink(filepath.Join(home, ".hermes/profiles/work"), filepath.Join(home, ".hermes/profiles/alias")); err != nil {
		t.Fatal(err)
	}
	profiles, _ = DiscoverAt(home, "user", 501, 20, runtime.AdapterKindHermes, "seed")
	var alias, work ResolvedTarget
	for _, p := range profiles {
		if p.Label == "alias" {
			alias = p.Resolved
		}
		if p.Label == "work" {
			work = p.Resolved
		}
	}
	if !SharedPhysicalTarget(alias, work) || alias.PhysicalID != work.PhysicalID {
		t.Fatal("symlink alias treated independently")
	}
	other := filepath.Join(home, "hardlink")
	if err := os.Link(work.ConfigPath, other); err != nil {
		t.Fatal(err)
	}
	if !SharedPhysicalTarget(work, ResolvedTarget{StateRoot: "other", ConfigPath: other}) {
		t.Fatal("hardlink config bypass")
	}
}
