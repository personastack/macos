package hermessetup

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func hostFixture(t *testing.T, config, env string) Paths {
	t.Helper()
	root := t.TempDir()
	paths := ResolvePaths(root, root)
	if err := os.WriteFile(paths.ConfigPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.EnvPath, []byte(env), 0600); err != nil {
		t.Fatal(err)
	}
	return paths
}
func TestDesktopAgentBridgeHermesEffectiveHostConfig(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name, config, env, endpoint, key string
		denied                           bool
	}{
		{name: "yaml-custom-port-and-key", config: "platforms:\n  api_server:\n    host: 127.0.0.1\n    port: 8643\n    extra:\n      key: yaml-profile-key-123\n", endpoint: "http://127.0.0.1:8643", key: "yaml-profile-key-123"},
		{name: "extra-before-flat", config: "platforms:\n  api_server:\n    port: 8643\n    extra:\n      port: 8644\n", endpoint: "http://127.0.0.1:8644"},
		{name: "usable-env-after-yaml", config: "platforms:\n  api_server:\n    port: 8643\n", env: "API_SERVER_KEY=own-default-key-123\nAPI_SERVER_PORT=8645\nAPI_SERVER_HOST=::1\n", endpoint: "http://[::1]:8645", key: "own-default-key-123"},
		{name: "no-usable-env-key", config: "platforms:\n  api_server:\n    port: 8643\n", env: "API_SERVER_PORT=9999\n", endpoint: "http://127.0.0.1:8643"},
		{name: "gateway-shorthand", config: "gateway:\n  platforms:\n    api_server:\n      port: 8643\nplatforms:\n  api_server:\n    port: 8644\ngateway:\n  api_server:\n    port: 8645\n", denied: true}, // duplicate YAML key rejected
		{name: "native-merge-order", config: "gateway:\n  platforms:\n    api_server:\n      port: 8643\n      extra:\n        key: merged-host-key-123\n  api_server:\n    port: 8645\nplatforms:\n  api_server:\n    port: 8644\n", endpoint: "http://127.0.0.1:8645", key: "merged-host-key-123"},
		{name: "nonloopback", config: "platforms:\n  api_server:\n    host: 0.0.0.0\n", denied: true},
		{name: "malformed", config: "platforms:\n  api_server: []\n", denied: true},
		{name: "secret-reference", config: "platforms:\n  api_server:\n    extra:\n      key: '${secret:api-key}'\n", denied: true},
		{name: "native-invalid-env-port-safe-refusal", config: "platforms:\n  api_server:\n    port: 8643\n", env: "API_SERVER_KEY=profile-key-123456\nAPI_SERVER_PORT=oops\n", denied: true},
		{name: "root-platform-shorthand-safe-refusal", config: "api_server:\n  port: 8643\n", denied: true},
		{name: "external-secret-source-safe-refusal", config: "secrets:\n  bitwarden:\n    enabled: true\n", denied: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			paths := hostFixture(t, tc.config, tc.env)
			state, err := ReadAPIConfig(paths)
			if tc.denied {
				if err == nil {
					t.Fatal("unsupported native configuration accepted")
				}
				return
			}
			if err != nil || state.Endpoint != tc.endpoint || state.Key != tc.key {
				t.Fatalf("effective host config %+v %v", state, err)
			}
		})
	}
}
func TestDesktopAgentBridgeHermesHostSetupPreservesNativeKeys(t *testing.T) {
	t.Parallel()
	paths := hostFixture(t, "user_key: keep\nplatforms:\n  api_server:\n    enabled: false\n    port: 8643\n    extra:\n      key: existing-host-key-123\n      unrelated: keep\n", "OTHER_PROFILE_SETTING=keep\n")
	err := EnsureHostAPI(paths, "http://127.0.0.1:8643")
	if err != nil {
		t.Fatal(err)
	}
	state, err := ReadAPIConfig(paths)
	if err != nil || state.Key != "existing-host-key-123" || state.Endpoint != "http://127.0.0.1:8643" {
		t.Fatal("native key/bind replaced", err)
	}
	raw, _ := os.ReadFile(paths.ConfigPath)
	env, _ := os.ReadFile(paths.EnvPath)
	if !strings.Contains(string(raw), "user_key: keep") || !strings.Contains(string(raw), "unrelated: keep") || !strings.Contains(string(raw), "enabled: true") || !strings.Contains(string(env), "OTHER_PROFILE_SETTING=keep") {
		t.Fatal("unrelated native config changed")
	}
}
func TestDesktopAgentBridgeHermesNamedCredentialDoesNotEnableListener(t *testing.T) {
	t.Parallel()
	paths := hostFixture(t, "user_key: keep\n", "API_SERVER_PORT=8999\nOTHER=keep\n")
	before, _ := os.ReadFile(paths.ConfigPath)
	err := EnsureProfileAPIKey(paths, "writer")
	if err != nil {
		t.Fatal(err)
	}
	key, err := LoadProfileAPIKey(paths, "writer")
	if err != nil || len(key) < 16 {
		t.Fatal("profile key absent")
	}
	after, _ := os.ReadFile(paths.ConfigPath)
	env, _ := os.ReadFile(paths.EnvPath)
	if string(before) != string(after) || strings.Contains(string(env), "API_SERVER_ENABLED") || strings.Contains(string(env), "API_SERVER_HOST") || !strings.Contains(string(env), "API_SERVER_PORT=8999") {
		t.Fatal("named credential setup changed listener intent")
	}
}
func TestDesktopAgentBridgeHermesDefaultNativeLaunchIgnoresStickyProfile(t *testing.T) {
	t.Parallel()
	paths := hostFixture(t, "user_key: keep\n", "API_SERVER_KEY=host-key-123456789\nAPI_SERVER_PORT=8643\n")
	if err := os.WriteFile(filepath.Join(paths.HermesHome, "active_profile"), []byte("writer"), 0600); err != nil {
		t.Fatal(err)
	}
	identity := ProcessIdentity{HomeDir: paths.HomeDir, Username: "fixture", UID: os.Geteuid()}
	command, err := gatewayCommand(paths, identity, "/fixture/venv/bin/hermes")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(command.Args, []string{"/fixture/venv/bin/hermes", "--profile", "default", "gateway", "run"}) || command.Dir != paths.HermesHome {
		t.Fatal("unsupported native startup arguments")
	}
	env := processEnvFor(paths, identity, []string{"HERMES_HOME=/foreign", "HERMES_PROFILE=writer", "HERMES_PROFILE_NAME=writer", "API_SERVER_PORT=9999", "API_SERVER_KEY=foreign", "HOME=/foreign", "USER=foreign", "LOGNAME=foreign", "UNRELATED=keep"})
	joined := strings.Join(env, "\n")
	if strings.Contains(joined, "writer") || strings.Contains(joined, "foreign") || strings.Contains(joined, "API_SERVER_") || !strings.Contains(joined, "HERMES_HOME="+paths.HermesHome) || !strings.Contains(joined, "HOME="+paths.HomeDir) || !strings.Contains(joined, "USER=fixture") || !strings.Contains(joined, "UNRELATED=keep") {
		t.Fatal("native child retained foreign selectors or lost identity")
	}
}
func TestDesktopAgentBridgeHermesUnservedProfileDenied(t *testing.T) {
	t.Parallel()
	for _, parked := range []bool{false, true} {
		name := "standalone"
		if parked {
			name = "parked"
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			paths := hostFixture(t, "gateway:\n  standalone: true\n", "")
			if parked {
				os.WriteFile(filepath.Join(paths.HermesHome, "gateway.parked"), nil, 0600)
			}
			if SharedProfileEligible(paths, "writer") == nil {
				t.Fatal("unserved named profile accepted")
			}
			if SharedProfileEligible(paths, "default") != nil {
				t.Fatal("native default ignores park/standalone settings")
			}
		})
	}
}

