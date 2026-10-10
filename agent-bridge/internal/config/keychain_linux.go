//go:build !darwin

package config

import (
	"errors"
	"fmt"
)

var errSecretMissing = errors.New("credential missing")

func SecretMissing(err error) bool { return errors.Is(err, errSecretMissing) }
func (KeychainStore) Get(string) (string, error) {
	return "", fmt.Errorf("credential_unavailable: macOS Keychain required")
}
func (KeychainStore) Set(string, string) error {
	return fmt.Errorf("credential_unavailable: macOS Keychain required")
}
func (KeychainStore) Delete(string) error {
	return fmt.Errorf("credential_unavailable: macOS Keychain required")
}
