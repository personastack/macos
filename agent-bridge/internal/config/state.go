package config

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

type ConnectionID string
type PersonaID string

type ExternalAgentKind int

const (
	ExternalAgentKindHermes ExternalAgentKind = iota
	ExternalAgentKindOpenClaw
)

func (kind ExternalAgentKind) String() string {
	switch kind {
	case ExternalAgentKindHermes:
		return "hermes"
	case ExternalAgentKindOpenClaw:
		return "openclaw"
	default:
		return "unknown"
	}
}

type MigrationCapture struct {
	WasPaused           bool
	PauseVersion        int64
	ID                  string
	ConfigPath          string
	CanonicalConfigPath string
	EntryKey            string
	Namespace           string
	Fingerprint         string
	BackupPath          string
	LegacyConnectionID  ConnectionID
}
type Binding struct {
	PersonaMCPSecretUnavailable bool `json:"-"`
	ReadinessDiagnosticCode     string

	Migration               *MigrationCapture `json:",omitempty"`
	EnvironmentID           string
	WorkspaceID             string
	ProfileCandidateID      string
	AccountCandidateID      string
	TargetSelectionRevision int64
	InventorySeed           string `json:"-"`
	PhysicalProfileID       string
	NativeStateRoot         string
	NativeConfigPath        string
	NativeProfileName       string
	RuntimeURL              string
	RuntimeLaunchAllowed    bool
	MCPOwnership            MCPOwnership
	Quiesced                bool
	ConnectionID            ConnectionID
	PersonaID               PersonaID
	ExternalAgentKind       ExternalAgentKind
	ConnectionGeneration    int64
	GatewayWebsocketURL     string
	BridgeCredentialID      string
	BridgePrivateKey        string
	BridgePublicKey         string
	NativeMCPServer         string
	NativeMCPNamespace      string
	HermesHome              string
	OpenClawAgentID         string
	OpenClawGatewayToken    string
	OpenClawPassword        string
	OpenClawDeviceToken     string
	PersonaMCPURL           string
	PersonaMCPToken         string
	ActiveRunID             string
	ActiveAssignmentID      string
	ActiveNativeRunID       string
	ActiveRunDeadlineAt     time.Time
	LastHeartbeatAt         time.Time
	LastWakeProbeAt         time.Time
	LastWakeProbeGeneration int64
	RuntimeKind             runtime.AdapterKind
	ReadinessState          runtime.AdapterState
	HasBridgeSecret         bool
	HasOpenClawToken        bool
	HasOpenClawPassword     bool
	HasOpenClawDevice       bool
	HasPersonaMCPToken      bool
}

type MCPOwnership struct {
	ConfigPath, CanonicalConfigPath, EntryKey, Fingerprint string
	FormatVersion                                          int
}

type State struct{ Bindings []Binding }

// BindingKey isolates credentials/state across approved server environments.
type BindingKey struct {
	EnvironmentID string       `json:"environment_id"`
	ConnectionID  ConnectionID `json:"connection_id"`
}

func (b Binding) Key() BindingKey {
	return BindingKey{EnvironmentID: b.EnvironmentID, ConnectionID: b.ConnectionID}
}
func (key BindingKey) String() string { return key.EnvironmentID + "\x00" + string(key.ConnectionID) }
func NormalizeEnvironment(raw string) (string, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") {
		return "", fmt.Errorf("approved server origin required")
	}
	parsed.Scheme = strings.ToLower(parsed.Scheme)
	parsed.Host = strings.ToLower(parsed.Host)
	if (parsed.Scheme == "https" && parsed.Port() == "443") || (parsed.Scheme == "http" && parsed.Port() == "80") {
		parsed.Host = parsed.Hostname()
	}
	parsed.Path = ""
	return parsed.String(), nil
}

type Store interface {
	Binding(ConnectionID) (Binding, bool)
	ListBindings() []Binding
}
type WritableStore interface {
	Store
	SaveBinding(Binding) error
}
type DeletingStore interface {
	Store
	DeleteBinding(ConnectionID) error
}
type KeyedStore interface {
	Store
	BindingKey(BindingKey) (Binding, bool)
	DeleteBindingKey(BindingKey) error
}

