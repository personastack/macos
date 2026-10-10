package mcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"gopkg.in/yaml.v3"
)

func TestDesktopAgentBridgeHermesConfiguredReadinessContract(t *testing.T) {
	t.Parallel()
	const core = `{"tools":[{"name":"my_persona_info"},{"name":"baseline_prompt"}]}`
	cases := []struct {
		name, policy, result, diagnostic string
		status, calls                    int
		ready                            bool
	}{
		{name: "standalone core catalog", result: core, calls: 3, ready: true},
		{name: "empty API list inherits MCP", policy: "platform_toolsets: {api_server: []}", result: core, calls: 3, ready: true},
		{name: "ordinary tools inherit MCP", policy: "platform_toolsets: {api_server: [terminal]}", result: core, calls: 3, ready: true},
		{name: "issued allowlist", policy: "platform_toolsets: {api_server: [issued]}", result: core, calls: 3, ready: true},
		{name: "string list", policy: `platform_toolsets: {api_server: "['issued']"}`, result: core, calls: 3, ready: true},
		{name: "other MCP allowlist", policy: "platform_toolsets: {api_server: [unrelated]}", diagnostic: "capability_missing"},
		{name: "no MCP", policy: "platform_toolsets: {api_server: [issued, no_mcp]}", diagnostic: "capability_missing"},
		{name: "global issued suppression", policy: "agent: {disabled_toolsets: [issued]}", diagnostic: "capability_missing"},
		{name: "global registered alias suppression", policy: "agent: {disabled_toolsets: [mcp-issued]}", diagnostic: "capability_missing"},
		{name: "other suppression preserved", policy: "agent: {disabled_toolsets: [memory]}", result: core, calls: 3, ready: true},
		{name: "malformed platform", policy: "platform_toolsets: []", diagnostic: "capability_missing"},
		{name: "malformed list", policy: "platform_toolsets: {api_server: terminal}", diagnostic: "capability_missing"},
		{name: "malformed item", policy: "platform_toolsets: {api_server: [123]}", diagnostic: "capability_missing"},
		{name: "malformed global suppression", policy: "agent: {disabled_toolsets: {issued: true}}", diagnostic: "capability_missing"},
		{name: "empty catalog", result: `{"tools":[]}`, calls: 3, diagnostic: "capability_missing"},
		{name: "identity missing", result: `{"tools":[{"name":"baseline_prompt"}]}`, calls: 3, diagnostic: "capability_missing"},
		{name: "baseline missing", result: `{"tools":[{"name":"my_persona_info"}]}`, calls: 3, diagnostic: "capability_missing"},
		{name: "different tools", result: `{"tools":[{"name":"get_persona"},{"name":"tell_persona"}]}`, calls: 3, diagnostic: "capability_missing"},
		{name: "malformed catalog", result: `{"tools":{}}`, calls: 3, diagnostic: "capability_missing"},
		{name: "null catalog", result: `{"tools":null}`, calls: 3, diagnostic: "capability_missing"},
		{name: "authorization denied", status: http.StatusForbidden, calls: 1, diagnostic: "mcp_token_rejected"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			b, _, path := installedFixture(t)
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			before = append(before, []byte(tc.policy+"\n")...)
			if err = os.WriteFile(path, before, 0600); err != nil {
				t.Fatal(err)
			}
			calls := 0
			client := &http.Client{Transport: verifyContractRoundTripper(func(req *http.Request) (*http.Response, error) {
				calls++
				if calls > tc.calls || req.Method != http.MethodPost || req.URL.String() != b.PersonaMCPURL || req.Header.Get("Authorization") != "Bearer secret" {
					t.Fatal("unplanned or unscoped MCP request")
				}
				var payload struct {
					JSONRPC string          `json:"jsonrpc"`
					Method  string          `json:"method"`
					ID      json.RawMessage `json:"id"`
					Params  json.RawMessage `json:"params"`
				}
				decoder := json.NewDecoder(req.Body)
				decoder.DisallowUnknownFields()
				if err := decoder.Decode(&payload); err != nil {
					t.Fatal(err)
				}
				if payload.Method != []string{"initialize", "notifications/initialized", "tools/list"}[calls-1] {
					t.Fatal("wrong handshake sequence")
				}
				status, response := http.StatusOK, `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"PersonaStack","version":"test"}}}`
				if calls == 1 {
					var p struct {
						ProtocolVersion string `json:"protocolVersion"`
					}
					if json.Unmarshal(payload.Params, &p) != nil || p.ProtocolVersion != "2025-11-25" {
						t.Fatal("wrong producer catalog protocol")
					}
				}
				if calls == 2 {
					status, response = http.StatusAccepted, ""
				}
				if calls == 3 {
					response = `{"jsonrpc":"2.0","id":2,"result":` + tc.result + `}`
				}
				if tc.status != 0 {
					status = tc.status
				}
				return &http.Response{StatusCode: status, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(response)), Request: req}, nil
			})}
			result := verifyBindingWithNative(context.Background(), "", b, client, "http://127.0.0.1:8642/p/default", func(context.Context, config.Binding, string) (bool, string) {
				t.Fatal("Hermes configured readiness invented a native loaded-catalog call")
				return false, ""
			})
			if (result.State == runtime.AdapterStateMCPVerified) != tc.ready || result.DiagnosticCode != tc.diagnostic || calls != tc.calls {
				t.Fatalf("readiness %+v calls%d", result, calls)
			}
			if tc.ready && !strings.Contains(result.Note, "native discovery requires wake acceptance") {
				t.Fatal("readiness claims loaded native tools")
			}
			after, err := os.ReadFile(path)
			if err != nil || string(after) != string(before) {
				t.Fatal("readiness changed native config")
			}
		})
	}
}

