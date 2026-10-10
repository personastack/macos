package openclawsetup

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/personastack/macos/agent-bridge/internal/hermessetup"
)

func TestDesktopAgentBridgeLaunchdEnvironmentResolvesSupportedInstallations(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name, binary, node string
		wrapper            bool
	}{
		{"apple-homebrew", "/opt/homebrew/bin/openclaw", "/opt/homebrew/bin/node", false},
		{"intel-homebrew", "/usr/local/bin/openclaw", "/usr/local/bin/node", false},
		{"home-npm", "/user/.npm-global/bin/openclaw", "/opt/homebrew/bin/node", false},
		{"home-git-wrapper", "/user/.local/bin/openclaw", "", true},
		{"local-prefix-wrapper", "/user/.openclaw/bin/openclaw", "", true},
		{"local-node-shim", "/user/.openclaw/bin/openclaw", "/user/.openclaw/tools/node/bin/node", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			environment := []string{"PATH=/usr/bin:/bin", "HOME=/foreign", "USER=foreign", "LOGNAME=foreign", "BASH_ENV=/foreign/init", "ENV=/foreign/init", "NODE_OPTIONS=--import=/foreign/code", "NODE_PATH=/foreign/modules", "OPENCLAW_GATEWAY_BIND=lan", "OPENCLAW_STATE_DIR=/foreign", "OPENCLAW_CONFIG_PATH=/foreign/config", "KEEP=yes"}
			probes := 0
			launch, err := resolveNativeLaunch(context.Background(), "/user", environment, func(path string) bool { return path == test.binary || test.node != "" && path == test.node }, func(path string) (bool, error) {
				if path != test.binary {
					t.Fatal("foreign executable inspection")
				}
				return !test.wrapper, nil
			}, func(ctx context.Context, path string) (string, error) {
				probes++
				if path != test.node {
					t.Fatal("wrong interpreter probe")
				}
				return "v24.21.0", nil
			})
			if err != nil || launch.binary != test.binary || launch.node != test.node || test.wrapper && probes != 0 || !test.wrapper && probes != 1 {
				t.Fatalf("launch resolution: %+v %v", launch, err)
			}
			for _, profile := range []string{"default", "work"} {
				cmd := profileGatewayCommand(launch, "/user", "/profile/work", "/profile/work/openclaw.json", profile, hermessetup.ProcessIdentity{Username: "selected"}, 25907, environment)
				want := []string{test.binary, "gateway", "run", "--port", "25907", "--bind", "loopback"}
				if profile != "default" {
					want = append([]string{test.binary, "--profile", profile}, want[1:]...)
				}
				if !reflect.DeepEqual(cmd.Args, want) || cmd.Path != test.binary || cmd.Dir != "/profile/work" {
					t.Fatal("native entrypoint/profile/port changed")
				}
				env := map[string]string{}
				for _, entry := range cmd.Env {
					key, value, _ := strings.Cut(entry, "=")
					env[key] = value
				}
				if env["HOME"] != "/user" || env["USER"] != "selected" || env["LOGNAME"] != "selected" || env["OPENCLAW_STATE_DIR"] != "/profile/work" || env["OPENCLAW_CONFIG_PATH"] != "/profile/work/openclaw.json" || env["KEEP"] != "yes" {
					t.Fatal("selected child identity/scope lost")
				}
				for _, key := range []string{"BASH_ENV", "ENV", "NODE_OPTIONS", "NODE_PATH", "OPENCLAW_GATEWAY_BIND"} {
					if _, exists := env[key]; exists {
						t.Fatal("inherited initialization override", key)
					}
				}
				if !test.wrapper && strings.Split(env["PATH"], ":")[0] != filepath.Dir(test.node) {
					t.Fatal("env-node shim would use wrong interpreter")
				}
				for _, directory := range []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/user/.openclaw/tools/node/bin"} {
					if !strings.Contains(":"+env["PATH"]+":", ":"+directory+":") {
						t.Fatal("minimal login PATH missing supported location", directory)
					}
				}
			}
		})
	}
}

