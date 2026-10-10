package mcp

import (
	"encoding/json"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// OpenClawAppsEnabled only reads the selected profile. Missing settings are disabled.
func OpenClawAppsEnabled(path string) (bool, error) {
	raw, err := os.ReadFile(path)
	if err != nil || !json.Valid(raw) {
		return false, fmt.Errorf("native_config_unsupported: selected OpenClaw config must be strict JSON")
	}
	var doc yaml.Node
	if err = yaml.Unmarshal(raw, &doc); err != nil || len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return false, fmt.Errorf("native_config_unsupported: selected OpenClaw config must be an object")
	}
	if err = validateMappingKeys(&doc); err != nil {
		return false, err
	}
	_, enabled, err := openClawAppsNode(&doc, false)
	if err == nil && enabled {
		err = validateOpenClawLoopback(&doc)
	}
	return enabled, err
}

func openClawAppsNode(doc *yaml.Node, create bool) (*yaml.Node, bool, error) {
	node := doc.Content[0]
	for _, key := range []string{"mcp", "apps"} {
		child, _ := entryAt(node, key)
		if child == nil && create {
			child = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
			node.Content = append(node.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, child)
		}
		if child == nil {
			return nil, false, nil
		}
		if child.Kind != yaml.MappingNode {
			return nil, false, fmt.Errorf("native_config_unsupported: OpenClaw MCP Apps setting must be an object")
		}
		node = child
	}
	enabled, _ := entryAt(node, "enabled")
	if enabled == nil {
		return node, false, nil
	}
	if enabled.Kind != yaml.ScalarNode || enabled.Tag != "!!bool" {
		return nil, false, fmt.Errorf("native_config_unsupported: OpenClaw MCP Apps enabled must be boolean")
	}
	return node, enabled.Value == "true", nil
}

func enableOpenClawApps(doc *yaml.Node, confirmed bool) error {
	_, enabled, err := openClawAppsNode(doc, false)
	if err != nil {
		return err
	}
	if !enabled && !confirmed {
		return fmt.Errorf("mcp_apps_disabled: explicit native MCP Apps consent required")
	}
	if err = validateOpenClawLoopback(doc); err != nil {
		return err
	}
	if enabled {
		return nil
	}
	apps, _, err := openClawAppsNode(doc, true)
	if err != nil {
		return err
	}
	enabledNode, index := entryAt(apps, "enabled")
	if enabledNode == nil {
		apps.Content = append(apps.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "enabled"}, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"})
	} else {
		apps.Content[index+1] = &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"}
	}
	return nil
}

func validateOpenClawLoopback(doc *yaml.Node) error {
	// The upstream HTML sandbox listener inherits Gateway bind hosts.
	// Enable only the default or explicit loopback mode. Never broaden a host.
	gateway, _ := entryAt(doc.Content[0], "gateway")
	if gateway != nil {
		if gateway.Kind != yaml.MappingNode {
			return fmt.Errorf("native_config_unsupported: OpenClaw gateway must be an object")
		}
		bind, _ := entryAt(gateway, "bind")
		if bind != nil && (bind.Kind != yaml.ScalarNode || bind.Tag != "!!str" || bind.Value != "loopback") {
			return fmt.Errorf("runtime_conflict: MCP Apps requires a loopback Gateway bind")
		}
	}
	return nil
}