func TestDesktopAgentBridgeHermesReadinessRejectsUnownedConfiguration(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"missing", "changed"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			b, _, path := installedFixture(t)
			before, _ := os.ReadFile(path)
			if scenario == "missing" {
				before = []byte("mcp_servers: {}\n")
			} else {
				before = []byte(strings.ReplaceAll(string(before), "Bearer secret", "Bearer foreign"))
			}
			if err := os.WriteFile(path, before, 0600); err != nil {
				t.Fatal(err)
			}
			result := VerifyBindingWithLiveAt(context.Background(), "", b, &http.Client{Transport: verifyContractRoundTripper(func(*http.Request) (*http.Response, error) {
				t.Fatal("unowned config performed protected MCP read")
				return nil, nil
			})}, "http://127.0.0.1:8642")
			if result.State != runtime.AdapterStateMCPConfigMissing {
				t.Fatalf("unowned config admitted %+v", result)
			}
			after, _ := os.ReadFile(path)
			if string(after) != string(before) {
				t.Fatal("Check repaired user configuration")
			}
		})
	}
}

func TestDesktopAgentBridgeHermesConfiguredServerEnablementMatchesProducer(t *testing.T) {
	t.Parallel()
	for _, value := range []string{"false", "False", "0", "0.0", "0x0", "' OFF '", "null", "''", "invalid", "[]"} {
		t.Run(value, func(t *testing.T) {
			t.Parallel()
			b, _, path := installedFixture(t)
			doc, err := readConfig(path)
			if err != nil {
				t.Fatal(err)
			}
			entries, _ := nativeEntries(doc, b.RuntimeKind, false)
			other, _ := entryAt(entries, "unrelated")
			var enabled yaml.Node
			if err := yaml.Unmarshal([]byte(value), &enabled); err != nil {
				t.Fatal(err)
			}
			other.Content = append(other.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "enabled"}, enabled.Content[0])
			var policy yaml.Node
			if err := yaml.Unmarshal([]byte("platform_toolsets: {api_server: [unrelated]}"), &policy); err != nil {
				t.Fatal(err)
			}
			doc.Content[0].Content = append(doc.Content[0].Content, policy.Content[0].Content...)
			if err := writeConfig(path, doc, b.RuntimeKind); err != nil {
				t.Fatal(err)
			}
			result := VerifyBinding("", b)
			disabled := value == "false" || value == "False" || value == "0" || value == "0.0" || value == "0x0" || value == "' OFF '"
			if (result.State == runtime.AdapterStateMCPRestartRequired) != disabled {
				t.Fatalf("enabled=%s policy %+v", value, result)
			}
		})
	}
}
