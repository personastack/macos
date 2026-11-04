package control

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/localcluster"
	"github.com/personastack/macos/agent-bridge/internal/pairing"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
)

type unavailableCredentialStore struct{ calls atomic.Int32 }

func (s *unavailableCredentialStore) Binding(config.ConnectionID) (config.Binding, bool) {
	s.calls.Add(1)
	return config.Binding{}, false
}
func (s *unavailableCredentialStore) ListBindings() []config.Binding {
	s.calls.Add(1)
	return nil
}
func (s *unavailableCredentialStore) SaveBinding(config.Binding) error {
	s.calls.Add(1)
	return errors.New("unplanned protected mutation")
}

func unavailableCredentialsFixture(t *testing.T) (*Controller, *unavailableCredentialStore, *atomic.Int32) {
	t.Helper()
	store := &unavailableCredentialStore{}
	calls := &atomic.Int32{}
	controller := &Controller{
		ExternalCredentialsUnavailable: true,
		Store:                          store,
		Environments:                   func() ([]Environment, error) { calls.Add(1); return nil, nil },
		Discover:                       func(runtime.AdapterKind, string) ([]targetinventory.Profile, []error) { calls.Add(1); return nil, nil },
		Exchange: func(context.Context, Environment, pairing.Request) (pairing.Result, error) {
			calls.Add(1)
			return pairing.Result{}, nil
		},
		Check: func(context.Context, config.Binding) (runtime.Detection, error) {
			calls.Add(1)
			return runtime.Detection{}, nil
		},
		Repair:   func(context.Context, config.Binding, bool, bool, bool) error { calls.Add(1); return nil },
		Cleanup:  func(config.Binding) error { calls.Add(1); return nil },
		Stop:     func() error { calls.Add(1); return nil },
		Shutdown: func() { calls.Add(1) },
	}
	t.Cleanup(func() {
		if store.calls.Load() != 0 || calls.Load() != 0 {
			t.Errorf("unavailable credential fence made protected calls: store=%d callbacks=%d", store.calls.Load(), calls.Load())
		}
		if controller.preparations != nil {
			t.Error("credential fence initialized external preparation state")
		}
	})
	return controller, store, calls
}

