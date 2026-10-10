package control

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/targetruntime"
)

func TestDesktopAgentBridgeRepairReceiptScopeFence(t *testing.T) {
	t.Parallel()
	for _, change := range []string{"missing generation", "missing revision", "generation", "revision", "accepted"} {
		t.Run(change, func(t *testing.T) {
			t.Parallel()
			c, store, _ := fixture(t)
			b := config.Binding{EnvironmentID: "https://app.test", ConnectionID: "connection", ConnectionGeneration: 7, TargetSelectionRevision: 9, PersonaMCPToken: "fixture"}
			if err := store.SaveBinding(b); err != nil {
				t.Fatal(err)
			}
			p := RepairPayload{BindingKey: b.Key(), ConnectionGeneration: 7, TargetSelectionRevision: 9, RestartConfirmed: true, OpenClawAppsConfirmed: true}
			switch change {
			case "missing generation":
				p.ConnectionGeneration = 0
			case "missing revision":
				p.TargetSelectionRevision = 0
			case "generation":
				p.ConnectionGeneration = 6
			case "revision":
				p.TargetSelectionRevision = 8
			}
			calls := 0
			c.Repair = func(_ context.Context, current config.Binding, restart, apps bool) error {
				calls++
				if current.ConnectionGeneration != 7 || current.TargetSelectionRevision != 9 || !restart || !apps {
					t.Fatal("native consent scope lost")
				}
				return nil
			}
			raw, _ := json.Marshal(p)
			result := request(t, c, "repair", string(raw))
			if change == "accepted" {
				if result.Error != nil || calls != 1 {
					t.Fatal("current native consent was denied")
				}
				return
			}
			if result.Error == nil || result.Error.Code != "scope_changed" || calls != 0 {
				t.Fatal("stale consent repaired successor binding/selection")
			}
		})
	}
}

func TestDesktopAgentBridgeRepairUnverifiedListenerScopeUsesNativeHelp(t *testing.T) {
	t.Parallel()
	c, store, _ := fixture(t)
	b := config.Binding{EnvironmentID: "https://app.test", ConnectionID: "connection", ConnectionGeneration: 7, TargetSelectionRevision: 9, PersonaMCPToken: "fixture"}
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	c.Repair = func(context.Context, config.Binding, bool, bool) error {
		return targetruntime.ErrProfileScopeUnverified
	}
	raw, _ := json.Marshal(RepairPayload{BindingKey: b.Key(), ConnectionGeneration: 7, TargetSelectionRevision: 9, RestartConfirmed: true, OpenClawAppsConfirmed: true})
	result := request(t, c, "repair", string(raw))
	if result.Error == nil || result.Error.Code != "runtime_conflict" || result.Error.Message != targetruntime.ProfileScopeUnverifiedMessage {
		t.Fatal("approved consent turned unverified listener into misleading consent prompt")
	}
}
