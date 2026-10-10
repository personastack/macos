package mcp

import (
	"fmt"

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
