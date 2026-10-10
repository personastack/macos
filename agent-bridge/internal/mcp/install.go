package mcp

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/hermessetup"
	"github.com/personastack/macos/agent-bridge/internal/openclawauth"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"gopkg.in/yaml.v3"
)

type InstallResult struct {
	ConnectionID           config.ConnectionID
	Runtime                runtime.AdapterKind
	Path, ServerName, Note string
}
type VerifyResult struct {
	ConnectionID                           config.ConnectionID
	Runtime                                runtime.AdapterKind
	Path, ServerName, Note, DiagnosticCode string
	State                                  runtime.AdapterState
}
type Installer struct {
	Store   config.Store
	HomeDir string
}

// Native direct HTTP entries are the only delivered MCP transport.
type nativeHTTPEntry struct {
	Transport string      `json:"transport" yaml:"transport"`
	URL       string      `json:"url" yaml:"url"`
	Headers   httpHeaders `json:"headers" yaml:"headers"`
}
type httpHeaders struct {
	Authorization string `json:"Authorization" yaml:"Authorization"`
}

func (i Installer) InstallAll() ([]InstallResult, error) {
	if i.Store == nil {
		return nil, ErrMissingBinding
	}
	results := []InstallResult{}
	for _, b := range i.Store.ListBindings() {
		r, err := i.InstallBinding(b)
		if err != nil {
			return nil, err
		}
		results = append(results, r)
	}
	return results, nil
}
func (i Installer) InstallBinding(b config.Binding) (InstallResult, error) { return i.install(b) }
func (i Installer) InstallBindingForTarget(b config.Binding, home, hermesHome string, identity hermessetup.ProcessIdentity) (InstallResult, error) {
	if identity.UID != os.Geteuid() {
		return InstallResult{}, fmt.Errorf("runtime_conflict: current-user target required")
	}
	b.HermesHome = hermesHome
	return i.install(b)
}
func (i Installer) install(b config.Binding) (InstallResult, error) {
	var result InstallResult
	err := config.UpdateBinding(i.Store, b, func(latest *config.Binding) error {
		if latest.ConnectionGeneration != b.ConnectionGeneration || latest.TargetSelectionRevision != b.TargetSelectionRevision || latest.ProfileCandidateID != b.ProfileCandidateID || latest.NativeConfigPath != b.NativeConfigPath || latest.NativeMCPServer != b.NativeMCPServer || latest.PersonaMCPToken != b.PersonaMCPToken {
			return fmt.Errorf("scope_changed: binding changed before native config mutation")
		}
		if latest.ActiveRunID != "" || latest.Quiesced {
			return fmt.Errorf("busy: assigned run or quiesce prevents native config mutation")
		}
		configured, err := ConfigureBinding(latest, false)
		result = configured
		return err
	})
	return result, err
}

