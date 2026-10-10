package hermessetup

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// HostPaths retains selected-profile custody while targeting the native default
// shared gateway. A named profile never launches its own gateway.
func HostPaths(selected Paths, profile string) (Paths, error) {
	if profile == "" || profile == "default" {
		return selected, nil
	}
	root, err := filepath.EvalSymlinks(filepath.Join(selected.HomeDir, ".hermes"))
	if err != nil {
		return Paths{}, fmt.Errorf("runtime_conflict: Hermes shared host is unavailable")
	}
	return ResolvePaths(selected.HomeDir, root), nil
}

// APIEndpoint uses the producer's effective adapter bind. Its usable API key
// enables the environment override pass after the YAML platform merge.
func APIEndpoint(paths Paths) (string, error) {
	state, err := ReadAPIConfig(paths)
	return state.Endpoint, err
}

type APIConfig struct{ Endpoint, Key string }

func ReadAPIConfig(paths Paths) (APIConfig, error) {
	api, err := readNativeAPIBlock(paths)
	if err != nil {
		return APIConfig{}, err
	}
	values, err := nativeAPIBind(api)
	if err != nil {
		return APIConfig{}, err
	}
	values, err = applyAPIEnvironment(paths, values)
	if err != nil {
		return APIConfig{}, err
	}
	number, err := strconv.Atoi(values.port)
	if err != nil || number < 1024 || number > 65535 {
		return APIConfig{}, fmt.Errorf("runtime_conflict: Hermes host port invalid")
	}
	ip := net.ParseIP(values.host)
	if values.host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return APIConfig{}, fmt.Errorf("runtime_conflict: Hermes host API must bind loopback")
	}
	return APIConfig{Endpoint: "http://" + net.JoinHostPort(values.host, values.port), Key: values.key}, nil
}

func readNativeAPIBlock(paths Paths) (*yaml.Node, error) {
	if err := supportedHostSources(paths); err != nil {
		return nil, err
	}
	if info, err := os.Stat(filepath.Join(paths.HermesHome, "gateway.json")); err == nil && info.Size() > 0 {
		return nil, fmt.Errorf("runtime_conflict: legacy Hermes gateway configuration is unsupported")
	}
	raw, err := os.ReadFile(paths.ConfigPath)
	if err != nil {
		return nil, fmt.Errorf("read Hermes host config: %w", err)
	}
	if len(raw) > 1024*1024 {
		return nil, fmt.Errorf("runtime_conflict: oversized Hermes host configuration")
	}
	var doc yaml.Node
	err = yaml.Unmarshal(raw, &doc)
	if err == nil {
		err = validateNativeYAML(&doc, 0)
	}
	if err != nil || len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("runtime_conflict: unsupported Hermes host configuration")
	}
	if yamlField(doc.Content[0], "secrets") != nil {
		return nil, fmt.Errorf("runtime_conflict: external Hermes secret sources are unsupported")
	}
	return apiBlock(doc.Content[0])
}

type nativeAPIBindValues struct{ host, port, key string }

func nativeAPIBind(api *yaml.Node) (nativeAPIBindValues, error) {
	values := nativeAPIBindValues{host: "127.0.0.1", port: "8642"}
	extra := yamlField(api, "extra")
	if extra != nil && extra.Kind != yaml.MappingNode {
		return values, fmt.Errorf("runtime_conflict: malformed Hermes API extras")
	}
	for _, key := range []string{"host", "port", "key"} {
		node := yamlField(api, key)
		if explicit := yamlField(extra, key); explicit != nil {
			node = explicit
		}
		if node == nil {
			continue
		}
		if node.Kind != yaml.ScalarNode || strings.Contains(node.Value, "$") {
			return values, fmt.Errorf("runtime_conflict: unsupported Hermes API bind")
		}
		switch key {
		case "host":
			values.host = node.Value
		case "port":
			values.port = node.Value
		case "key":
			values.key = node.Value
		}
	}
	return values, nil
}
func applyAPIEnvironment(paths Paths, values nativeAPIBindValues) (nativeAPIBindValues, error) {
	env, err := loadEnvState(paths.EnvPath)
	if err != nil {
		return values, err
	}
	if key := findEnvValue(env, "API_SERVER_KEY"); len(strings.TrimSpace(key)) >= 16 {
		values.key = key
		if host := findEnvValue(env, "API_SERVER_HOST"); host != "" {
			values.host = host
		}
		if port := findEnvValue(env, "API_SERVER_PORT"); port != "" {
			values.port = port
		}
	}
	if !literalEnvValue(values.key) || !literalEnvValue(values.host) || !literalEnvValue(values.port) {
		return values, fmt.Errorf("runtime_conflict: unsupported Hermes API environment value")
	}
	return values, nil
}

// Managed overlays and external secret sources can replace the native bind or
// credentials. Do not infer their effective authority from a local YAML file.
func supportedHostSources(paths Paths) error {
	return supportedManagedDirectory(paths, os.Getenv("HERMES_MANAGED_DIR"))
}

