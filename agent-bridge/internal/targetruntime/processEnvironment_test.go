package targetruntime

import (
	"encoding/binary"
	"strings"
	"testing"
)

func processArgumentsFixture(arguments, environment []string) []byte {
	raw := make([]byte, 4)
	binary.LittleEndian.PutUint32(raw, uint32(len(arguments)))
	raw = append(raw, []byte("/opt/homebrew/bin/node\x00\x00")...)
	for _, argument := range arguments {
		raw = append(raw, []byte(argument)...)
		raw = append(raw, 0)
	}
	raw = append(raw, 0, 0) // padding retained after Node's title mutation
	for _, field := range environment {
		raw = append(raw, []byte(field)...)
		raw = append(raw, 0)
	}
	return append(raw, 0)
}

func TestOpenClawMacOSGatewayTitleRequiresExactProfileAndUID(t *testing.T) {
	t.Parallel()
	root := "/Users/user/.openclaw-work"
	config := root + "/openclaw.json"
	for _, tc := range []struct {
		name, title, state, config string
		uid                        int
		want                       bool
	}{
		{"title and kernel profile", "openclaw-gateway", root, config, 501, true},
		{"wrong UID", "openclaw-gateway", root, config, 502, false},
		{"wrong root", "openclaw-gateway", root + "-other", config, 501, false},
		{"wrong config", "openclaw-gateway", root, config + ".other", 501, false},
		{"missing root", "openclaw-gateway", "", config, 501, false},
		{"missing config", "openclaw-gateway", root, "", 501, false},
		{"wrong title", "not-openclaw-gateway", root, config, 501, false},
		{"title prefix", "openclaw-gateway-other", root, config, 501, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			// Exact macOS ps output after Node process.title no longer has argv/env.
			proof := ProcessEvidence("501 "+tc.title, "openclaw", root, config)
			proof.UID = tc.uid
			raw := processArgumentsFixture([]string{tc.title, "", ""}, []string{
				"PATH=/usr/bin:/bin", "OPENCLAW_STATE_DIR=" + tc.state, "OPENCLAW_CONFIG_PATH=" + tc.config,
			})
			var err error
			proof.StateRoot, proof.ConfigPath, err = profileEnvironment(raw)
			if err != nil {
				t.Fatal(err)
			}
			got, err := MatchEndpoint(proof, 501, "openclaw", root, config)
			if got != tc.want || (tc.want && err != nil) {
				t.Fatalf("attachment = %v, error = %v", got, err)
			}
		})
	}
	withoutProfile := ProcessEvidence("501 openclaw-gateway", "openclaw", root, config)
	withoutProfile.UID = 501
	if ok, err := MatchEndpoint(withoutProfile, 501, "openclaw", root, config); ok || err == nil {
		t.Fatal("title alone authorized attachment")
	}
	withoutListener := EndpointEvidence{UID: 501, RuntimeKind: "openclaw", StateRoot: root, ConfigPath: config}
	if ok, err := MatchEndpoint(withoutListener, 501, "openclaw", root, config); ok || err != nil {
		t.Fatal("profile without listener authorized attachment")
	}
}

func TestProcessEnvironmentIgnoresArgumentsAndRejectsAmbiguousBuffers(t *testing.T) {
	t.Parallel()
	root, config := "/profile/with space", "/profile/with space/openclaw.json"
	raw := processArgumentsFixture([]string{"openclaw-gateway", "OPENCLAW_STATE_DIR=/foreign", "OPENCLAW_CONFIG_PATH=/foreign"},
		[]string{"OPENCLAW_STATE_DIR=" + root, "OPENCLAW_CONFIG_PATH=" + config, "SECRET=ignored"})
	gotRoot, gotConfig, err := profileEnvironment(raw)
	if err != nil || gotRoot != root || gotConfig != config {
		t.Fatal("exact kernel environment was not selected")
	}
	unterminated := processArgumentsFixture([]string{"openclaw-gateway"}, nil)
	unterminated = append(unterminated[:len(unterminated)-3], []byte("OPENCLAW_STATE_DIR=/one")...)
	for _, tc := range []struct {
		name string
		raw  []byte
	}{
		{"short", []byte{1, 2, 3}},
		{"oversized", make([]byte, maxProcessArguments+1)},
		{"zero argc", []byte{0, 0, 0, 0, 0}},
		{"missing executable terminator", []byte{1, 0, 0, 0, 'n'}},
		{"duplicate root", processArgumentsFixture([]string{"openclaw-gateway"}, []string{"OPENCLAW_STATE_DIR=/one", "OPENCLAW_STATE_DIR=/two"})},
		{"duplicate config", processArgumentsFixture([]string{"openclaw-gateway"}, []string{"OPENCLAW_CONFIG_PATH=/one", "OPENCLAW_CONFIG_PATH=/two"})},
		{"unterminated environment", unterminated},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			root, config, err := profileEnvironment(tc.raw)
			if err == nil || root != "" || config != "" {
				t.Fatal("ambiguous kernel buffer admitted")
			}
			if strings.Contains(err.Error(), "/one") || strings.Contains(err.Error(), "/two") {
				t.Fatal("error exposed process values")
			}
		})
	}
}