func TestDesktopAgentBridgeHermesNativeRendezvousEnvironment(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, env, state, override, expected string
		denied                               bool
	}{
		{name: "user-default", expected: "/fixture/home/.local/state/hermes/gateway-locks"},
		{name: "dotenv-lock-overrides-shell", env: "HERMES_GATEWAY_LOCK_DIR=/fixture/profile-locks\n", override: "/fixture/shell-locks", expected: "/fixture/profile-locks"},
		{name: "dotenv-state-overrides-shell", env: "XDG_STATE_HOME=/fixture/profile-state\n", state: "/fixture/shell-state", expected: "/fixture/profile-state/hermes/gateway-locks"},
		{name: "relative-xdg-ignored", state: "relative", expected: "/fixture/home/.local/state/hermes/gateway-locks"},
		{name: "relative-lock-refused", env: "HERMES_GATEWAY_LOCK_DIR=relative\n", denied: true},
		{name: "interpolated-lock-refused", env: "HERMES_GATEWAY_LOCK_DIR=${HOME}/locks\n", denied: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			paths := hostFixture(t, "user_key: keep\n", tc.env)
			got, err := GatewayLockDirectory(paths, "/fixture/home", tc.state, tc.override)
			if tc.denied {
				if err == nil {
					t.Fatal("ambiguous native rendezvous accepted")
				}
				return
			}
			if err != nil || got != tc.expected {
				t.Fatalf("native lock location %q %v", got, err)
			}
		})
	}
}