// ConfigureBinding runs only inside the existing store mutation/admission guard.
// It changes native config and its ownership fields without a nested store write.
func ConfigureBinding(b *config.Binding, repairHermesToolset bool, openClawAppsConsent ...bool) (InstallResult, error) {
	if b.NativeConfigPath == "" || b.NativeMCPServer == "" || b.InventorySeed == "" || b.PersonaMCPToken == "" || b.PersonaMCPURL == "" {
		return InstallResult{}, fmt.Errorf("scoped profile and native MCP credential required")
	}
	doc, err := readConfig(b.NativeConfigPath)
	if err != nil {
		return InstallResult{}, err
	}
	if b.RuntimeKind == runtime.AdapterKindOpenClaw && len(openClawAppsConsent) > 0 {
		if _, err = OpenClawAppsEnabled(b.NativeConfigPath); err != nil {
			return InstallResult{}, err
		}
		if err = enableOpenClawApps(doc, openClawAppsConsent[0]); err != nil {
			return InstallResult{}, err
		}
	}
	entries, err := nativeEntries(doc, b.RuntimeKind, true)
	if err != nil {
		return InstallResult{}, err
	}
	canonical, err := filepath.EvalSymlinks(b.NativeConfigPath)
	if err != nil {
		return InstallResult{}, err
	}
	if err = transferCapturedEntry(entries, *b, canonical); err != nil {
		return InstallResult{}, err
	}
	if b.Migration == nil && b.MCPOwnership.EntryKey != "" && b.MCPOwnership.EntryKey != b.NativeMCPServer {
		previous, previousIndex := entryAt(entries, b.MCPOwnership.EntryKey)
		if previous != nil {
			if fingerprint(previous, b.InventorySeed) != b.MCPOwnership.Fingerprint {
				return InstallResult{}, fmt.Errorf("cleanup_required: previous owned MCP entry changed")
			}
			entries.Content = append(entries.Content[:previousIndex], entries.Content[previousIndex+2:]...)
		}
	}
	old, index := entryAt(entries, b.NativeMCPServer)
	if old != nil {
		if b.MCPOwnership.EntryKey != b.NativeMCPServer || b.MCPOwnership.Fingerprint != fingerprint(old, b.InventorySeed) {
			return InstallResult{}, fmt.Errorf("cleanup_required: native MCP entry changed or owned by user")
		}
	}
	raw, err := yaml.Marshal(nativeHTTPEntry{Transport: "streamable-http", URL: b.PersonaMCPURL, Headers: httpHeaders{Authorization: "Bearer " + b.PersonaMCPToken}})
	if err != nil {
		return InstallResult{}, fmt.Errorf("encode native MCP entry: %w", err)
	}
	var parsed yaml.Node
	err = yaml.Unmarshal(raw, &parsed)
	if err != nil {
		return InstallResult{}, fmt.Errorf("decode native MCP entry: %w", err)
	}
	entry := parsed.Content[0]
	if index < 0 {
		entries.Content = append(entries.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: b.NativeMCPServer}, entry)
	} else {
		entries.Content[index+1] = entry
	}
	canonical, err = filepath.EvalSymlinks(b.NativeConfigPath)
	if err != nil {
		return InstallResult{}, fmt.Errorf("resolve native config: %w", err)
	}
	if b.MCPOwnership.CanonicalConfigPath != "" && b.MCPOwnership.CanonicalConfigPath != canonical {
		return InstallResult{}, fmt.Errorf("cleanup_required: config symlink target changed")
	}
	if repairHermesToolset && b.RuntimeKind == runtime.AdapterKindHermes {
		if err = enableHermesAPIMCP(doc, b.NativeMCPServer); err != nil {
			return InstallResult{}, err
		}
	}
	err = writeConfig(canonical, doc, b.RuntimeKind)
	if err != nil {
		return InstallResult{}, err
	}
	b.MCPOwnership = config.MCPOwnership{ConfigPath: b.NativeConfigPath, CanonicalConfigPath: canonical, EntryKey: b.NativeMCPServer, Fingerprint: fingerprint(entry, b.InventorySeed), FormatVersion: 1}
	b.Migration = nil
	return InstallResult{ConnectionID: b.ConnectionID, Runtime: b.RuntimeKind, Path: b.NativeConfigPath, ServerName: b.NativeMCPServer, Note: "native MCP entry configured"}, nil
}
func RemoveOwned(b config.Binding) error {
	record := b.MCPOwnership
	if record.EntryKey == "" {
		return nil
	}
	canonical, err := filepath.EvalSymlinks(record.ConfigPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read owned config: %w", err)
	}
	if canonical != record.CanonicalConfigPath {
		return fmt.Errorf("cleanup_required: config target changed")
	}
	doc, err := readConfig(record.ConfigPath)
	if err != nil {
		return err
	}
	entries, err := nativeEntries(doc, b.RuntimeKind, false)
	if err != nil {
		return err
	}
	if entries == nil {
		return nil
	}
	entry, index := entryAt(entries, record.EntryKey)
	if entry == nil {
		return nil
	}
	if fingerprint(entry, b.InventorySeed) != record.Fingerprint {
		return fmt.Errorf("cleanup_required: owned entry changed")
	}
	entries.Content = append(entries.Content[:index], entries.Content[index+2:]...)
	return writeConfig(canonical, doc, b.RuntimeKind)
}
func readConfig(path string) (*yaml.Node, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read native config: %w", err)
	}
	var doc yaml.Node
	err = yaml.Unmarshal(raw, &doc)
	if err != nil {
		return nil, fmt.Errorf("cleanup_required: parse native config: %w", err)
	}
	if len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("cleanup_required: native config must be object")
	}
	if err := validateMappingKeys(&doc); err != nil {
		return nil, err
	}
	return &doc, nil
}
func writeConfig(path string, doc *yaml.Node, kind runtime.AdapterKind) error {
	var raw []byte
	var err error
	if kind == runtime.AdapterKindOpenClaw {
		var value json.RawMessage
		value, err = nodeJSON(doc.Content[0])
		if err == nil {
			raw, err = json.MarshalIndent(value, "", "  ")
		}
	} else {
		raw, err = yaml.Marshal(doc)
	}
	if err != nil {
		return fmt.Errorf("encode native config: %w", err)
	}
	err = os.WriteFile(path, raw, 0o600)
	if err != nil {
		return fmt.Errorf("write native config: %w", err)
	}
	return nil
}

