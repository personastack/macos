package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/personastack/macos/agent-bridge/internal/localcluster"
)

type localClusterWorkflowFunc func(context.Context, localcluster.Scope, func(localcluster.Progress)) error

func (f localClusterWorkflowFunc) Install(ctx context.Context, scope localcluster.Scope, report func(localcluster.Progress)) error {
	return f(ctx, scope, report)
}

func clusterScope() localcluster.Scope {
	return localcluster.Scope{AppOrigin: "https://app.test", AccountID: "opaque-account", WorkspaceID: "opaque-workspace", DocumentID: uuid.NewString()}
}

func dispatchCluster(t *testing.T, c *Controller, operation string, payload interface{}) Response {
	t.Helper()
	responses := make(chan Response, 1)
	raw := deadlineRequest(t, operation, payload)
	go func() { responses <- c.Dispatch(context.Background(), raw) }()
	select {
	case response := <-responses:
		return response
	case <-time.After(time.Second):
		t.Fatal("local task control waited for legacy lock or installer")
	}
	return Response{}
}

func TestLocalClusterControlDoesNotHoldLegacyLockOrRequestLifetime(t *testing.T) {
	t.Parallel()
	parent, stopHelper := context.WithCancel(context.Background())
	t.Cleanup(stopHelper)
	calls := make(chan context.Context, 1)
	release := make(chan struct{})
	var stopOnce sync.Once
	t.Cleanup(func() { stopOnce.Do(func() { close(release) }) })
	manager, err := localcluster.NewManager(parent, localClusterWorkflowFunc(func(ctx context.Context, _ localcluster.Scope, report func(localcluster.Progress)) error {
		calls <- ctx
		<-ctx.Done()
		<-release
		return ctx.Err()
	}), nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	controller.mu.Lock()
	defer controller.mu.Unlock()
	scope := clusterScope()
	response := dispatchCluster(t, controller, "local_cluster_start", LocalClusterStartPayload{Scope: scope})
	if response.Error != nil || response.Result == nil || response.Result.LocalCluster == nil {
		t.Fatalf("start: %+v", response)
	}
	attempt := response.Result.LocalCluster.AttemptID
	var workflowContext context.Context
	select {
	case workflowContext = <-calls:
	case <-time.After(time.Second):
		t.Fatal("workflow did not start")
	}
	_, hasDeadline := workflowContext.Deadline()
	if hasDeadline || workflowContext.Err() != nil {
		t.Fatal("installer inherited finite request lifetime")
	}
	reopened := scope
	reopened.DocumentID = uuid.NewString()
	status := dispatchCluster(t, controller, "local_cluster_status", LocalClusterAttemptPayload{Scope: reopened, AttemptID: attempt})
	if status.Error != nil || status.Result.LocalCluster.AttemptID != attempt {
		t.Fatal("new same-owner document could not observe task")
	}
	cancelled := dispatchCluster(t, controller, "local_cluster_cancel", LocalClusterAttemptPayload{Scope: reopened, AttemptID: attempt})
	if cancelled.Error != nil || cancelled.Result.LocalCluster.State != localcluster.StateCancelling {
		t.Fatal("control acknowledged cancellation before workflow stopped")
	}
	select {
	case <-workflowContext.Done():
	default:
		t.Fatal("control did not request cancellation")
	}
	encoded, err := json.Marshal(cancelled)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"local_cluster":`) || strings.Contains(string(encoded), `"connections"`) || strings.Contains(string(encoded), "api_connected") {
		t.Fatalf("unexpected dedicated control DTO: %s", encoded)
	}
}

func TestLocalClusterControlRejectsUnsafeInputsWithoutWorkflowSideEffects(t *testing.T) {
	t.Parallel()
	var calls atomic.Int32
	manager, err := localcluster.NewManager(context.Background(), localClusterWorkflowFunc(func(context.Context, localcluster.Scope, func(localcluster.Progress)) error { calls.Add(1); return nil }), nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	for _, test := range []struct {
		operation string
		payload   json.RawMessage
		code      string
	}{
		{"local_cluster_start", json.RawMessage(`{"scope":{},"command":"uname -a"}`), "invalid_request"},
		{"local_cluster_start", json.RawMessage(`{"scope":{}}`), "invalid_request"},
		{"local_cluster_start", json.RawMessage(`{"scope":{},"url":"https://untrusted.test"}`), "invalid_request"},
		{"local_cluster_status", json.RawMessage(`{"scope":{},"attempt_id":"invalid"}`), "invalid_request"},
		{"local_cluster_status", json.RawMessage(`{"scope":{},"attempt_id":"invalid","path":"/tmp/untrusted"}`), "invalid_request"},
		{"local_cluster_cancel", json.RawMessage(`{"scope":{},"attempt_id":"invalid"}`), "invalid_request"},
	} {
		t.Run(test.operation+string(test.payload), func(t *testing.T) {
			t.Parallel()
			response := dispatchCluster(t, controller, test.operation, test.payload)
			if response.Error == nil || response.Error.Code != test.code || response.Result != nil {
				t.Fatalf("unsafe input accepted: %+v", response)
			}
		})
	}
	t.Cleanup(func() {
		if calls.Load() != 0 {
			t.Error("invalid control invoked workflow")
		}
	})
}

func TestLocalClusterControlUnavailableByDefaultAndCrossOwnerRedacted(t *testing.T) {
	t.Parallel()
	scope := clusterScope()
	for _, operation := range []string{"local_cluster_start", "local_cluster_status", "local_cluster_cancel"} {
		var payload interface{} = LocalClusterAttemptPayload{Scope: scope, AttemptID: uuid.NewString()}
		if operation == "local_cluster_start" {
			payload = LocalClusterStartPayload{Scope: scope}
		}
		response := dispatchCluster(t, &Controller{}, operation, payload)
		if response.Error == nil || response.Error.Code != "runtime_unsupported" || response.Result != nil {
			t.Fatalf("default helper claimed cluster support: %+v", response)
		}
	}
	parent, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	manager, err := localcluster.NewManager(parent, localClusterWorkflowFunc(func(ctx context.Context, _ localcluster.Scope, _ func(localcluster.Progress)) error {
		<-ctx.Done()
		return ctx.Err()
	}), nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	start := dispatchCluster(t, controller, "local_cluster_start", LocalClusterStartPayload{Scope: scope})
	if start.Error != nil {
		t.Fatal(start.Error)
	}
	foreign := scope
	foreign.AccountID = "other"
	for _, operation := range []string{"local_cluster_start", "local_cluster_status", "local_cluster_cancel"} {
		var payload interface{} = LocalClusterAttemptPayload{Scope: foreign, AttemptID: start.Result.LocalCluster.AttemptID}
		if operation == "local_cluster_start" {
			payload = LocalClusterStartPayload{Scope: foreign}
		}
		response := dispatchCluster(t, controller, operation, payload)
		if response.Error == nil || response.Error.Code != "runtime_occupied" || response.Result != nil || response.Error.Message != "Managed local cluster setup is occupied." {
			t.Fatalf("cross-owner response leaked private task: %+v", response)
		}
	}
}

func TestLocalClusterControlExpiredRequestDoesNotStartTask(t *testing.T) {
	t.Parallel()
	var calls atomic.Int32
	manager, err := localcluster.NewManager(context.Background(), localClusterWorkflowFunc(func(context.Context, localcluster.Scope, func(localcluster.Progress)) error { calls.Add(1); return nil }), nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	response := controller.Dispatch(ctx, deadlineRequest(t, "local_cluster_start", LocalClusterStartPayload{Scope: clusterScope()}))
	if response.Error == nil || response.Error.Code != "operation_timeout" || calls.Load() != 0 {
		t.Fatal("expired request started task")
	}
}

func TestLocalClusterControlStaleAttemptIsRejected(t *testing.T) {
	t.Parallel()
	parent, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	manager, err := localcluster.NewManager(parent, localClusterWorkflowFunc(func(ctx context.Context, _ localcluster.Scope, _ func(localcluster.Progress)) error {
		<-ctx.Done()
		return ctx.Err()
	}), nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	scope := clusterScope()
	start := dispatchCluster(t, controller, "local_cluster_start", LocalClusterStartPayload{Scope: scope})
	if start.Error != nil {
		t.Fatal(start.Error)
	}
	for _, operation := range []string{"local_cluster_status", "local_cluster_cancel"} {
		response := dispatchCluster(t, controller, operation, LocalClusterAttemptPayload{Scope: scope, AttemptID: uuid.NewString()})
		if response.Error == nil || response.Error.Code != "attempt_changed" || response.Result != nil {
			t.Fatal("stale control attempt was accepted")
		}
	}
}

func TestLocalClusterControlPassiveReopenAndNoTaskStatus(t *testing.T) {
	t.Parallel()
	parent, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	calls := make(chan struct{}, 1)
	manager, err := localcluster.NewManager(parent, localClusterWorkflowFunc(func(ctx context.Context, _ localcluster.Scope, _ func(localcluster.Progress)) error {
		calls <- struct{}{}
		<-ctx.Done()
		return ctx.Err()
	}), nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	scope := clusterScope()
	status := dispatchCluster(t, controller, "local_cluster_status", LocalClusterAttemptPayload{Scope: scope})
	if status.Error != nil || status.Result == nil || status.Result.LocalCluster.State != localcluster.StateNoTask {
		t.Fatalf("passive no-task lookup failed: %+v", status)
	}
	raw, err := json.Marshal(status.Result)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != `{"local_cluster":{"state":"no_task","action":"none"}}` {
		t.Fatalf("no-task DTO claimed installation state: %s", raw)
	}
	select {
	case <-calls:
		t.Fatal("passive no-task lookup invoked installer")
	default:
	}
	start := dispatchCluster(t, controller, "local_cluster_start", LocalClusterStartPayload{Scope: scope})
	if start.Error != nil {
		t.Fatal(start.Error)
	}
	select {
	case <-calls:
	case <-time.After(time.Second):
		t.Fatal("installer did not start")
	}
	reopened := scope
	reopened.DocumentID = uuid.NewString()
	status = dispatchCluster(t, controller, "local_cluster_status", LocalClusterAttemptPayload{Scope: reopened})
	if status.Error != nil || status.Result.LocalCluster.AttemptID != start.Result.LocalCluster.AttemptID || status.Result.LocalCluster.Scope.DocumentID != scope.DocumentID {
		t.Fatal("passive reopen did not retain original attempt metadata")
	}
	foreign := reopened
	foreign.WorkspaceID = "another-workspace"
	denied := dispatchCluster(t, controller, "local_cluster_status", LocalClusterAttemptPayload{Scope: foreign})
	if denied.Error == nil || denied.Error.Code != "runtime_occupied" || denied.Result != nil {
		t.Fatal("passive lookup disclosed foreign task")
	}
	denied = dispatchCluster(t, controller, "local_cluster_cancel", LocalClusterAttemptPayload{Scope: reopened})
	if denied.Error == nil || denied.Error.Code != "invalid_request" || denied.Result != nil {
		t.Fatal("cancel accepted an omitted attempt")
	}
	status = dispatchCluster(t, controller, "local_cluster_status", LocalClusterAttemptPayload{Scope: reopened})
	if status.Error != nil || status.Result.LocalCluster.State != localcluster.StateRunning {
		t.Fatal("invalid cancellation changed current work")
	}
	select {
	case <-calls:
		t.Fatal("passive reopen started another installer")
	default:
	}
	unsupported := dispatchCluster(t, &Controller{}, "local_cluster_status", LocalClusterAttemptPayload{Scope: scope})
	if unsupported.Error == nil || unsupported.Error.Code != "runtime_unsupported" || unsupported.Result != nil {
		t.Fatal("uninitialized workflow claimed no-task support")
	}
}

type lifecycleWorkflow struct {
	install  func(context.Context, localcluster.Scope, func(localcluster.Progress)) error
	probe    func(context.Context, localcluster.Scope) (localcluster.RuntimeStatus, error)
	resume   func(context.Context, localcluster.Scope) error
	stop     func(context.Context) error
	apply    func(context.Context, localcluster.Scope, localcluster.TargetBinding, []byte) error
	binding  func(context.Context, localcluster.Scope) (localcluster.TargetBindingStatus, error)
	remove   func(context.Context, localcluster.Scope, localcluster.TargetBinding) error
	newSetup func(context.Context, localcluster.Scope, localcluster.TargetBinding) error
}

func (f *lifecycleWorkflow) Install(ctx context.Context, scope localcluster.Scope, report func(localcluster.Progress)) error {
	if f.install == nil {
		return nil
	}
	return f.install(ctx, scope, report)
}
func (f *lifecycleWorkflow) Probe(ctx context.Context, scope localcluster.Scope) (localcluster.RuntimeStatus, error) {
	if f.probe == nil {
		return localcluster.RuntimeStatus{}, nil
	}
	return f.probe(ctx, scope)
}
func (f *lifecycleWorkflow) Start(ctx context.Context, scope localcluster.Scope) error {
	if f.resume == nil {
		return nil
	}
	return f.resume(ctx, scope)
}
func (f *lifecycleWorkflow) Stop(ctx context.Context) error {
	if f.stop == nil {
		return nil
	}
	return f.stop(ctx)
}
func (f *lifecycleWorkflow) ApplyManifest(ctx context.Context, scope localcluster.Scope, binding localcluster.TargetBinding, manifest []byte) error {
	if f.apply == nil {
		return nil
	}
	return f.apply(ctx, scope, binding, manifest)
}

func (f *lifecycleWorkflow) Binding(ctx context.Context, scope localcluster.Scope) (localcluster.TargetBindingStatus, error) {
	if f.binding == nil {
		return localcluster.TargetBindingStatus{}, errors.New("unexpected binding read")
	}
	return f.binding(ctx, scope)
}
func (f *lifecycleWorkflow) RemoveData(ctx context.Context, scope localcluster.Scope, binding localcluster.TargetBinding) error {
	if f.remove == nil {
		return errors.New("unexpected remove")
	}
	return f.remove(ctx, scope, binding)
}
func (f *lifecycleWorkflow) NewSetupAfterRemoval(ctx context.Context, scope localcluster.Scope, binding localcluster.TargetBinding) error {
	if f.newSetup == nil {
		return errors.New("unexpected new setup")
	}
	return f.newSetup(ctx, scope, binding)
}

func awaitClusterIdle(t *testing.T, manager *localcluster.Manager) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for manager.Active() {
		if time.Now().After(deadline) {
			t.Fatal("local task did not exit")
		}
		runtime.Gosched()
	}
}

func TestLocalClusterMachineControlIsScopeFreeAndAsynchronous(t *testing.T) {
	t.Parallel()
	parent, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	stopStarted := make(chan context.Context, 1)
	release := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	var probes atomic.Int32
	workflow := &lifecycleWorkflow{
		probe: func(ctx context.Context, scope localcluster.Scope) (localcluster.RuntimeStatus, error) {
			probes.Add(1)
			if scope != (localcluster.Scope{}) {
				t.Error("machine probe received cloud owner scope")
			}
			return localcluster.RuntimeStatus{Installed: true, Running: true, KubernetesAvailable: true, Enabled: true}, nil
		},
		stop: func(ctx context.Context) error { stopStarted <- ctx; <-release; return nil },
	}
	manager, err := localcluster.NewManager(parent, workflow, nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	status := dispatchCluster(t, controller, "local_cluster_runtime_status", struct{}{})
	if status.Error != nil || status.Result.LocalClusterRuntime == nil || !status.Result.LocalClusterRuntime.Enabled {
		t.Fatalf("machine observation: %+v", status)
	}
	raw, err := json.Marshal(status.Result)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "local_cluster") || strings.Contains(string(raw), "scope") || !strings.Contains(string(raw), `"kubernetes_available":true`) {
		t.Fatalf("machine status DTO not generic: %s", raw)
	}
	stop := dispatchCluster(t, controller, "local_cluster_runtime_stop", struct{}{})
	if stop.Error != nil {
		t.Fatal(stop.Error)
	}
	raw, err = json.Marshal(stop.Result)
	if err != nil || string(raw) != `{"active":true}` {
		t.Fatalf("stop leaked task owner: %s %v", raw, err)
	}
	select {
	case ctx := <-stopStarted:
		if _, ok := ctx.Deadline(); ok {
			t.Fatal("stop inherited request deadline")
		}
	case <-time.After(time.Second):
		t.Fatal("stop did not start")
	}
	status = dispatchCluster(t, controller, "local_cluster_runtime_status", struct{}{})
	if status.Error != nil || !status.Result.LocalClusterRuntime.InstallerActive || probes.Load() != 1 {
		t.Fatal("active stop blocked on runtime probe or appeared stopped")
	}
	denied := dispatchCluster(t, controller, "local_cluster_runtime_status", LocalClusterStartPayload{Scope: clusterScope()})
	if denied.Error == nil || denied.Error.Code != "invalid_request" {
		t.Fatal("generic machine status accepted owner metadata")
	}
}

func TestLocalClusterResumeAndApplyControlBoundaries(t *testing.T) {
	t.Parallel()
	parent, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	scope := clusterScope()
	resumed := make(chan localcluster.Scope, 2)
	applied := make(chan string, 1)
	workflow := &lifecycleWorkflow{
		resume: func(ctx context.Context, owner localcluster.Scope) error { resumed <- owner; return nil },
		apply: func(ctx context.Context, owner localcluster.Scope, binding localcluster.TargetBinding, manifest []byte) error {
			if owner != scope {
				t.Error("apply scope changed")
			}
			applied <- string(manifest)
			return nil
		},
	}
	manager, err := localcluster.NewManager(parent, workflow, nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	resume := dispatchCluster(t, controller, "local_cluster_runtime_resume", LocalClusterStartPayload{Scope: scope})
	if resume.Error != nil || resume.Result.LocalCluster == nil || resume.Result.LocalCluster.Operation != localcluster.OperationResume {
		t.Fatal("scoped resume missing task")
	}
	awaitClusterIdle(t, manager)
	select {
	case owner := <-resumed:
		if owner != scope {
			t.Fatal("scoped resume lost owner")
		}
	default:
		t.Fatal("resume was not called")
	}
	payload := LocalClusterApplyPayload{Scope: scope, AttemptID: resume.Result.LocalCluster.AttemptID, Manifest: "private native manifest", Binding: localcluster.TargetBinding{IntegrationID: "cluster-one", InstallationID: strings.Repeat("a", 64)}}
	apply := dispatchCluster(t, controller, "local_cluster_apply", payload)
	if apply.Error != nil || apply.Result.LocalCluster.Operation != localcluster.OperationApply {
		t.Fatalf("apply: %+v", apply)
	}
	awaitClusterIdle(t, manager)
	select {
	case manifest := <-applied:
		if manifest != payload.Manifest {
			t.Fatal("apply manifest changed")
		}
	default:
		t.Fatal("apply was not called")
	}
	raw, err := json.Marshal(apply)
	if err != nil || strings.Contains(string(raw), payload.Manifest) {
		t.Fatal("control response exposed manifest")
	}
	payload.Manifest = strings.Repeat("a", localcluster.MaxManifestBytes+1)
	denied := dispatchCluster(t, controller, "local_cluster_apply", payload)
	if denied.Error == nil || denied.Error.Code != "invalid_request" {
		t.Fatal("oversized manifest accepted")
	}
	local := dispatchCluster(t, controller, "local_cluster_runtime_resume", struct{}{})
	if local.Error != nil {
		t.Fatal(local.Error)
	}
	raw, err = json.Marshal(local.Result)
	if err != nil || string(raw) != `{"active":true}` {
		t.Fatal("local resume exposed scoped task")
	}
	awaitClusterIdle(t, manager)
	select {
	case owner := <-resumed:
		if owner != (localcluster.Scope{}) {
			t.Fatal("offline resume invented cloud scope")
		}
	default:
		t.Fatal("offline resume was not called")
	}
	status := dispatchCluster(t, controller, "local_cluster_status", LocalClusterAttemptPayload{Scope: scope})
	if status.Error != nil || status.Result == nil || status.Result.LocalCluster.State != localcluster.StateNoTask {
		t.Fatal("terminal machine task prevented scoped observation or became enrollment authority")
	}
}

func TestLocalClusterBindingAndRemovalRemainNativeScoped(t *testing.T) {
	t.Parallel()
	parent, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	scope := clusterScope()
	target := localcluster.TargetBinding{IntegrationID: "private-target", InstallationID: strings.Repeat("a", 64)}
	var reads, removes, resets atomic.Int32
	workflow := &lifecycleWorkflow{
		binding: func(ctx context.Context, owner localcluster.Scope) (localcluster.TargetBindingStatus, error) {
			reads.Add(1)
			if owner != scope {
				return localcluster.TargetBindingStatus{}, errors.New("unplanned protected binding read")
			}
			return localcluster.TargetBindingStatus{Binding: &target}, nil
		},
		remove: func(ctx context.Context, owner localcluster.Scope, binding localcluster.TargetBinding) error {
			if owner != scope || binding != target {
				return errors.New("unplanned remove target")
			}
			removes.Add(1)
			return nil
		},
		newSetup: func(ctx context.Context, owner localcluster.Scope, binding localcluster.TargetBinding) error {
			if owner != scope || binding != target || removes.Load() != 1 {
				return errors.New("unplanned new setup")
			}
			resets.Add(1)
			return nil
		},
	}
	manager, err := localcluster.NewManager(parent, workflow, nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	resume := dispatchCluster(t, controller, "local_cluster_runtime_resume", LocalClusterStartPayload{Scope: scope})
	if resume.Error != nil {
		t.Fatal(resume.Error)
	}
	awaitClusterIdle(t, manager)
	binding := dispatchCluster(t, controller, "local_cluster_binding", LocalClusterStartPayload{Scope: scope})
	if binding.Error != nil || binding.Result.LocalClusterBinding == nil || binding.Result.LocalClusterBinding.Binding == nil || *binding.Result.LocalClusterBinding.Binding != target {
		t.Fatal("native binding read lost target")
	}
	raw, err := json.Marshal(binding.Result)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"binding":{"integration_id":"private-target"`) || strings.Contains(string(raw), "scope") || strings.Contains(string(raw), "local_cluster") {
		t.Fatalf("native binding DTO mismatch: %s", raw)
	}
	foreign := scope
	foreign.AccountID = "foreign"
	denied := dispatchCluster(t, controller, "local_cluster_binding", LocalClusterStartPayload{Scope: foreign})
	if denied.Error == nil || denied.Error.Code != "runtime_occupied" || denied.Result != nil || reads.Load() != 1 {
		t.Fatal("foreign scope performed protected target read")
	}
	invalid := target
	invalid.InstallationID = "invalid"
	denied = dispatchCluster(t, controller, "local_cluster_remove", LocalClusterTargetPayload{Scope: scope, Binding: invalid})
	if denied.Error == nil || denied.Error.Code != "invalid_request" || removes.Load() != 0 {
		t.Fatal("invalid binding performed remove")
	}
	denied = dispatchCluster(t, controller, "local_cluster_remove", LocalClusterTargetPayload{Scope: foreign, Binding: target})
	if denied.Error == nil || denied.Error.Code != "runtime_occupied" || removes.Load() != 0 {
		t.Fatal("foreign scope performed remove")
	}
	removed := dispatchCluster(t, controller, "local_cluster_remove", LocalClusterTargetPayload{Scope: scope, Binding: target})
	if removed.Error != nil || removed.Result.LocalCluster.Operation != localcluster.OperationRemove {
		t.Fatal("remove missing async task")
	}
	awaitClusterIdle(t, manager)
	raw, err = json.Marshal(removed.Result)
	if err != nil || strings.Contains(string(raw), target.IntegrationID) || strings.Contains(string(raw), target.InstallationID) {
		t.Fatal("task snapshot disclosed native target binding")
	}
	blank := dispatchCluster(t, controller, "local_cluster_new_setup", LocalClusterTargetPayload{Scope: scope, Binding: target})
	if blank.Error != nil || blank.Result.LocalCluster.Operation != localcluster.OperationNewSetup {
		t.Fatal("new setup missing async task")
	}
	awaitClusterIdle(t, manager)
	if removes.Load() != 1 || resets.Load() != 1 {
		t.Fatal("native target mutation count changed")
	}
}