func supportedManagedDirectory(paths Paths, ambient string) error {
	managed := strings.TrimSpace(ambient)
	env, err := loadEnvState(paths.EnvPath)
	if err != nil {
		return err
	}
	if _, defined := env.index["HERMES_MANAGED_DIR"]; defined {
		managed = findEnvValue(env, "HERMES_MANAGED_DIR")
	}
	if managed == "" {
		managed = "/etc/hermes"
	}
	if !filepath.IsAbs(managed) || !literalEnvValue(managed) {
		return fmt.Errorf("runtime_conflict: unsupported Hermes managed configuration selector")
	}
	if info, err := os.Stat(managed); err == nil && info.IsDir() {
		return fmt.Errorf("runtime_conflict: managed Hermes host configuration is unsupported")
	}
	return nil
}

func literalEnvValue(value string) bool {
	return !strings.ContainsAny(value, "$\"'\x00\r\n") && !strings.HasPrefix(value, "__")
}

// The launch home's .env overrides inherited globals in the native loader.
// Only literal absolute lock locations are supported. No helper registry exists.
func GatewayLockDirectory(paths Paths, home, state, override string) (string, error) {
	env, err := loadEnvState(paths.EnvPath)
	if err != nil {
		return "", err
	}
	if _, defined := env.index["XDG_STATE_HOME"]; defined {
		state = findEnvValue(env, "XDG_STATE_HOME")
	}
	if _, defined := env.index["HERMES_GATEWAY_LOCK_DIR"]; defined {
		override = findEnvValue(env, "HERMES_GATEWAY_LOCK_DIR")
	}
	if !literalEnvValue(state) || !literalEnvValue(override) {
		return "", fmt.Errorf("runtime_conflict: unsupported Hermes host rendezvous")
	}
	if override != "" {
		if !filepath.IsAbs(override) {
			return "", fmt.Errorf("runtime_conflict: unsupported Hermes host rendezvous")
		}
		return filepath.Clean(override), nil
	}
	if !filepath.IsAbs(state) {
		state = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(state, "hermes", "gateway-locks"), nil
}

func yamlField(node *yaml.Node, key string) *yaml.Node {
	if node == nil || node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == key {
			return node.Content[i+1]
		}
	}
	return nil
}

// Follow the native merge order. A block's authored extra wins flat settings.
func apiBlock(root *yaml.Node) (*yaml.Node, error) {
	if yamlField(root, "api_server") != nil {
		return nil, fmt.Errorf("runtime_conflict: root Hermes API shorthand is unsupported")
	}
	gateway := yamlField(root, "gateway")
	result := &yaml.Node{Kind: yaml.MappingNode}
	for _, block := range []*yaml.Node{yamlField(yamlField(gateway, "platforms"), "api_server"), yamlField(yamlField(root, "platforms"), "api_server"), yamlField(gateway, "api_server")} {
		if block == nil {
			continue
		}
		if block.Kind != yaml.MappingNode {
			return nil, fmt.Errorf("runtime_conflict: malformed Hermes API platform")
		}
		for i := 0; i+1 < len(block.Content); i += 2 {
			upsertYAML(result, block.Content[i].Value, block.Content[i+1])
		}
	}
	return result, nil
}
func upsertYAML(node *yaml.Node, key string, value *yaml.Node) {
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == key {
			if key == "extra" && node.Content[i+1].Kind == yaml.MappingNode && value.Kind == yaml.MappingNode {
				for j := 0; j+1 < len(value.Content); j += 2 {
					upsertYAML(node.Content[i+1], value.Content[j].Value, value.Content[j+1])
				}
			} else {
				node.Content[i+1] = value
			}
			return
		}
	}
	node.Content = append(node.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, value)
}

// EnsureProfileAPIKey adds no listener intent to a named profile. Native /p/
// authentication reads this profile's credential and never the host key.
func EnsureProfileAPIKey(paths Paths, profiles ...string) error {
	if err := supportedHostSources(paths); err != nil {
		return err
	}
	profile := "default"
	if len(profiles) > 0 && profiles[0] != "" {
		profile = profiles[0]
	}
	var key string
	var err error
	if profile == "default" {
		state, e := ReadAPIConfig(paths)
		key, err = state.Key, e
	} else {
		key, err = resolveAPIKey(paths.EnvPath)
	}
	if err != nil {
		return err
	}
	if len(strings.TrimSpace(key)) < 16 {
		return fmt.Errorf("runtime_conflict: Hermes profile API key must contain at least 16 characters")
	}
	if !literalEnvValue(key) {
		return fmt.Errorf("runtime_conflict: unsupported Hermes profile API credential")
	}
	_, err = ensureEnvFile(paths.EnvPath, map[string]string{"API_SERVER_KEY": key})
	return err
}

