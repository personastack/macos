package mcp

import (
	"fmt"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"gopkg.in/yaml.v3"
	"os"
	"path/filepath"
	"reflect"
)

// CaptureLegacy requires exact credential or exact legacy CLI invocation ownership.
func CaptureLegacy(b config.Binding, id, backupPath string) (config.MigrationCapture, error) {
	if b.PersonaMCPToken == "" || b.NativeMCPServer == "" || b.NativeMCPNamespace == "" || b.InventorySeed == "" {
		return config.MigrationCapture{}, fmt.Errorf("legacy binding custody missing")
	}
	doc, err := readConfig(b.NativeConfigPath)
	if err != nil {
		return config.MigrationCapture{}, err
	}
	entries, err := nativeEntries(doc, b.RuntimeKind, false)
	if err != nil {
		return config.MigrationCapture{}, err
	}
	entry, _ := entryAt(entries, b.NativeMCPServer)
	if entry == nil {
		return config.MigrationCapture{}, fmt.Errorf("legacy native entry missing")
	}
	var legacy struct {
		Transport string `yaml:"transport"`
		URL       string `yaml:"url"`
		Headers   struct {
			Authorization string `yaml:"Authorization"`
		} `yaml:"headers"`
		Command string   `yaml:"command"`
		Args    []string `yaml:"args"`
	}
	if err = entry.Decode(&legacy); err != nil {
		return config.MigrationCapture{}, err
	}
	direct := legacy.URL == b.PersonaMCPURL && legacy.Headers.Authorization == "Bearer "+b.PersonaMCPToken && (legacy.Transport == "streamable-http" || legacy.Transport == "sse")
	stdio := filepath.Base(legacy.Command) == "personastack-connector" && reflect.DeepEqual(legacy.Args, []string{"mcp", "stdio", "--binding", string(b.ConnectionID)})
	if !direct && !stdio {
		return config.MigrationCapture{}, fmt.Errorf("legacy native entry does not match exact binding")
	}
	canonical, err := filepath.EvalSymlinks(b.NativeConfigPath)
	if err != nil {
		return config.MigrationCapture{}, err
	}
	raw, err := os.ReadFile(canonical)
	if err != nil {
		return config.MigrationCapture{}, err
	}
	file, err := os.OpenFile(backupPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return config.MigrationCapture{}, err
	}
	_, writeErr := file.Write(raw)
	closeErr := file.Close()
	if writeErr != nil {
		return config.MigrationCapture{}, writeErr
	}
	if closeErr != nil {
		return config.MigrationCapture{}, closeErr
	}
	return config.MigrationCapture{ID: id, ConfigPath: b.NativeConfigPath, CanonicalConfigPath: canonical, EntryKey: b.NativeMCPServer, Namespace: b.NativeMCPNamespace, Fingerprint: fingerprint(entry, b.InventorySeed), BackupPath: backupPath, LegacyConnectionID: b.ConnectionID}, nil
}
func transferCapturedEntry(entries *yaml.Node, b config.Binding, canonical string) error {
	capture := b.Migration
	if capture == nil {
		return nil
	}
	if canonical != capture.CanonicalConfigPath || b.NativeConfigPath != capture.ConfigPath {
		return fmt.Errorf("cleanup_required: migration profile changed")
	}
	entry, index := entryAt(entries, capture.EntryKey)
	if entry == nil || fingerprint(entry, b.InventorySeed) != capture.Fingerprint {
		return fmt.Errorf("cleanup_required: captured legacy entry changed")
	}
	if b.NativeMCPServer != capture.EntryKey {
		if current, _ := entryAt(entries, b.NativeMCPServer); current != nil {
			return fmt.Errorf("cleanup_required: replacement server collides")
		}
	}
	entries.Content = append(entries.Content[:index], entries.Content[index+2:]...)
	return nil
}

// LegacyEntryMatchesMetadata checks a known legacy key and endpoint for manual
// inspection guidance. It does not prove credential custody or permit deletion.
func LegacyEntryMatchesMetadata(b config.Binding) bool {
	if b.NativeMCPServer == "" {
		return false
	}
	doc, err := readConfig(b.NativeConfigPath)
	if err != nil {
		return false
	}
	entries, err := nativeEntries(doc, b.RuntimeKind, false)
	if err != nil {
		return false
	}
	entry, _ := entryAt(entries, b.NativeMCPServer)
	if entry == nil {
		return false
	}
	var metadata struct {
		Transport string   `yaml:"transport"`
		URL       string   `yaml:"url"`
		Command   string   `yaml:"command"`
		Args      []string `yaml:"args"`
	}
	if entry.Decode(&metadata) != nil {
		return false
	}
	direct := b.PersonaMCPURL != "" && metadata.URL == b.PersonaMCPURL && (metadata.Transport == "streamable-http" || metadata.Transport == "sse")
	stdio := filepath.Base(metadata.Command) == "personastack-connector" && reflect.DeepEqual(metadata.Args, []string{"mcp", "stdio", "--binding", string(b.ConnectionID)})
	return direct || stdio
}