func TestDesktopAgentBridgeNativeEntrypointProducerShapes(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name, content      string
		needsNode, allowed bool
	}{
		{"npm", "#!/usr/bin/env node\n// pinned openclaw.mjs\n", true, true},
		{"local-prefix", "#!/usr/bin/env bash\nset -euo pipefail\nexec \"/user/.openclaw/tools/node/bin/node\" \"/user/.openclaw/tools/node/lib/node_modules/openclaw/dist/entry.js\" \"$@\"\n", false, true},
		{"git", "#!/usr/bin/env bash\nset -euo pipefail\nexec /user/node/bin/node /user/openclaw/dist/entry.js \"$@\"\n", false, true},
		{"unknown", "#!/usr/bin/env python\n", false, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "openclaw")
			if err := os.WriteFile(path, []byte(test.content), 0700); err != nil {
				t.Fatal(err)
			}
			needsNode, err := nativeEntrypointNeedsNode(path)
			if (err == nil) != test.allowed || needsNode != test.needsNode {
				t.Fatal("producer entrypoint not preserved", needsNode, err)
			}
		})
	}
}

func TestDesktopAgentBridgeLaunchRefusesMissingOrUnsupportedNode(t *testing.T) {
	t.Parallel()
	for _, version := range []string{"", "v22.0.0", "v24.15.0", "v25.9.0", "v26.0.0", "invalid"} {
		t.Run(version, func(t *testing.T) {
			t.Parallel()
			_, err := resolveNativeLaunch(context.Background(), "/user", []string{"PATH=.:relative:/usr/bin:/bin"}, func(path string) bool {
				return path == "/opt/homebrew/bin/openclaw" || version != "" && path == "/opt/homebrew/bin/node"
			}, func(string) (bool, error) { return true, nil }, func(context.Context, string) (string, error) { return version, nil })
			if err == nil {
				t.Fatal("missing/unsupported interpreter admitted")
			}
		})
	}
	for _, version := range []string{"v24.16.0", "v24.21.0", "v26.1.0", "v27.0.0"} {
		if !supportedNodeVersion(version) {
			t.Fatal("producer-supported interpreter rejected", version)
		}
	}
	for _, directory := range launchDirectories("/user", []string{"PATH=.:relative:/usr/bin:/bin:/usr/bin"}) {
		if !filepath.IsAbs(directory) {
			t.Fatal("launch depends on relative working directory")
		}
	}
}

func TestDesktopAgentBridgeLaunchSkipsEarlierUnsupportedNode(t *testing.T) {
	t.Parallel()
	for _, early := range []string{"/user/.openclaw/tools/node/bin/node", "/opt/homebrew/bin/node"} {
		t.Run(early, func(t *testing.T) {
			t.Parallel()
			probed := []string{}
			launch, err := resolveNativeLaunch(context.Background(), "/user", []string{"PATH=/usr/bin:/bin"}, func(path string) bool {
				return path == "/opt/homebrew/bin/openclaw" || path == early || path == "/usr/local/bin/node"
			}, func(string) (bool, error) { return true, nil }, func(_ context.Context, path string) (string, error) {
				probed = append(probed, path)
				if path == early {
					return "v22.0.0", nil
				}
				if path == "/usr/local/bin/node" {
					return "v26.1.0", nil
				}
				t.Fatal("unexpected interpreter probe", path)
				return "", nil
			})
			if err != nil || launch.node != "/usr/local/bin/node" || strings.Split(launch.path, ":")[0] != "/usr/local/bin" || !reflect.DeepEqual(probed, []string{early, "/usr/local/bin/node"}) {
				t.Fatal("stale interpreter shadowed supported installed runtime", launch, probed, err)
			}
			command := profileGatewayCommand(launch, "/user", "/profile/work", "/profile/work/openclaw.json", "work", hermessetup.ProcessIdentity{Username: "selected"}, 25907, nil)
			if command.Path != "/opt/homebrew/bin/openclaw" {
				t.Fatal("interpreter fallback changed selected CLI")
			}
			found := false
			for _, entry := range command.Env {
				if entry == "PATH="+launch.path {
					found = true
				}
			}
			if !found {
				t.Fatal("supported interpreter PATH was not delivered to child")
			}
		})
	}
}
