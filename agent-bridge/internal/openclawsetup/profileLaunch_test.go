package openclawsetup

import (
	"reflect"
	"testing"
)

func TestDesktopAgentBridgeProfileLaunchPinsActualLoopback(t *testing.T) {
	t.Parallel()
	for _, profile := range []string{"default", "work"} {
		t.Run(profile, func(t *testing.T) {
			t.Parallel()
			cmd := profileGatewayCommand("/opt/bin/openclaw", "/profile/work", "/profile/work/openclaw.json", profile, 25907, []string{"HOME=/user", "OPENCLAW_STATE_DIR=/foreign", "OPENCLAW_CONFIG_PATH=/foreign/config", "OPENCLAW_GATEWAY_BIND=lan"})
			want := []string{"/opt/bin/openclaw", "gateway", "run", "--port", "25907", "--bind", "loopback"}
			if profile != "default" {
				want = append([]string{"/opt/bin/openclaw", "--profile", profile}, want[1:]...)
			}
			if !reflect.DeepEqual(cmd.Args, want) || cmd.Dir != "/profile/work" || !reflect.DeepEqual(cmd.Env, []string{"HOME=/user", "OPENCLAW_STATE_DIR=/profile/work", "OPENCLAW_CONFIG_PATH=/profile/work/openclaw.json"}) {
				t.Fatal("scoped native launch inherited bind/profile override")
			}
		})
	}
}