func TestDesktopAgentBridgeHermesHostEnablePreservesIPv6Bind(t *testing.T) {
	t.Parallel()
	paths := hostFixture(t, "platforms:\n  api_server:\n    host: ::1\n    port: 8643\n    extra:\n      key: existing-host-key-123\n", "")
	if err := EnsureHostAPI(paths, "http://[::1]:8643"); err != nil {
		t.Fatal(err)
	}
	state, err := ReadAPIConfig(paths)
	if err != nil || state.Endpoint != "http://[::1]:8643" || state.Key != "existing-host-key-123" {
		t.Fatal("native IPv6 bind/key changed", err)
	}
	env, _ := os.ReadFile(paths.EnvPath)
	if !strings.Contains(string(env), "API_SERVER_HOST=::1\n") {
		t.Fatal("IPv6 native host replaced with IPv4")
	}
}

func TestDesktopAgentBridgeHermesManagedPolicyRefusesBeforeConfigWrites(t *testing.T) {
	t.Parallel()
	managed := t.TempDir()
	paths := hostFixture(t, "user_key: keep\n", "HERMES_MANAGED_DIR="+managed+"\n")
	before, _ := os.ReadFile(paths.ConfigPath)
	envBefore, _ := os.ReadFile(paths.EnvPath)
	if err := EnsureHostAPI(paths, "http://127.0.0.1:8642"); err == nil {
		t.Fatal("managed host policy replaced")
	}
	after, _ := os.ReadFile(paths.ConfigPath)
	envAfter, _ := os.ReadFile(paths.EnvPath)
	if string(before) != string(after) || string(envBefore) != string(envAfter) {
		t.Fatal("managed refusal mutated host config")
	}
	if err := supportedManagedDirectory(hostFixture(t, "user_key: keep\n", ""), managed); err == nil {
		t.Fatal("native inherited managed policy ignored")
	}
}

func TestDesktopAgentBridgeHermesNamedManagedPolicyRefusesCredentialCustody(t *testing.T) {
	t.Parallel()
	managed := t.TempDir()
	paths := hostFixture(t, "user_key: keep\n", "HERMES_MANAGED_DIR="+managed+"\n")
	before, _ := os.ReadFile(paths.EnvPath)
	if err := SharedProfileEligible(paths, "writer"); err == nil {
		t.Fatal("managed profile was discoverable")
	}
	if err := EnsureProfileAPIKey(paths, "writer"); err == nil {
		t.Fatal("managed credential authority overwritten")
	}
	if _, err := LoadProfileAPIKey(paths, "writer"); err == nil {
		t.Fatal("managed profile borrowed literal credential")
	}
	after, _ := os.ReadFile(paths.EnvPath)
	if string(before) != string(after) {
		t.Fatal("managed selected profile changed")
	}
}
