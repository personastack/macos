package config

import (
	"encoding/base64"
	"fmt"
	"strings"
	"testing"
)

func TestDesktopAgentBridgeKeychainFullAccountEncoding(t *testing.T) {
	t.Parallel()
	store := KeychainStore{}
	seen := map[string]bool{}
	for _, env := range []string{"https://one.example", "https://two.example"} {
		for _, conn := range []ConnectionID{"same", "other"} {
			for _, suffix := range []string{"bridge-private-key", "persona-mcp-token", "openclaw-gateway-token", "openclaw-password", "openclaw-device-token", "active-run-mcp-token"} {
				key := bindingSecretKey((BindingKey{EnvironmentID: env, ConnectionID: conn}).String(), suffix)
				account, err := store.account(key)
				if err != nil || strings.ContainsRune(account, '\x00') || seen[account] {
					t.Fatalf("account collision or truncation: %q %v", account, err)
				}
				seen[account] = true
				decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(account, "v1:"))
				if err != nil || string(decoded) != key {
					t.Fatal("complete scoped key not preserved")
				}
			}
		}
	}
	legacy := KeychainStore{Service: "personastack-connector"}
	if account, err := legacy.account("connection:persona-mcp-token"); err != nil || account != "connection:persona-mcp-token" {
		t.Fatal("legacy migration lookup changed")
	}
	if _, err := legacy.account("connection\x00:persona-mcp-token"); err == nil {
		t.Fatal("NUL legacy account accepted")
	}
}

type deniedMCPSecrets struct{}

func (deniedMCPSecrets) Get(string) (string, error) { return "", fmt.Errorf("Keychain denied") }
func (deniedMCPSecrets) Set(string, string) error   { return fmt.Errorf("unexpected mutation") }
func (deniedMCPSecrets) Delete(string) error        { return fmt.Errorf("unexpected mutation") }
func TestDesktopAgentBridgeKeychainDenialDoesNotRequireCredentialReplacement(t *testing.T) {
	t.Parallel()
	b := Binding{EnvironmentID: "https://app.example", ConnectionID: "connection", HasPersonaMCPToken: true}
	readback := loadBindingSecretsWith(deniedMCPSecrets{}, b)
	if !readback.PersonaMCPSecretUnavailable || readback.PersonaMCPToken != "" || PersonaMCPReconnectRequired(readback) {
		t.Fatal("Keychain denial treated as missing credential")
	}
}
