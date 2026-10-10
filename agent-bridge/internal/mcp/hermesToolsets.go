package mcp

import (
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

// Explicit native Repair enables only this server on this profile's API surface.
// Missing API toolsets inherit Hermes defaults and need no policy change.
func enableHermesAPIMCP(doc *yaml.Node, server string) error {
	platforms, _ := entryAt(doc.Content[0], "platform_toolsets")
	if platforms == nil || platforms.Tag == "!!null" {
		return nil
	}
	if platforms.Kind != yaml.MappingNode {
		return fmt.Errorf("cleanup_required: Hermes platform_toolsets must be a map")
	}
	tools, _ := entryAt(platforms, "api_server")
	if tools == nil || tools.Tag == "!!null" {
		return nil
	}
	if tools.Kind == yaml.ScalarNode && tools.Tag == "!!str" {
		var parsed yaml.Node
		err := yaml.Unmarshal([]byte(tools.Value), &parsed)
		if err != nil || len(parsed.Content) != 1 || parsed.Content[0].Kind != yaml.SequenceNode {
			return fmt.Errorf("cleanup_required: Hermes API toolset list invalid")
		}
		tools.Kind, tools.Tag, tools.Value, tools.Style = yaml.SequenceNode, "!!seq", "", 0
		tools.Content = parsed.Content[0].Content
	}
	if tools.Kind != yaml.SequenceNode {
		return fmt.Errorf("cleanup_required: Hermes API toolsets must be a list")
	}
	selected := false
	kept := make([]*yaml.Node, 0, len(tools.Content)+1)
	for _, tool := range tools.Content {
		if tool.Kind != yaml.ScalarNode || tool.Tag != "!!str" {
			return fmt.Errorf("cleanup_required: Hermes API toolset name invalid")
		}
		if tool.Value == "no_mcp" {
			continue
		}
		selected = selected || tool.Value == server
		kept = append(kept, tool)
	}
	if !selected {
		kept = append(kept, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: server})
	}
	tools.Content = kept
	return nil
}

// Match the producer's configured API MCP allowlist. This is configuration
// evidence, not a claim about the running native gateway's discovered registry.
func verifyHermesAPIMCP(doc *yaml.Node, server string) error {
	root := doc.Content[0]
	platforms, _ := entryAt(root, "platform_toolsets")
	tools, err := hermesToolsetList(platforms, "api_server")
	if err != nil {
		return err
	}
	entries, _ := entryAt(root, "mcp_servers")
	explicit := false
	selected := false
	for _, name := range tools {
		if name == "no_mcp" {
			return fmt.Errorf("Hermes API toolset disables MCP")
		}
		entry, _ := entryAt(entries, name)
		if entry != nil && hermesServerEnabled(entry) {
			explicit = true
			selected = selected || name == server
		}
	}
	if explicit && !selected {
		return fmt.Errorf("Hermes API toolset excludes the issued PersonaStack server")
	}
	agent, _ := entryAt(root, "agent")
	disabled, err := hermesToolsetList(agent, "disabled_toolsets")
	if err != nil {
		return err
	}
	for _, name := range disabled {
		name = strings.TrimSpace(name)
		if name == server || name == "mcp-"+server {
			return fmt.Errorf("Hermes global toolset policy disables PersonaStack MCP")
		}
	}
	return nil
}

func hermesToolsetList(parent *yaml.Node, key string) ([]string, error) {
	if parent == nil || parent.Tag == "!!null" {
		return nil, nil
	}
	if parent.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("Hermes toolset policy must be a map")
	}
	tools, _ := entryAt(parent, key)
	if tools == nil || tools.Tag == "!!null" {
		return nil, nil
	}
	if tools.Kind == yaml.ScalarNode && tools.Tag == "!!str" {
		var parsed yaml.Node
		err := yaml.Unmarshal([]byte(tools.Value), &parsed)
		if err != nil || len(parsed.Content) != 1 {
			return nil, fmt.Errorf("Hermes toolset list invalid")
		}
		tools = parsed.Content[0]
	}
	if tools.Kind != yaml.SequenceNode {
		return nil, fmt.Errorf("Hermes toolsets must be a list")
	}
	result := make([]string, 0, len(tools.Content))
	for _, tool := range tools.Content {
		if tool.Kind != yaml.ScalarNode || tool.Tag != "!!str" {
			return nil, fmt.Errorf("Hermes toolset name invalid")
		}
		result = append(result, tool.Value)
	}
	return result, nil
}
func hermesServerEnabled(entry *yaml.Node) bool {
	enabled, _ := entryAt(entry, "enabled")
	if enabled == nil {
		return true
	}
	var value any
	if err := enabled.Decode(&value); err != nil {
		return true
	}
	switch typed := value.(type) {
	case bool:
		return typed
	case int:
		return typed != 0
	case int64:
		return typed != 0
	case uint64:
		return typed != 0
	case float64:
		return typed != 0
	case string:
		switch strings.ToLower(strings.TrimSpace(typed)) {
		case "false", "0", "no", "off":
			return false
		}
	}
	return true
}
