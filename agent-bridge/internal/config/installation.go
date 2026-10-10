package config

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
)

func InstallationSeed(secrets SecretStore) (string, error) {
	const key = "installation-inventory-seed"
	value, err := secrets.Get(key)
	if err == nil && value != "" {
		return value, nil
	}
	if !SecretMissing(err) {
		return "", fmt.Errorf("credential_unavailable: installation key access denied: %w", err)
	}
	raw := make([]byte, 32)
	_, err = rand.Read(raw)
	if err != nil {
		return "", fmt.Errorf("generate installation seed: %w", err)
	}
	value = base64.StdEncoding.EncodeToString(raw)
	err = secrets.Set(key, value)
	if err != nil {
		return "", fmt.Errorf("credential_unavailable: store installation key: %w", err)
	}
	return value, nil
}