// Native configs contain user-defined keys. Preserve their parsed structure.
func nodeJSON(node *yaml.Node) (json.RawMessage, error) {
	if node.Kind == yaml.MappingNode {
		values := map[string]json.RawMessage{}
		for i := 0; i < len(node.Content); i += 2 {
			raw, err := nodeJSON(node.Content[i+1])
			if err != nil {
				return nil, err
			}
			values[node.Content[i].Value] = raw
		}
		return json.Marshal(values)
	}
	if node.Kind == yaml.SequenceNode {
		values := []json.RawMessage{}
		for _, child := range node.Content {
			raw, err := nodeJSON(child)
			if err != nil {
				return nil, err
			}
			values = append(values, raw)
		}
		return json.Marshal(values)
	}
	switch node.Tag {
	case "!!bool", "!!int", "!!float", "!!null":
		return json.RawMessage(node.Value), nil
	default:
		return json.Marshal(node.Value)
	}
}
func nativeEntries(doc *yaml.Node, kind runtime.AdapterKind, create bool) (*yaml.Node, error) {
	key := "mcp_servers"
	if kind == runtime.AdapterKindOpenClaw {
		key = "mcp"
	}
	root := doc.Content[0]
	entry, index := entryAt(root, key)
	if entry == nil && create {
		entry = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		root.Content = append(root.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, entry)
	}
	_ = index
	if entry == nil {
		return nil, nil
	}
	if entry.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("cleanup_required: native MCP map invalid")
	}
	if kind == runtime.AdapterKindOpenClaw {
		servers, _ := entryAt(entry, "servers")
		if servers == nil && create {
			servers = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
			entry.Content = append(entry.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "servers"}, servers)
		}
		if servers != nil && servers.Kind != yaml.MappingNode {
			return nil, fmt.Errorf("cleanup_required: native MCP server map invalid")
		}
		return servers, nil
	}
	return entry, nil
}
func entryAt(node *yaml.Node, key string) (*yaml.Node, int) {
	if node == nil {
		return nil, -1
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == key {
			return node.Content[i+1], i
		}
	}
	return nil, -1
}
func fingerprint(node *yaml.Node, seed string) string {
	canonical := canonicalNode(node)
	raw, _ := yaml.Marshal(canonical)
	mac := hmac.New(sha256.New, []byte(seed))
	_, _ = mac.Write(raw)
	return hex.EncodeToString(mac.Sum(nil))
}
func canonicalNode(node *yaml.Node) *yaml.Node {
	result := *node
	result.HeadComment = ""
	result.LineComment = ""
	result.FootComment = ""
	result.Style = 0
	result.Content = nil
	if node.Kind == yaml.MappingNode {
		keys := []string{}
		for i := 0; i < len(node.Content); i += 2 {
			keys = append(keys, node.Content[i].Value)
		}
		sort.Strings(keys)
		for _, key := range keys {
			child, _ := entryAt(node, key)
			result.Content = append(result.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, canonicalNode(child))
		}
	} else {
		for _, child := range node.Content {
			result.Content = append(result.Content, canonicalNode(child))
		}
	}
	return &result
}
func VerifyBinding(home string, b config.Binding) VerifyResult {
	r := VerifyResult{ConnectionID: b.ConnectionID, Runtime: b.RuntimeKind, Path: b.NativeConfigPath, ServerName: b.NativeMCPServer, State: runtime.AdapterStateMCPRestartRequired}
	doc, err := readConfig(b.NativeConfigPath)
	if err != nil {
		r.State = runtime.AdapterStateMCPConfigMissing
		r.Note = err.Error()
		return r
	}
	entries, err := nativeEntries(doc, b.RuntimeKind, false)
	if err != nil {
		r.Note = err.Error()
		return r
	}
	entry, _ := entryAt(entries, b.NativeMCPServer)
	if entry == nil || b.MCPOwnership.Fingerprint != fingerprint(entry, b.InventorySeed) {
		r.State = runtime.AdapterStateMCPConfigMissing
		r.Note = "owned native MCP entry missing or changed"
	}
	return r
}
func VerifyBindingWithLive(ctx context.Context, home string, b config.Binding, client *http.Client) VerifyResult {
	return VerifyBindingWithLiveAt(ctx, home, b, client, b.RuntimeURL)
}
func VerifyBindingWithLiveAt(ctx context.Context, home string, b config.Binding, client *http.Client, runtimeURL string) VerifyResult {
	return verifyBindingWithNative(ctx, home, b, client, runtimeURL, nativeCatalog)
}