func BindingFor(store Store, reference Binding) (Binding, bool) {
	if keyed, ok := store.(KeyedStore); ok {
		return keyed.BindingKey(reference.Key())
	}
	b, ok := store.Binding(reference.ConnectionID)
	return b, ok && b.EnvironmentID == reference.EnvironmentID
}
func DeleteBindingFor(store Store, reference Binding) error {
	if keyed, ok := store.(KeyedStore); ok {
		return keyed.DeleteBindingKey(reference.Key())
	}
	return fmt.Errorf("keyed binding store required")
}

type MemoryStore struct {
	mu    *sync.RWMutex
	state *State
}

func NewMemoryStore(state State) MemoryStore {
	return MemoryStore{mu: &sync.RWMutex{}, state: &State{Bindings: append([]Binding(nil), state.Bindings...)}}
}
func EmptyStore() MemoryStore { return NewMemoryStore(State{}) }
func (store MemoryStore) Binding(id ConnectionID) (Binding, bool) {
	return uniqueBinding(store.ListBindings(), id)
}
func (store MemoryStore) BindingKey(key BindingKey) (Binding, bool) {
	for _, b := range store.ListBindings() {
		if b.Key() == key {
			return b, true
		}
	}
	return Binding{}, false
}
func (store MemoryStore) ListBindings() []Binding {
	store.mu.RLock()
	defer store.mu.RUnlock()
	return append([]Binding(nil), store.state.Bindings...)
}
func (store *MemoryStore) SaveBinding(b Binding) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	store.state.Bindings = upsertBinding(store.state.Bindings, b)
	return nil
}
func (store *MemoryStore) DeleteBinding(id ConnectionID) error {
	b, ok := store.Binding(id)
	if !ok {
		return fmt.Errorf("binding missing or ambiguous")
	}
	return store.DeleteBindingKey(b.Key())
}
func (store *MemoryStore) DeleteBindingKey(key BindingKey) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	store.state.Bindings = removeBinding(store.state.Bindings, key)
	return nil
}
func uniqueBinding(bindings []Binding, id ConnectionID) (Binding, bool) {
	var found Binding
	count := 0
	for _, b := range bindings {
		if b.ConnectionID == id {
			found = b
			count++
		}
	}
	return found, count == 1
}
func upsertBinding(bindings []Binding, b Binding) []Binding {
	for i, old := range bindings {
		if old.Key() == b.Key() {
			bindings[i] = b
			return bindings
		}
	}
	return append(bindings, b)
}
func removeBinding(bindings []Binding, key BindingKey) []Binding {
	result := make([]Binding, 0, len(bindings))
	for _, b := range bindings {
		if b.Key() != key {
			result = append(result, b)
		}
	}
	return result
}

type FileStore struct {
	path          string
	mu            *sync.Mutex
	secrets       SecretStore
	inventorySeed string
}

