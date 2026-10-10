package config

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"strings"
)

const keyringService = "ai.personastack.desktop.agent-bridge"

// SecretStore keeps a single Keychain authority. Denial never creates fallback files.
type SecretStore interface {
	Get(string) (string, error)
	Set(string, string) error
	Delete(string) error
}
type KeychainStore struct{ Service string }

func (s KeychainStore) service() string {
	if s.Service != "" {
		return s.Service
	}
	return keyringService
}

func getSecret(store SecretStore, key string) string {
	value, err := store.Get(key)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(value)
}
func loadBridgePrivateKeySecretWith(store SecretStore, key, publicKey string) string {
	value := getSecret(store, key)
	if !bridgePrivateKeyMatchesPublicKey(value, publicKey) {
		return ""
	}
	return value
}
func storeBindingSecretsWith(secrets SecretStore, binding Binding) (Binding, error) {
	// Target choice belongs to PersonaStack. These former pair-time fields may
	// appear in legacy state, but must never survive another local write.

	connectionID := binding.Key().String()
	if connectionID == "" {
		return binding, nil
	}
	if strings.TrimSpace(binding.BridgePrivateKey) != "" {
		if err := secrets.Set(bindingSecretKey(connectionID, "bridge-private-key"), binding.BridgePrivateKey); err != nil {
			return Binding{}, fmt.Errorf("store bridge private key: %w", err)
		}
		binding.BridgePrivateKey = ""
		binding.HasBridgeSecret = true
	}
	if strings.TrimSpace(binding.PersonaMCPToken) != "" {
		if err := secrets.Set(bindingSecretKey(connectionID, "persona-mcp-token"), binding.PersonaMCPToken); err != nil {
			return Binding{}, fmt.Errorf("store persona mcp token: %w", err)
		}
		binding.PersonaMCPToken = ""
		binding.HasPersonaMCPToken = true
	}

	if strings.TrimSpace(binding.OpenClawGatewayToken) != "" {
		if err := secrets.Set(bindingSecretKey(connectionID, "openclaw-gateway-token"), binding.OpenClawGatewayToken); err != nil {
			return Binding{}, fmt.Errorf("store OpenClaw gateway token: %w", err)
		}
		binding.OpenClawGatewayToken = ""
		binding.HasOpenClawToken = true
	}
	if strings.TrimSpace(binding.OpenClawPassword) != "" {
		if err := secrets.Set(bindingSecretKey(connectionID, "openclaw-password"), binding.OpenClawPassword); err != nil {
			return Binding{}, fmt.Errorf("store OpenClaw password: %w", err)
		}
		binding.OpenClawPassword = ""
		binding.HasOpenClawPassword = true
	}
	if strings.TrimSpace(binding.OpenClawDeviceToken) != "" {
		if err := secrets.Set(bindingSecretKey(connectionID, "openclaw-device-token"), binding.OpenClawDeviceToken); err != nil {
			return Binding{}, fmt.Errorf("store OpenClaw device token: %w", err)
		}
		binding.OpenClawDeviceToken = ""
		binding.HasOpenClawDevice = true
	}
	_ = secrets.Delete(bindingSecretKey(connectionID, "active-run-mcp-token"))
	return binding, nil
}

func loadBindingSecretsWith(secrets SecretStore, binding Binding) Binding {
	// Scrub legacy path and agent fields before any command can reuse them as a
	// fallback target. The connector must await an API-selected runtime target.

	connectionID := binding.Key().String()
	if connectionID == "" {
		return binding
	}
	if binding.HasBridgeSecret && strings.TrimSpace(binding.BridgePrivateKey) == "" {
		binding.BridgePrivateKey = loadBridgePrivateKeySecretWith(secrets,
			bindingSecretKey(connectionID, "bridge-private-key"),
			binding.BridgePublicKey,
		)
	}
	if binding.HasPersonaMCPToken && strings.TrimSpace(binding.PersonaMCPToken) == "" {
		binding.PersonaMCPToken = getSecret(secrets, bindingSecretKey(connectionID, "persona-mcp-token"))
	}

	if binding.HasOpenClawToken && strings.TrimSpace(binding.OpenClawGatewayToken) == "" {
		binding.OpenClawGatewayToken = getSecret(secrets, bindingSecretKey(connectionID, "openclaw-gateway-token"))
	}
	if binding.HasOpenClawPassword && strings.TrimSpace(binding.OpenClawPassword) == "" {
		binding.OpenClawPassword = getSecret(secrets, bindingSecretKey(connectionID, "openclaw-password"))
	}
	if binding.HasOpenClawDevice && strings.TrimSpace(binding.OpenClawDeviceToken) == "" {
		binding.OpenClawDeviceToken = getSecret(secrets, bindingSecretKey(connectionID, "openclaw-device-token"))
	}
	return binding
}

func bridgePrivateKeyMatchesPublicKey(privateKey string, publicKey string) bool {
	if strings.TrimSpace(publicKey) == "" {
		return strings.TrimSpace(privateKey) != ""
	}
	privateKeyRaw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(privateKey))
	if err != nil {
		return false
	}
	if len(privateKeyRaw) != ed25519.PrivateKeySize {
		return false
	}
	publicKeyRaw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(publicKey))
	if err != nil {
		return false
	}
	if len(publicKeyRaw) != ed25519.PublicKeySize {
		return false
	}
	derivedPublicKey := ed25519.PrivateKey(privateKeyRaw).Public().(ed25519.PublicKey)
	return bytes.Equal(derivedPublicKey, publicKeyRaw)
}

func deleteBindingSecretsWith(store SecretStore, binding Binding) error {
	for _, name := range []string{"bridge-private-key", "persona-mcp-token", "openclaw-gateway-token", "openclaw-password", "openclaw-device-token", "active-run-mcp-token"} {
		err := store.Delete(bindingSecretKey(binding.Key().String(), name))
		if err != nil && !SecretMissing(err) {
			return fmt.Errorf("remove binding credential: %w", err)
		}
	}
	return nil
}
func bindingSecretKey(connectionID, name string) string { return connectionID + ":" + name }
