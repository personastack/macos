package daemon

import (
	"context"
	"os"
	"testing"

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
	"github.com/personastack/macos/agent-bridge/internal/targetruntime"
)

func TestDesktopAgentBridgeAppsRepairActualBindAndScopeFence(t *testing.T) {
	t.Parallel()
	for _, change := range []string{"lan override", "wildcard override", "mixed listener", "port override", "generation changed", "target changed", "run admitted"} {
		t.Run(change, func(t *testing.T) {
			t.Parallel()
			b, store, runner := freshSelectedFixture(t)
			b.RuntimeKind = runtime.AdapterKindOpenClaw
			b.OpenClawAgentID = "writer"
			b.TargetSelectionRevision = 3
			raw := []byte(`{"gateway":{"bind":"loopback","port":25907,"auth":{"mode":"token","token":"local-fixture"}},"agents":{"entries":[{"id":"writer"}]},"user_key":"keep"}`)
			if err := os.WriteFile(b.NativeConfigPath, raw, 0600); err != nil {
				t.Fatal(err)
			}
			if err := store.SaveBinding(b); err != nil {
				t.Fatal(err)
			}
			runner.ResolveTarget = func(config.Binding, *externalagentprotocol.RuntimeTarget) (targetinventory.ResolvedTarget, error) {
				return targetinventory.ResolvedTarget{StateRoot: b.NativeStateRoot, ConfigPath: b.NativeConfigPath, OpenClawAgentID: "writer", UID: os.Geteuid()}, nil
			}
			probes := 0
			runner.VerifyRuntimeEndpoint = func(_ context.Context, endpoint, root, path, kind string) (bool, error) {
				probes++
				if endpoint != "ws://127.0.0.1:25907" || root != b.NativeStateRoot || path != b.NativeConfigPath || kind != "openclaw" {
					t.Fatal("ownership probe selected another target")
				}
				// Exact current-user/profile evidence cannot override the actual socket.
				proof := targetruntime.ProcessEvidence("501 /opt/bin/openclaw gateway run --bind lan OPENCLAW_STATE_DIR="+root+" OPENCLAW_CONFIG_PATH="+path, kind, root, path)
				proof.UID = os.Geteuid()
				if ok, err := targetruntime.MatchEndpoint(proof, os.Geteuid(), kind, root, path); !ok || err != nil {
					t.Fatal("fixture profile must match")
				}
				listener := "p812\nf21\nn127.0.0.1:25907\n"
				switch change {
				case "lan override":
					listener = "p812\nf21\nn192.168.0.54:25907\n"
				case "wildcard override":
					listener = "p812\nf21\nn*:25907\n"
				case "mixed listener":
					listener += "f22\nn[::]:25907\n"
				case "port override":
					listener = "p812\nf21\nn192.168.0.54:25908\n"
				}
				if _, err := targetruntime.ListenerPID([]byte(listener), "25907"); err != nil {
					return false, err
				}
				if err := config.UpdateBinding(store, b, func(next *config.Binding) error {
					switch change {
					case "generation changed":
						next.ConnectionGeneration++
					case "target changed":
						next.TargetSelectionRevision++
					case "run admitted":
						next.ActiveRunID = "assigned"
					}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
				return true, nil
			}
			runner.OpenClawNativeCall = func(context.Context, runtime.OpenClawRequest) (runtime.OpenClawResponse, error) {
				t.Fatal("rejected ownership started native work")
				return runtime.OpenClawResponse{}, nil
			}
			if err := runner.RepairBinding(context.Background(), b, true, true); err == nil {
				t.Fatal("actual bind or changed admission accepted")
			}
			after, _ := os.ReadFile(b.NativeConfigPath)
			current, _ := config.BindingFor(store, b)
			if probes != 1 || string(after) != string(raw) || current.RuntimeLaunchAllowed || current.OpenClawSetupPending || current.MCPOwnership.EntryKey != "" {
				t.Fatal("rejected actual listener/scope changed Apps/MCP or launch admission")
			}
		})
	}
}