func DefaultFileStore() (FileStore, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return FileStore{}, fmt.Errorf("resolve user home: %w", err)
	}
	return NewFileStore(filepath.Join(home, "Library", "Application Support", "PersonaStack", "AgentBridge", "state.json")), nil
}
func NewFileStore(path string) FileStore { return NewFileStoreWithSecrets(path, KeychainStore{}) }
func NewFileStoreWithSecrets(path string, secrets SecretStore) FileStore {
	return FileStore{path: path, mu: &sync.Mutex{}, secrets: secrets}
}
func (store FileStore) WithInventorySeed(seed string) FileStore {
	store.inventorySeed = seed
	return store
}
func (store FileStore) Binding(id ConnectionID) (Binding, bool) {
	return uniqueBinding(store.ListBindings(), id)
}
func (store FileStore) BindingKey(key BindingKey) (Binding, bool) {
	for _, b := range store.ListBindings() {
		if b.Key() == key {
			return b, true
		}
	}
	return Binding{}, false
}
func (store FileStore) ListBindings() []Binding {
	store.mu.Lock()
	defer store.mu.Unlock()
	state, err := store.read()
	if err != nil {
		return nil
	}
	for i, b := range state.Bindings {
		state.Bindings[i] = loadBindingSecretsWith(store.secrets, b)
		state.Bindings[i].InventorySeed = store.inventorySeed
	}
	return state.Bindings
}
func (store FileStore) SaveBinding(b Binding) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	state, err := store.read()
	if err != nil {
		return err
	}
	persisted, err := storeBindingSecretsWith(store.secrets, b)
	if err != nil {
		return err
	}
	state.Bindings = upsertBinding(state.Bindings, persisted)
	return store.write(state)
}
func (store FileStore) DeleteBinding(id ConnectionID) error {
	b, ok := store.Binding(id)
	if !ok {
		return fmt.Errorf("binding missing or ambiguous")
	}
	return store.DeleteBindingKey(b.Key())
}
func (store FileStore) DeleteBindingKey(key BindingKey) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	state, err := store.read()
	if err != nil {
		return err
	}
	var removed *Binding
	for _, b := range state.Bindings {
		if b.Key() == key {
			copy := b
			removed = &copy
			break
		}
	}
	state.Bindings = removeBinding(state.Bindings, key)
	err = store.write(state)
	if err != nil {
		return err
	}
	if removed != nil {
		return deleteBindingSecretsWith(store.secrets, *removed)
	}
	return nil
}
func (store FileStore) read() (State, error) {
	info, err := os.Lstat(store.path)
	if os.IsNotExist(err) {
		return State{}, nil
	}
	if err != nil {
		return State{}, fmt.Errorf("inspect bridge state: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || !fileOwned(info) {
		return State{}, fmt.Errorf("unsafe bridge state file")
	}
	raw, err := os.ReadFile(store.path)
	if err != nil {
		return State{}, fmt.Errorf("read bridge state: %w", err)
	}
	var state State
	err = json.Unmarshal(raw, &state)
	if err != nil {
		return State{}, fmt.Errorf("decode bridge state: %w", err)
	}
	return state, nil
}
func (store FileStore) write(state State) error {
	dir := filepath.Dir(store.path)
	err := os.MkdirAll(dir, 0o700)
	if err != nil {
		return fmt.Errorf("create bridge state directory: %w", err)
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return fmt.Errorf("inspect bridge directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("unsafe bridge directory")
	}
	raw, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("encode bridge state: %w", err)
	}
	err = os.WriteFile(store.path, raw, 0o600)
	if err != nil {
		return fmt.Errorf("write bridge state: %w", err)
	}
	return nil
}

func fileOwned(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Geteuid()
}

// UpdateBinding serializes an in-process binding mutation against the sole store writer.
// It does not add a cross-store transaction or crash-recovery guarantee.
type MutationStore interface {
	UpdateBinding(BindingKey, func(*Binding) error) error
}

func UpdateBinding(store Store, reference Binding, change func(*Binding) error) error {
	if mutations, ok := store.(MutationStore); ok {
		return mutations.UpdateBinding(reference.Key(), change)
	}
	writer, ok := store.(WritableStore)
	if !ok {
		return fmt.Errorf("writable binding store required")
	}
	b, ok := BindingFor(store, reference)
	if !ok {
		return fmt.Errorf("binding not found")
	}
	if err := change(&b); err != nil {
		return err
	}
	return writer.SaveBinding(b)
}
func (store *MemoryStore) UpdateBinding(key BindingKey, change func(*Binding) error) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	for i, b := range store.state.Bindings {
		if b.Key() != key {
			continue
		}
		if err := change(&b); err != nil {
			return err
		}
		store.state.Bindings[i] = b
		return nil
	}
	return fmt.Errorf("binding not found")
}
func (store FileStore) UpdateBinding(key BindingKey, change func(*Binding) error) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	state, err := store.read()
	if err != nil {
		return err
	}
	for i, b := range state.Bindings {
		if b.Key() != key {
			continue
		}
		b = loadBindingSecretsWith(store.secrets, b)
		b.InventorySeed = store.inventorySeed
		if err = change(&b); err != nil {
			return err
		}
		state.Bindings[i], err = storeBindingSecretsWith(store.secrets, b)
		if err != nil {
			return err
		}
		return store.write(state)
	}
	return fmt.Errorf("binding not found")
}
