package mcp

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

func TestDesktopAgentBridgeOpenClawAppsNativeConsentConfig(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name, raw        string
		consent, success bool
	}{
		{"default loopback", `{"user_key":"keep","gateway":{"port":25907}}`, true, true},
		{"explicit loopback", `{"user_key":"keep","gateway":{"bind":"loopback"},"mcp":{"apps":{"enabled":false,"sandboxPort":25099}}}`, true, true},
		{"already enabled", `{"user_key":"keep","mcp":{"apps":{"enabled":true,"sandboxPort":25099}}}`, false, true},
		{"denied consent", `{"user_key":"keep","mcp":{"apps":{"enabled":false}}}`, false, false},
		{"lan", `{"user_key":"keep","gateway":{"bind":"lan"}}`, true, false},
		{"custom", `{"user_key":"keep","gateway":{"bind":"custom","customBindHost":"127.0.0.1"}}`, true, false},
		{"auto", `{"user_key":"keep","gateway":{"bind":"auto"}}`, true, false},
		{"all host", `{"user_key":"keep","gateway":{"bind":"0.0.0.0"}}`, true, false},
		{"malformed apps", `{"user_key":"keep","mcp":{"apps":true}}`, true, false},
		{"malformed enabled", `{"user_key":"keep","mcp":{"apps":{"enabled":"false"}}}`, true, false},
		{"null mcp", `{"user_key":"keep","mcp":null}`, true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "openclaw.json")
			if err := os.WriteFile(path, []byte(test.raw), 0600); err != nil {
				t.Fatal(err)
			}
			b := config.Binding{RuntimeKind: runtime.AdapterKindOpenClaw, NativeConfigPath: path, NativeMCPServer: "issued", InventorySeed: "seed", PersonaMCPToken: "fixture-token", PersonaMCPURL: "https://mcp.example/v1/mcp"}
			_, err := ConfigureBinding(&b, false, test.consent)
			after, _ := os.ReadFile(path)
			if !test.success {
				if err == nil || string(after) != test.raw || b.MCPOwnership.EntryKey != "" {
					t.Fatal("denied Apps setup changed selected config/custody")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			enabled, err := OpenClawAppsEnabled(path)
			if err != nil || !enabled {
				t.Fatal("explicit Apps setup was not enabled")
			}
			var preserved struct {
				User string `json:"user_key"`
				MCP  struct {
					Apps struct {
						Port int `json:"sandboxPort"`
					} `json:"apps"`
				} `json:"mcp"`
			}
			if err = json.Unmarshal(after, &preserved); err != nil || preserved.User != "keep" {
				t.Fatal("unrelated config changed")
			}
			if test.name == "explicit loopback" || test.name == "already enabled" {
				if preserved.MCP.Apps.Port != 25099 {
					t.Fatal("user sandbox listener setting changed")
				}
			}
		})
	}
}
