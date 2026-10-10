package targetruntime

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDesktopAgentBridgeEndpointOwnership(t *testing.T) {
	t.Parallel()
	expected := EndpointEvidence{Listening: true, UID: 501, RuntimeKind: "hermes", StateRoot: "/profile/a", ConfigPath: "/profile/a/config.yaml"}
	ok, err := MatchEndpoint(expected, 501, "hermes", "/profile/a", "/profile/a/config.yaml")
	if !ok || err != nil {
		t.Fatal(err)
	}
	for _, e := range []EndpointEvidence{{Listening: true, UID: 502, RuntimeKind: "hermes", StateRoot: expected.StateRoot, ConfigPath: expected.ConfigPath}, {Listening: true, UID: 501, RuntimeKind: "hermes", StateRoot: "/profile/other", ConfigPath: expected.ConfigPath}} {
		if ok, err := MatchEndpoint(e, 501, "hermes", expected.StateRoot, expected.ConfigPath); ok || err == nil {
			t.Fatal("foreign listener accepted")
		}
	}
}
func TestDesktopAgentBridgeConfiguredProfileEndpoints(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".env"), []byte("API_SERVER_PORT=25001\nAPI_SERVER_HOST=127.0.0.1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := ProfileEndpoint("hermes", home, "")
	if err != nil || got != "http://127.0.0.1:25001" {
		t.Fatalf("Hermes endpoint %s %v", got, err)
	}
	path := filepath.Join(home, "openclaw.json")
	os.WriteFile(path, []byte(`{"gateway":{"port":25002}}`), 0600)
	got, err = ProfileEndpoint("openclaw", home, path)
	if err != nil || got != "ws://127.0.0.1:25002" {
		t.Fatalf("OpenClaw endpoint %s %v", got, err)
	}
}

func TestDesktopAgentBridgeProcessProfileAttribution(t *testing.T) {
	t.Parallel()
	root := "/Users/user/.hermes/profiles/work"
	config := root + "/config.yaml"
	exact := ProcessEvidence("501 /opt/bin/hermes gateway HERMES_HOME="+root, "hermes", root, config)
	if exact.StateRoot != root || exact.RuntimeKind != "hermes" {
		t.Fatal("exact profile rejected")
	}
	for _, line := range []string{"501 /opt/bin/hermes gateway HERMES_HOME=" + root + "-other", "501 /opt/bin/not-hermes gateway HERMES_HOME=" + root, "501 /opt/bin/hermes gateway XHERMES_HOME=" + root} {
		proof := ProcessEvidence(line, "hermes", root, config)
		proof.UID = 501
		if ok, _ := MatchEndpoint(proof, 501, "hermes", root, config); ok {
			t.Fatal("substring process proof admitted")
		}
	}
}
