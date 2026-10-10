package targetruntime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDesktopAgentBridgeAbsentPortChecksOtherNativeListeners(t *testing.T) {
	t.Parallel()
	for _, change := range []string{"same profile port override", "unknown profile", "distinct sibling", "symlink alias", "hardlink alias", "unrelated process", "wrong UID", "duplicate PID", "malformed"} {
		t.Run(change, func(t *testing.T) {
			t.Parallel()
			root, other := t.TempDir(), t.TempDir()
			configPath := filepath.Join(root, "openclaw.json")
			otherConfig := filepath.Join(other, "openclaw.json")
			for _, path := range []string{configPath, otherConfig} {
				if err := os.WriteFile(path, []byte(`{}`), 0600); err != nil {
					t.Fatal(err)
				}
			}
			calls, envCalls := 0, 0
			run := func(_ context.Context, binary string, args ...string) ([]byte, error) {
				calls++
				if calls == 1 {
					want := []string{"-nP", "-u", "501", "-a", "-iTCP", "-sTCP:LISTEN", "-Fp"}
					if binary != "/usr/sbin/lsof" || !reflect.DeepEqual(args, want) {
						t.Fatal("scan omitted UID/all-port LISTEN fence")
					}
					raw := "p812\nf21\n"
					if change == "duplicate PID" {
						raw += "p812\nf22\n"
					}
					if change == "malformed" {
						raw = "punknown\nf21\n"
					}
					return []byte(raw), nil
				}
				if calls != 2 || binary != "/bin/ps" || !reflect.DeepEqual(args, []string{"-p", "812", "-o", "uid=,command="}) {
					t.Fatal("unplanned process read")
				}
				if change == "unrelated process" {
					return []byte("501 /usr/bin/node unrelated-listener"), nil
				}
				if change == "wrong UID" {
					return []byte("502 openclaw-gateway"), nil
				}
				return []byte("501 openclaw-gateway"), nil
			}
			environment := func(pid int) (string, string, error) {
				envCalls++
				if pid != 812 {
					t.Fatal("native environment crossed PID")
				}
				switch change {
				case "unknown profile":
					return "", "", nil
				case "distinct sibling":
					return other, otherConfig, nil
				case "symlink alias":
					alias := filepath.Join(other, "alias")
					if err := os.Symlink(root, alias); err != nil {
						t.Fatal(err)
					}
					return alias, filepath.Join(alias, "openclaw.json"), nil
				case "hardlink alias":
					alias := filepath.Join(other, "shared.json")
					if err := os.Link(configPath, alias); err != nil {
						t.Fatal(err)
					}
					return other, alias, nil
				default:
					return root, configPath, nil
				}
			}
			err := verifyNoOtherOpenClawListener(context.Background(), root, configPath, 501, run, environment)
			allowed := change == "distinct sibling" || change == "unrelated process"
			if (err == nil) != allowed {
				t.Fatalf("other-port profile scope: %s %v", change, err)
			}
			if (change == "wrong UID" || change == "unrelated process" || change == "malformed") && envCalls != 0 {
				t.Fatal("protected kernel read before UID/runtime proof")
			}
			if change == "duplicate PID" && (calls != 2 || envCalls != 1) {
				t.Fatal("duplicate PID was not deduplicated")
			}
		})
	}
}

func TestDesktopAgentBridgeListenerScanBounds(t *testing.T) {
	t.Parallel()
	for _, count := range []int{0, 128, 129} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			t.Parallel()
			raw := ""
			for n := 1; n <= count; n++ {
				raw += fmt.Sprintf("p%d\nf21\n", n)
			}
			pids, err := listenerProcessIDs([]byte(raw))
			if count <= 128 {
				if err != nil || len(pids) != count {
					t.Fatal("bounded scan refused")
				}
			} else if err == nil {
				t.Fatal("unbounded process scan admitted")
			}
		})
	}
	output := &boundedProcessOutput{}
	if _, err := output.Write(make([]byte, 64*1024+1)); err == nil || len(output.raw) != 0 {
		t.Fatal("oversized process output retained")
	}
}
