//go:build darwin && cgo

package config

import "testing"

func TestDesktopAgentBridgeKeychainActualCoreFoundationAccountBoundary(t *testing.T) {
	t.Parallel()
	store := KeychainStore{}
	seen := map[string]bool{}
	for _, connection := range []ConnectionID{"first", "second"} {
		for _, suffix := range []string{"bridge-private-key", "persona-mcp-token", "openclaw-gateway-token", "openclaw-password", "openclaw-device-token", "active-run-mcp-token"} {
			key := bindingSecretKey((BindingKey{EnvironmentID: "https://app.example", ConnectionID: connection}).String(), suffix)
			want, err := store.account(key)
			if err != nil {
				t.Fatal(err)
			}
			actual, err := store.keychainAccountCFString(key)
			if err != nil || actual != want || seen[actual] {
				t.Fatalf("C/CFString account collision: %q %v", actual, err)
			}
			seen[actual] = true
		}
	}
}