func TestLocalClusterVersionSerializationPreservesLegacyStatusContract(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name      string
		operation string
		version   int
		expected  string
	}{
		{"legacy status", "status", 0, `{"connections":[]}`},
		{"private implementation", "status", LocalClusterControlVersion, `{"connections":[],"local_cluster_control_version":1}`},
		{"check unchanged", "check", LocalClusterControlVersion, `{"connections":[]}`},
		{"repair unchanged", "repair", LocalClusterControlVersion, `{"connections":[]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			raw, err := json.Marshal(Result{Operation: test.operation, LocalClusterControlVersion: test.version})
			if err != nil || string(raw) != test.expected {
				t.Fatalf("status compatibility changed: %s %v", raw, err)
			}
		})
	}
}

func TestLocalClusterVersionAdvertisesOnlyInitializedPrivateController(t *testing.T) {
	t.Parallel()
	for _, enabled := range []bool{false, true} {
		t.Run(fmt.Sprint(enabled), func(t *testing.T) {
			t.Parallel()
			controller, _, _ := fixture(t)
			var installs atomic.Int32
			if enabled {
				manager, err := localcluster.NewManager(context.Background(), localClusterWorkflowFunc(func(context.Context, localcluster.Scope, func(localcluster.Progress)) error {
					installs.Add(1)
					return nil
				}), nil)
				if err != nil {
					t.Fatal(err)
				}
				controller.LocalCluster = manager
			}
			response := dispatchCluster(t, controller, "status", BindingPayload{})
			if response.Error != nil || response.Result == nil {
				t.Fatalf("existing status failed: %+v", response)
			}
			want := 0
			if enabled {
				want = LocalClusterControlVersion
			}
			if response.Result.LocalClusterControlVersion != want || installs.Load() != 0 {
				t.Fatal("status inferred product readiness or ran setup")
			}
			raw, err := json.Marshal(response.Result)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(raw), "local_cluster_control_version") != enabled {
				t.Fatalf("private IPC capability availability incorrect: %s", raw)
			}
		})
	}
}

func TestLocalClusterMachineRemoveAcceptsOnlyGenericNativeAction(t *testing.T) {
	t.Parallel()
	parent, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	var calls atomic.Int32
	workflow := &lifecycleWorkflow{remove: func(ctx context.Context, scope localcluster.Scope, binding localcluster.TargetBinding) error {
		if scope != (localcluster.Scope{}) || binding != (localcluster.TargetBinding{}) {
			return errors.New("machine removal accepted caller target")
		}
		calls.Add(1)
		return nil
	}}
	manager, err := localcluster.NewManager(parent, workflow, nil)
	if err != nil {
		t.Fatal(err)
	}
	controller := &Controller{LocalCluster: manager}
	foreign := localcluster.TargetBinding{IntegrationID: "foreign", InstallationID: strings.Repeat("b", 64)}
	denied := dispatchCluster(t, controller, "local_cluster_remove", LocalClusterTargetPayload{Binding: foreign})
	if denied.Error == nil || denied.Error.Code != "invalid_request" || calls.Load() != 0 {
		t.Fatal("generic removal accepted caller-chosen foreign binding")
	}
	accepted := dispatchCluster(t, controller, "local_cluster_remove", struct{}{})
	if accepted.Error != nil {
		t.Fatal(accepted.Error)
	}
	raw, err := json.Marshal(accepted.Result)
	if err != nil || string(raw) != `{"active":true}` {
		t.Fatal("machine removal disclosed owner")
	}
	awaitClusterIdle(t, manager)
	if calls.Load() != 1 {
		t.Fatal("machine removal call count wrong")
	}
}