// EnsureHostAPI requires explicit shared-host consent from the native caller.
func EnsureHostAPI(paths Paths, endpoint string) error {
	info, err := os.Lstat(paths.ConfigPath)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("runtime_conflict: unsupported Hermes host config ownership")
	}
	effective, err := ReadAPIConfig(paths)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(paths.ConfigPath)
	if err != nil {
		return err
	}
	var doc yaml.Node
	err = yaml.Unmarshal(raw, &doc)
	if err != nil {
		return err
	}
	root := doc.Content[0]
	platforms := yamlField(root, "platforms")
	if platforms == nil {
		platforms = &yaml.Node{Kind: yaml.MappingNode}
		upsertYAML(root, "platforms", platforms)
	}
	if platforms.Kind != yaml.MappingNode {
		return fmt.Errorf("runtime_conflict: malformed Hermes platforms")
	}
	api := yamlField(platforms, "api_server")
	if api == nil {
		api = &yaml.Node{Kind: yaml.MappingNode}
		upsertYAML(platforms, "api_server", api)
	}
	if api.Kind != yaml.MappingNode {
		return fmt.Errorf("runtime_conflict: malformed Hermes API platform")
	}
	upsertYAML(api, "enabled", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"})
	// Shorthand is later in native merge order. Preserve it while updating only
	// the exact API enable switch explicitly covered by shared-host consent.
	shortcut := yamlField(yamlField(root, "gateway"), "api_server")
	if shortcut != nil {
		upsertYAML(shortcut, "enabled", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"})
	}
	if endpoint != effective.Endpoint {
		return fmt.Errorf("scope_changed: Hermes host bind changed")
	}
	key := effective.Key
	if key == "" {
		key, err = generateAPIKey()
		if err != nil {
			return err
		}
	}
	if len(key) < 16 {
		return fmt.Errorf("runtime_conflict: Hermes host API key is unusable")
	}
	bind, err := url.Parse(effective.Endpoint)
	if err != nil {
		return err
	}
	_, err = ensureEnvFile(paths.EnvPath, map[string]string{"API_SERVER_ENABLED": "true", "API_SERVER_HOST": bind.Hostname(), "API_SERVER_PORT": bind.Port(), "API_SERVER_KEY": key})
	if err != nil {
		return err
	}
	updated, err := yaml.Marshal(&doc)
	if err != nil {
		return err
	}
	return ensureOwnerOnlyFile(paths.ConfigPath, updated)
}

// LoadProfileAPIKey never lets a named profile borrow the shared host key.
func LoadProfileAPIKey(paths Paths, profile string) (string, error) {
	if err := supportedHostSources(paths); err != nil {
		return "", err
	}
	if profile == "" || profile == "default" {
		config, err := ReadAPIConfig(paths)
		return config.Key, err
	}
	state, err := loadEnvState(paths.EnvPath)
	if err != nil {
		return "", err
	}
	key := findEnvValue(state, "API_SERVER_KEY")
	if !literalEnvValue(key) {
		return "", fmt.Errorf("runtime_conflict: unsupported Hermes profile API credential")
	}
	return key, nil
}

// Shared-host routing deliberately excludes native parked and standalone profiles.
// PersonaStack never unparks them or enables the retired standalone shim.
func SharedProfileEligible(paths Paths, profile string) error {
	if err := supportedHostSources(paths); err != nil {
		return err
	}
	if profile == "" || profile == "default" {
		return nil
	}
	_, err := os.Stat(filepath.Join(paths.HermesHome, "gateway.parked"))
	if err == nil {
		return fmt.Errorf("runtime_conflict: Hermes profile is parked")
	}
	if !os.IsNotExist(err) {
		return fmt.Errorf("runtime_conflict: Hermes parked state unavailable")
	}
	raw, err := os.ReadFile(paths.ConfigPath)
	if err != nil {
		return err
	}
	var doc yaml.Node
	err = yaml.Unmarshal(raw, &doc)
	if err == nil {
		err = validateNativeYAML(&doc, 0)
	}
	if err != nil || len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return fmt.Errorf("runtime_conflict: malformed Hermes profile config")
	}
	if yamlField(doc.Content[0], "secrets") != nil {
		return fmt.Errorf("runtime_conflict: external Hermes profile secret sources unsupported")
	}
	standalone := yamlField(yamlField(doc.Content[0], "gateway"), "standalone")
	if standalone == nil {
		return nil
	}
	if standalone.Kind != yaml.ScalarNode {
		return fmt.Errorf("runtime_conflict: unsupported Hermes standalone setting")
	}
	switch strings.ToLower(strings.TrimSpace(standalone.Value)) {
	case "false", "no", "off", "0", "", "null":
		return nil
	case "true", "yes", "on", "1":
		return fmt.Errorf("runtime_conflict: standalone Hermes profiles are unsupported")
	default:
		return fmt.Errorf("runtime_conflict: unsupported Hermes standalone setting")
	}
}

func validateNativeYAML(node *yaml.Node, depth int) error {
	if depth > 32 || node.Kind == yaml.AliasNode {
		return fmt.Errorf("unsupported native YAML")
	}
	if node.Kind == yaml.MappingNode {
		seen := map[string]bool{}
		for i := 0; i+1 < len(node.Content); i += 2 {
			key := node.Content[i]
			if key.Kind != yaml.ScalarNode || seen[key.Value] {
				return fmt.Errorf("ambiguous native YAML")
			}
			seen[key.Value] = true
		}
	}
	for _, child := range node.Content {
		err := validateNativeYAML(child, depth+1)
		if err != nil {
			return err
		}
	}
	return nil
}