func TestUnavailableExternalCredentialsStatusPreservesLocalCapabilityWithoutInventory(t *testing.T) {
	t.Parallel()
	controller, _, _ := unavailableCredentialsFixture(t)
	manager, err := localcluster.NewManager(context.Background(), &lifecycleWorkflow{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	controller.LocalCluster = manager
	controller.mu.Lock()
	defer controller.mu.Unlock()
	response := dispatchCluster(t, controller, "status", BindingPayload{})
	if response.Error != nil || response.Result == nil || response.Result.ExternalError == nil || response.Result.ExternalError.Code != "credential_unavailable" || response.Result.ExternalError.Message != externalCredentialsMessage || response.Result.LocalClusterControlVersion != LocalClusterControlVersion || response.Result.Connections != nil {
		t.Fatalf("unavailable status contract: %+v", response)
	}
	raw, err := json.Marshal(response.Result)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"local_cluster_control_version":1,"external_error":{"code":"credential_unavailable","message":"External runtime credentials are unavailable. Restore login Keychain access, then sign out of macOS and sign back in to reconnect external agents."}}`
	if string(raw) != want {
		t.Fatalf("status claimed external inventory or lost private capability: %s", raw)
	}
}

func TestUnavailableExternalCredentialsDenyExternalOperationsBeforeProtectedAccess(t *testing.T) {
	t.Parallel()
	for _, operation := range []string{"discover", "prepare", "enroll", "check", "repair", "disconnect", "quiesce", "resume", "stop_background"} {
		t.Run(operation, func(t *testing.T) {
			t.Parallel()
			controller, _, _ := unavailableCredentialsFixture(t)
			response := dispatchCluster(t, controller, operation, struct{}{})
			if response.Error == nil || response.Error.Code != "credential_unavailable" || response.Error.Message != externalCredentialsMessage || response.Result != nil {
				t.Fatalf("external operation bypassed credential fence: %+v", response)
			}
		})
	}
}

func TestUnavailableExternalCredentialsStatusStillValidatesItsPayload(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name    string
		payload json.RawMessage
		code    string
	}{
		{"unknown", json.RawMessage(`{"unknown":true}`), "invalid_request"},
		{"wrong binding type", json.RawMessage(`{"binding_key":"not-a-target"}`), "invalid_request"},
		{"unknown target field", json.RawMessage(`{"binding_key":{"unknown":true}}`), "invalid_request"},
		{"array", json.RawMessage(`[]`), "invalid_request"},
		{"binding target", json.RawMessage(`{"binding_key":{"environment_id":"https://app.test","connection_id":"connection"}}`), "credential_unavailable"},
		{"empty binding target", json.RawMessage(`{"binding_key":{}}`), "credential_unavailable"},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			controller, _, _ := unavailableCredentialsFixture(t)
			response := dispatchCluster(t, controller, "status", test.payload)
			if response.Error == nil || response.Error.Code != test.code || response.Result != nil {
				t.Fatalf("invalid/targeted status accepted: %+v", response)
			}
		})
	}
}

func TestUnavailableExternalCredentialsDoNotBlockLocalStatusOrInstall(t *testing.T) {
	t.Parallel()
	controller, _, _ := unavailableCredentialsFixture(t)
	var installs atomic.Int32
	workflow := &lifecycleWorkflow{install: func(context.Context, localcluster.Scope, func(localcluster.Progress)) error {
		installs.Add(1)
		return nil
	}}
	manager, err := localcluster.NewManager(context.Background(), workflow, nil)
	if err != nil {
		t.Fatal(err)
	}
	controller.LocalCluster = manager
	scope := clusterScope()
	status := dispatchCluster(t, controller, "local_cluster_status", LocalClusterAttemptPayload{Scope: scope})
	if status.Error != nil || status.Result == nil || status.Result.LocalCluster.State != localcluster.StateNoTask {
		t.Fatal("external credentials blocked independent scoped local status")
	}
	runtimeStatus := dispatchCluster(t, controller, "local_cluster_runtime_status", struct{}{})
	if runtimeStatus.Error != nil || runtimeStatus.Result == nil || runtimeStatus.Result.LocalClusterRuntime == nil {
		t.Fatal("external credentials blocked generic local runtime observation")
	}
	started := dispatchCluster(t, controller, "local_cluster_start", LocalClusterStartPayload{Scope: scope})
	if started.Error != nil || started.Result == nil || started.Result.LocalCluster.Operation != localcluster.OperationInstall {
		t.Fatal("external credentials blocked independent local installer")
	}
	awaitClusterIdle(t, manager)
	if installs.Load() != 1 {
		t.Fatal("local installer was not invoked exactly once")
	}
}

func TestUnavailableExternalCredentialsCannotTurnExpiredStatusIntoSuccess(t *testing.T) {
	t.Parallel()
	controller, _, _ := unavailableCredentialsFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	response := controller.Dispatch(ctx, deadlineRequest(t, "status", BindingPayload{}))
	if response.Error == nil || response.Error.Code != "operation_timeout" || response.Result != nil {
		t.Fatal("expired external status advertised successful observation")
	}
}

func TestUnavailableExternalStatusOmitsCapabilityWhenLocalOwnerIsUninitialized(t *testing.T) {
	t.Parallel()
	controller, _, _ := unavailableCredentialsFixture(t)
	response := dispatchCluster(t, controller, "status", BindingPayload{})
	if response.Error != nil || response.Result == nil || response.Result.ExternalError == nil {
		t.Fatal("unfiltered status did not expose finite external error")
	}
	raw, err := json.Marshal(response.Result)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "connections") || strings.Contains(string(raw), "local_cluster_control_version") {
		t.Fatalf("unknown inventory/private capability was invented: %s", raw)
	}
}
