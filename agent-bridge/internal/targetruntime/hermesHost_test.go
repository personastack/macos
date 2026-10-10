package targetruntime

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestDesktopAgentBridgeHermesSharedHostIdentity(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"writer", "reader", "default", "wrong UID", "wrong PID", "foreign home", "named launcher", "wrong protocol", "wrong kind", "unserved", "wildcard", "different incarnation", "missing rendezvous", "malformed listener"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			root := "/Users/fixture/.hermes"
			profile := "writer"
			if scenario == "reader" || scenario == "default" {
				profile = scenario
			}
			identity := HermesHostIdentity{Protocol: 1, Kind: "hermes-gateway", PID: 812, StartTime: 12345678, Home: root, Profile: "default", ServedProfiles: []string{"default", "writer", "reader"}}
			record := HermesHostRecord{Role: "gateway", PID: 812, StartTime: 12345678, Protocol: 1, Home: root, Profiles: []string{"default", "writer", "reader"}}
			raw := "p812\nf21\nn127.0.0.1:8643\nf22\nn[::1]:8643\n"
			uid := "501"
			switch scenario {
			case "wrong UID":
				uid = "502"
			case "wrong PID":
				identity.PID = 999
			case "foreign home":
				record.Home = "/foreign"
			case "named launcher":
				identity.Profile = "writer"
			case "wrong protocol":
				identity.Protocol = 2
			case "wrong kind":
				identity.Kind = "serve"
			case "unserved":
				identity.ServedProfiles = []string{"default", "reader"}
			case "wildcard":
				raw = "p812\nf21\nn*:8643\n"
			case "different incarnation":
				record.StartTime++
			case "malformed listener":
				raw = "p812\nf21\n"
			}
			calls := 0
			run := func(_ context.Context, binary string, args ...string) ([]byte, error) {
				calls++
				if calls == 1 {
					if binary != "/usr/sbin/lsof" || !reflect.DeepEqual(args, []string{"-nP", "-iTCP:8643", "-sTCP:LISTEN", "-Fpn"}) {
						t.Fatal("unplanned listener proof")
					}
					return []byte(raw), nil
				}
				if calls != 2 || binary != "/bin/ps" || !reflect.DeepEqual(args, []string{"eww", "-p", "812", "-o", "uid=,command="}) {
					t.Fatal("unplanned owner read")
				}
				return []byte(uid + " /fixture/venv/bin/hermes --profile default gateway run"), nil
			}
			identifies := 0
			ok, err := verifyHermesHost(context.Background(), "http://127.0.0.1:8643/p/"+profile, root, 501, run, func(_ context.Context, home string) (HermesHostIdentity, bool, error) {
				identifies++
				if home != root {
					t.Fatal("foreign socket read")
				}
				return identity, true, nil
			}, func(home string) (HermesHostRecord, bool, error) {
				if home != root {
					t.Fatal("foreign record read")
				}
				return record, scenario != "missing rendezvous", nil
			})
			accepted := scenario == "writer" || scenario == "reader" || scenario == "default"
			if ok != accepted || (accepted && err != nil) || (!accepted && !errors.Is(err, ErrHermesHostConflict)) {
				t.Fatalf("host proof %t %v", ok, err)
			}
			if scenario == "foreign home" && (calls != 0 || identifies != 0) {
				t.Fatal("foreign rendezvous caused protected reads")
			}
			if accepted && calls != 2 {
				t.Fatal("missing native owner/listener proof")
			}
		})
	}
}
func TestDesktopAgentBridgeHermesAbsentAPIIsNotStoppedHost(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"stopped", "recorded host API disabled", "unrecorded named host", "module host", "foreign rendezvous"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			calls := 0
			root := "/Users/fixture/.hermes"
			run := func(_ context.Context, binary string, args ...string) ([]byte, error) {
				calls++
				if calls == 1 {
					if binary != "/usr/sbin/lsof" {
						t.Fatal("unplanned listener read")
					}
					return nil, nil
				}
				if calls != 2 || binary != "/bin/ps" || !reflect.DeepEqual(args, []string{"-u", "501", "-o", "uid=,pid=,command="}) {
					t.Fatal("unplanned host scan")
				}
				line := "501 123 /usr/bin/unrelated"
				if scenario == "unrecorded named host" {
					line = "501 812 /fixture/hermes --profile writer gateway run"
				}
				if scenario == "module host" {
					line = "501 812 /fixture/python -m gateway.run"
				}
				return []byte(line), nil
			}
			record := HermesHostRecord{Role: "gateway", PID: 812, StartTime: 12345678, Protocol: 1, Home: root}
			if scenario == "foreign rendezvous" {
				record.Home = "/foreign"
			}
			ok, err := verifyHermesHost(context.Background(), "http://127.0.0.1:8643/p/writer", root, 501, run, func(context.Context, string) (HermesHostIdentity, bool, error) {
				return HermesHostIdentity{}, false, nil
			}, func(string) (HermesHostRecord, bool, error) {
				return record, strings.Contains(scenario, "recorded host") || scenario == "foreign rendezvous", nil
			})
			if ok || (scenario == "stopped" && err != nil) || (scenario != "stopped" && !errors.Is(err, ErrHermesHostConflict)) {
				t.Fatalf("absent API host verdict %t %v", ok, err)
			}
			if scenario == "foreign rendezvous" && calls != 0 {
				t.Fatal("foreign native record admitted probing")
			}
		})
	}
}
