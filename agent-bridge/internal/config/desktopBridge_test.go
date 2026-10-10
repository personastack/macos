package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type fakeSecrets struct {
	mu     sync.Mutex
	values map[string]string
	denied bool
}

func (s *fakeSecrets) Get(key string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.denied {
		return "", errors.New("denied")
	}
	value, ok := s.values[key]
	if !ok {
		return "", errSecretMissing
	}
	return value, nil
}
func (s *fakeSecrets) Set(key, value string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.denied {
		return errors.New("denied")
	}
	s.values[key] = value
	return nil
}
func (s *fakeSecrets) Delete(key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.values, key)
	return nil
}
func TestDesktopAgentBridgeKeyedStores(t *testing.T) {
	t.Parallel()
	for _, file := range []bool{false, true} {
		t.Run(map[bool]string{false: "memory", true: "file"}[file], func(t *testing.T) {
			t.Parallel()
			memory := EmptyStore()
			var store WritableStore = &memory
			var keyed KeyedStore = &memory
			secrets := &fakeSecrets{values: map[string]string{}}
			if file {
				disk := NewFileStoreWithSecrets(filepath.Join(t.TempDir(), "private", "state.json"), secrets).WithInventorySeed("installation-seed")
				store = disk
				keyed = disk
			}
			bindings := []Binding{{EnvironmentID: "https://a.test", ConnectionID: "same", PersonaID: "a", PersonaMCPToken: "token-a", InventorySeed: "installation-seed"}, {EnvironmentID: "https://b.test", ConnectionID: "same", PersonaID: "b", PersonaMCPToken: "token-b"}, {EnvironmentID: "https://a.test", ConnectionID: "third", PersonaID: "c", PersonaMCPToken: "token-c"}}
			for _, b := range bindings {
				if err := store.SaveBinding(b); err != nil {
					t.Fatal(err)
				}
			}
			if len(store.ListBindings()) != 3 {
				t.Fatal("sibling lost")
			}
			if _, ok := store.Binding("same"); ok {
				t.Fatal("ambiguous unscoped read admitted")
			}
			updated, ok := keyed.BindingKey(bindings[1].Key())
			if !ok {
				t.Fatal("environment binding missing")
			}
			updated.ActiveRunID = "run-b"
			if err := store.SaveBinding(updated); err != nil {
				t.Fatal(err)
			}
			if err := keyed.DeleteBindingKey(bindings[0].Key()); err != nil {
				t.Fatal(err)
			}
			if len(store.ListBindings()) != 2 {
				t.Fatal("wrong deletion scope")
			}
			remaining, ok := keyed.BindingKey(bindings[1].Key())
			if !ok || remaining.PersonaMCPToken != "token-b" || remaining.ActiveRunID != "run-b" {
				t.Fatal("sibling credentials or run changed")
			}
			third, _ := keyed.BindingKey(bindings[2].Key())
			if third.PersonaMCPToken != "token-c" {
				t.Fatal("third credential changed")
			}
		})
	}
}
func TestDesktopAgentBridgeDeniedKeychainCreatesNoFallback(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	secrets := &fakeSecrets{values: map[string]string{}, denied: true}
	store := NewFileStoreWithSecrets(filepath.Join(dir, "state.json"), secrets)
	err := store.SaveBinding(Binding{EnvironmentID: "https://a.test", ConnectionID: "one", PersonaMCPToken: "private-token"})
	if err == nil {
		t.Fatal("denied credential accepted")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Fatal("fallback or state file created")
	}
}
func TestDesktopAgentBridgeStateRedactsSecretsAndSeed(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	path := filepath.Join(dir, "private", "state.json")
	secrets := &fakeSecrets{values: map[string]string{}}
	store := NewFileStoreWithSecrets(path, secrets).WithInventorySeed("private-seed")
	err := store.SaveBinding(Binding{EnvironmentID: "https://a.test", ConnectionID: "one", PersonaMCPToken: "private-token", InventorySeed: "private-seed"})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "private-token") || strings.Contains(string(raw), "private-seed") {
		t.Fatal("nonsecret state contains credentials")
	}
}
func TestDesktopAgentBridgeEnvironmentOrigin(t *testing.T) {
	t.Parallel()
	for _, row := range []struct {
		input, expected string
		denied          bool
	}{{"https://EXAMPLE.test:443/", "https://example.test", false}, {"http://Example.test:8080", "http://example.test:8080", false}, {"https://user@example.test", "", true}, {"https://example.test?q=x", "", true}} {
		t.Run(row.input, func(t *testing.T) {
			t.Parallel()
			value, err := NormalizeEnvironment(row.input)
			if row.denied {
				if err == nil {
					t.Fatal("invalid origin accepted")
				}
				return
			}
			if err != nil || value != row.expected {
				t.Fatalf("origin %q %v", value, err)
			}
		})
	}
}