// Reuse the exact selected-profile adapter already admitted by the reconciler.
func VerifyBindingWithOpenClawAdapter(ctx context.Context, home string, b config.Binding, client *http.Client, adapter runtime.OpenClawAdapter) VerifyResult {
	adapter.ReadinessSession = b.OpenClawReadinessSession
	return verifyBindingWithNative(ctx, home, b, client, adapter.GatewayURL, func(ctx context.Context, _ config.Binding, _ string) (bool, string) {
		result := adapter.VerifyMCPCatalog(ctx, b.NativeMCPServer)
		return result.OK, result.Note
	})
}
func verifyBindingWithNative(ctx context.Context, home string, b config.Binding, client *http.Client, runtimeURL string, native func(context.Context, config.Binding, string) (bool, string)) VerifyResult {
	r := VerifyBinding(home, b)
	if r.State != runtime.AdapterStateMCPRestartRequired {
		return r
	}
	ok, note := native(ctx, b, runtimeURL)
	if !ok {
		r.Note = note
		r.DiagnosticCode = "native_mcp_unreachable"
		if b.RuntimeKind == runtime.AdapterKindOpenClaw {
			r.State = runtime.AdapterStateCapabilityMissing
			r.DiagnosticCode = "runtime_unsupported"
		}
		return r
	}
	live := VerifyBindingLive(ctx, b, client)
	if !live.OK {
		r.Note = live.Note
		r.DiagnosticCode = live.DiagnosticCode
		return r
	}
	r.State = runtime.AdapterStateMCPVerified
	r.Note = "selected runtime and PersonaStack MCP verified"
	return r
}
func VerifyBindingInUserHome(b config.Binding) VerifyResult { return VerifyBinding("", b) }
func appendNote(parts ...string) string                     { return strings.Join(parts, "; ") }

func nativeCatalog(ctx context.Context, b config.Binding, runtimeURL string) (bool, string) {
	if b.RuntimeKind == runtime.AdapterKindOpenClaw {
		auth, err := openclawauth.Resolve(openclawauth.Options{StateDir: b.NativeStateRoot, Env: func(name string) string {
			if name == "OPENCLAW_CONFIG_PATH" {
				return b.NativeConfigPath
			}
			return ""
		}})
		if err != nil {
			return false, "selected OpenClaw credential unavailable"
		}
		adapter := runtime.NewOpenClawAdapterWithAuth(runtimeURL, auth.Auth, b.OpenClawAgentID)
		adapter.StateRoot = b.NativeStateRoot
		adapter.ConfigPath = b.NativeConfigPath
		adapter.SessionOwner = b.Key().String()
		adapter.NativeMCPServer = b.NativeMCPServer
		adapter.NativeMCPNamespace = b.NativeMCPNamespace
		adapter.ReadinessSession = b.OpenClawReadinessSession
		adapter.MCPAppsEnabled = func() (bool, error) { return OpenClawAppsEnabled(b.NativeConfigPath) }
		native := adapter.VerifyMCPCatalog(ctx, b.NativeMCPServer)
		return native.OK, native.Note
	}
	native := runtime.VerifyHermesMCPServerLoadedWithHome(ctx, b.NativeMCPServer, b.HermesHome)
	return native.OK, native.Note
}

func validateMappingKeys(node *yaml.Node) error {
	if node.Kind == yaml.MappingNode {
		seen := map[string]bool{}
		for i := 0; i < len(node.Content); i += 2 {
			key := node.Content[i].Value
			if seen[key] {
				return fmt.Errorf("cleanup_required: duplicate native config key")
			}
			seen[key] = true
		}
	}
	for _, child := range node.Content {
		if err := validateMappingKeys(child); err != nil {
			return err
		}
	}
	return nil
}
