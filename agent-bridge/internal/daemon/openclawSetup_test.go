package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
)

func TestDesktopAgentBridgeOpenClawConsentedSetupAndReadOnlyCheck(t *testing.T) {
	t.Parallel()
	for _, change := range []string{"none", "quiesce", "run", "generation", "target", "apps disabled", "deleted"} {
		t.Run(change, func(t *testing.T) {
			t.Parallel()
			b, store, runner := freshSelectedFixture(t)
			b.RuntimeKind = runtime.AdapterKindOpenClaw
			b.OpenClawAgentID = "writer"
			b.TargetSelectionRevision = 3
			original := `{"user_key":"keep","gateway":{"port":25907,"auth":{"mode":"token","token":"local-fixture"}},"agents":{"entries":[{"id":"writer"}]}}`
			if err := os.WriteFile(b.NativeConfigPath, []byte(original), 0600); err != nil {
				t.Fatal(err)
			}
			if err := store.SaveBinding(b); err != nil {
				t.Fatal(err)
			}
			runner.ResolveTarget = func(reference config.Binding, target *externalagentprotocol.RuntimeTarget) (targetinventory.ResolvedTarget, error) {
				if reference.Key() != b.Key() || target.ProfileCandidateID != b.ProfileCandidateID {
					t.Fatal("unplanned target")
				}
				return targetinventory.ResolvedTarget{HomeDir: b.NativeStateRoot, StateRoot: b.NativeStateRoot, ConfigPath: b.NativeConfigPath, OpenClawAgentID: "writer", UID: os.Geteuid()}, nil
			}
			calls := 0
			runner.OpenClawNativeCall = func(context.Context, runtime.OpenClawRequest) (runtime.OpenClawResponse, error) {
				t.Fatal("native mutation before consent")
				return runtime.OpenClawResponse{}, nil
			}
			detection, err := runner.CheckBinding(context.Background(), b)
			if err != nil || detection.DiagnosticCode != "mcp_apps_disabled" {
				t.Fatalf("stopped profile omitted Apps diagnosis: %+v %v", detection, err)
			}
			if err := runner.RepairBinding(context.Background(), b, true, false); err == nil {
				t.Fatal("restart consent silently granted Apps")
			}
			unchanged, _ := os.ReadFile(b.NativeConfigPath)
			if string(unchanged) != original {
				t.Fatal("denied Apps consent mutated config")
			}
			// A newer selection cannot inherit the previously validated native receipt.
			stale := b
			stale.TargetSelectionRevision--
			if err := runner.RepairBinding(context.Background(), stale, true, true); err == nil {
				t.Fatal("stale native target consent was accepted")
			}
			stillUnchanged, _ := os.ReadFile(b.NativeConfigPath)
			if string(stillUnchanged) != original {
				t.Fatal("stale target receipt mutated profile")
			}
			if err := runner.RepairBinding(context.Background(), b, true, true); err != nil {
				t.Fatal(err)
			}
			current, _ := config.BindingFor(store, b)
			if !current.OpenClawSetupPending || !current.RuntimeLaunchAllowed || current.OpenClawReadinessSession.ID != "" {
				t.Fatal("explicit setup admission not retained")
			}
			preparedConfig, _ := os.ReadFile(b.NativeConfigPath)
			adapter, _, err := runner.targetAdapter(current, targetForBinding(current))
			if err != nil {
				t.Fatal(err)
			}
			selected := adapter.(runtime.OpenClawAdapter)
			key := selected.OwnedSessionKey("setup", "")
			methods := []string{"sessions.create", "mcp.app.discover", "sessions.describe", "tools.effective", "sessions.describe"}
			runner.OpenClawNativeCall = func(_ context.Context, req runtime.OpenClawRequest) (runtime.OpenClawResponse, error) {
				if calls >= len(methods) || req.Method != methods[calls] {
					t.Fatalf("unplanned native call %s at %d", req.Method, calls)
				}
				calls++
				ok := true
				res := runtime.OpenClawResponse{OK: &ok, Type: "res", ID: req.ID}
				raw, _ := json.Marshal(req.Params)
				switch req.Method {
				case "sessions.create":
					if string(raw) != fmt.Sprintf(`{"key":%q,"agentId":"writer","idempotencyKey":%q}`, key, key) {
						t.Fatal("empty session create lost profile authority or added turn")
					}
					res.Payload = json.RawMessage(fmt.Sprintf(`{"ok":true,"key":%q,"sessionId":"native-setup","entry":{"sessionId":"native-setup","lifecycleRevision":"rev1"},"runStarted":false}`, key))
				case "mcp.app.discover":
					res.Payload = json.RawMessage(`{"servers":[],"onboarding":[]}`)
				case "sessions.describe":
					res.Payload = json.RawMessage(fmt.Sprintf(`{"session":{"key":%q,"sessionId":"native-setup","agentId":"writer","lifecycleRevision":"rev1"}}`, key))
				case "tools.effective":
					res.Payload = json.RawMessage(`{"agentId":"writer","groups":[{"source":"mcp","tools":[{"source":"mcp","pluginId":"bundle-mcp","mcpServer":"issued","mcpToolName":"get_persona"}]}]}`)
					if change == "deleted" {
						if err := store.DeleteBindingKey(b.Key()); err != nil {
							t.Fatal(err)
						}
					} else if change == "apps disabled" {
						if err := os.WriteFile(b.NativeConfigPath, []byte(original), 0600); err != nil {
							t.Fatal(err)
						}
					} else if change != "none" {
						if err := config.UpdateBinding(store, b, func(next *config.Binding) error {
							switch change {
							case "quiesce":
								next.Quiesced = true
							case "run":
								next.ActiveRunID = "assigned"
							case "generation":
								next.ConnectionGeneration++
							case "target":
								next.TargetSelectionRevision++
							}
							return nil
						}); err != nil {
							t.Fatal(err)
						}
					}
				}
				return res, nil
			}
			selected.CallNative = runner.OpenClawNativeCall
			completed, err := runner.completeOpenClawSetup(context.Background(), current, selected)
			persisted, exists := config.BindingFor(store, b)
			if change != "none" {
				if err == nil || (exists && persisted.OpenClawReadinessSession.ID != "") {
					t.Fatal("changed scope persisted setup readiness")
				}
				return
			}
			if err != nil || calls != 5 || persisted.OpenClawSetupPending || completed.ReadinessSession.ID != "native-setup" {
				t.Fatalf("no-model setup failed: %v %+v", err, persisted)
			}
			// Ordinary Check may only detect and read retained metadata/effective tools.
			calls = 0
			methods = []string{"health", "status", "agents.list", "sessions.describe", "tools.effective", "sessions.describe"}
			setupCall := runner.OpenClawNativeCall
			runner.OpenClawNativeCall = func(ctx context.Context, req runtime.OpenClawRequest) (runtime.OpenClawResponse, error) {
				if req.Method == "health" || req.Method == "status" || req.Method == "agents.list" {
					if calls >= 3 || req.Method != methods[calls] {
						t.Fatal("unplanned detection")
					}
					calls++
					ok := true
					payload := json.RawMessage(`{}`)
					if req.Method == "agents.list" {
						payload = json.RawMessage(`{"agents":[{"id":"writer"}]}`)
					}
					return runtime.OpenClawResponse{OK: &ok, Type: "res", ID: req.ID, Payload: payload}, nil
				}
				return setupCall(ctx, req)
			}
			runner.VerifyRuntimeEndpoint = func(context.Context, string, string, string, string) (bool, error) { return true, nil }
			runner.MCPHTTPClient = acceptedMCPCredentialClient(t, nil)
			detection, err = runner.CheckBinding(context.Background(), persisted)
			if err != nil || detection.State != runtime.AdapterStateMCPVerified || calls != 6 {
				t.Fatalf("read-only retained check failed %+v %v calls%d", detection, err, calls)
			}
			after, _ := os.ReadFile(b.NativeConfigPath)
			if string(after) != string(preparedConfig) {
				t.Fatal("Check changed selected profile config")
			}
		})
	}
}
