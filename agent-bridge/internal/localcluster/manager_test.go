package localcluster

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

type workflowCall struct {
	ctx    context.Context
	scope  Scope
	report func(Progress)
}

type controlledWorkflow struct {
	calls  chan workflowCall
	finish chan error
}

func (w *controlledWorkflow) Install(ctx context.Context, scope Scope, report func(Progress)) error {
	w.calls <- workflowCall{ctx, scope, report}
	return <-w.finish
}

func managerFixture(t *testing.T) (*Manager, *controlledWorkflow, Scope, *atomic.Int64) {
	t.Helper()
	parent, cancel := context.WithCancel(context.Background())
	workflow := &controlledWorkflow{calls: make(chan workflowCall, 2), finish: make(chan error, 1)}
	clock := &atomic.Int64{}
	clock.Store(100)
	manager, err := NewManager(parent, workflow, func() time.Time { return time.Unix(clock.Load(), 0) })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cancel()
		select {
		case workflow.finish <- context.Canceled:
		default:
		}
	})
	return manager, workflow, Scope{AppOrigin: "https://app.test", AccountID: "account:one", WorkspaceID: "workspace-one", DocumentID: uuid.NewString()}, clock
}

func awaitWorkflow(t *testing.T, workflow *controlledWorkflow) workflowCall {
	t.Helper()
	select {
	case call := <-workflow.calls:
		return call
	case <-time.After(time.Second):
		t.Fatal("installer was not scheduled")
	}
	return workflowCall{}
}

func awaitTask(t *testing.T, manager *Manager) {
	t.Helper()
	manager.mu.Lock()
	done := manager.task.done
	manager.mu.Unlock()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("installer did not stop")
	}
}

func TestManagerNativeProgressAndSuccessfulCompletion(t *testing.T) {
	t.Parallel()
	manager, workflow, scope, clock := managerFixture(t)
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	if started.State != StateRunning || started.Progress.Stage != StageQueued || started.Scope != scope ||
		started.StartedAt != time.Unix(100, 0).UTC() || started.UpdatedAt != started.StartedAt || !started.FinishedAt.IsZero() {
		t.Fatalf("unexpected initial snapshot: %+v", started)
	}
	call := awaitWorkflow(t, workflow)
	if call.scope != scope {
		t.Fatal("workflow lost original scope")
	}
	clock.Store(110)
	call.report(Progress{Stage: StageDownloading, CompletedBytes: 10, TotalBytes: 100})
	progress, err := manager.Status(scope, started.AttemptID)
	if err != nil || progress.Progress.CompletedBytes != 10 || progress.UpdatedAt != time.Unix(110, 0).UTC() {
		t.Fatalf("progress: %+v %v", progress, err)
	}
	for _, stage := range []Stage{StageVerifying, StageExtracting, StageStarting, StageChecking} {
		call.report(Progress{Stage: stage, CompletedBytes: 100, TotalBytes: 100})
	}
	clock.Store(120)
	workflow.finish <- nil
	awaitTask(t, manager)
	finished, err := manager.Status(scope, started.AttemptID)
	if err != nil || finished.State != StateInstalled || finished.Progress.Stage != StageCompleted ||
		finished.FinishedAt != time.Unix(120, 0).UTC() || finished.Action != ActionNone || finished.Reason != ReasonNone {
		t.Fatalf("completion: %+v %v", finished, err)
	}
	raw, err := json.Marshal(finished)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "ready") || strings.Contains(string(raw), "api_connected") {
		t.Fatal("native setup claimed cloud readiness")
	}
}

func TestManagerSameOwnerReopenAndCrossOwnerFences(t *testing.T) {
	t.Parallel()
	manager, workflow, scope, _ := managerFixture(t)
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	awaitWorkflow(t, workflow)
	reopened := scope
	reopened.DocumentID = uuid.NewString()
	repeated, err := manager.Start(reopened)
	if err != nil || repeated != started {
		t.Fatalf("new document lost same-owner attempt: %+v %v", repeated, err)
	}
	observed, err := manager.Status(reopened, started.AttemptID)
	if err != nil || observed.Scope.DocumentID != scope.DocumentID {
		t.Fatal("observation must preserve originating document metadata")
	}
	for _, field := range []string{"origin", "account", "workspace"} {
		t.Run(field, func(t *testing.T) {
			t.Parallel()
			foreign := scope
			switch field {
			case "origin":
				foreign.AppOrigin = "https://other.test"
			case "account":
				foreign.AccountID = "other"
			case "workspace":
				foreign.WorkspaceID = "other"
			}
			for _, operation := range []string{"start", "status", "cancel"} {
				var result Snapshot
				var err error
				switch operation {
				case "start":
					result, err = manager.Start(foreign)
				case "status":
					result, err = manager.Status(foreign, started.AttemptID)
				case "cancel":
					result, err = manager.Cancel(foreign, started.AttemptID)
				}
				if !errors.Is(err, ErrOccupied) || result != (Snapshot{}) {
					t.Fatalf("%s leaked owner data: %+v %v", operation, result, err)
				}
			}
		})
	}
}

func TestManagerCancelWaitsForWorkflowAndPreservesCancellingDuringProgress(t *testing.T) {
	t.Parallel()
	manager, workflow, scope, _ := managerFixture(t)
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	call := awaitWorkflow(t, workflow)
	for range 2 {
		cancelled, err := manager.Cancel(scope, started.AttemptID)
		if err != nil || cancelled.State != StateCancelling || !cancelled.FinishedAt.IsZero() {
			t.Fatalf("premature cancellation acknowledgement: %+v %v", cancelled, err)
		}
	}
	select {
	case <-call.ctx.Done():
	default:
		t.Fatal("workflow did not receive cancellation")
	}
	call.report(Progress{Stage: StageChecking})
	observed, err := manager.Status(scope, started.AttemptID)
	if err != nil || observed.State != StateCancelling {
		t.Fatal("progress erased pending cancellation")
	}
	repeated, err := manager.Start(scope)
	if err != nil || repeated.AttemptID != started.AttemptID {
		t.Fatal("new task overlapped stopping workflow")
	}
	workflow.finish <- call.ctx.Err()
	awaitTask(t, manager)
	observed, err = manager.Status(scope, started.AttemptID)
	if err != nil || observed.State != StateCancelled || observed.FinishedAt.IsZero() {
		t.Fatalf("stopped workflow not acknowledged: %+v %v", observed, err)
	}
}

func TestManagerCancelRacingSuccessReportsInstalled(t *testing.T) {
	t.Parallel()
	manager, workflow, scope, _ := managerFixture(t)
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	awaitWorkflow(t, workflow)
	_, err = manager.Cancel(scope, started.AttemptID)
	if err != nil {
		t.Fatal(err)
	}
	workflow.finish <- nil
	awaitTask(t, manager)
	observed, err := manager.Status(scope, started.AttemptID)
	if err != nil || observed.State != StateInstalled {
		t.Fatalf("successful work was labelled cancelled: %+v %v", observed, err)
	}
}

func TestManagerParentLifetimeCancellationRequiresWorkflowExit(t *testing.T) {
	t.Parallel()
	parent, cancel := context.WithCancel(context.Background())
	defer cancel()
	workflow := &controlledWorkflow{calls: make(chan workflowCall, 1), finish: make(chan error, 1)}
	manager, err := NewManager(parent, workflow, nil)
	if err != nil {
		t.Fatal(err)
	}
	_, _, scope, _ := managerFixture(t)
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	call := awaitWorkflow(t, workflow)
	cancel()
	select {
	case <-call.ctx.Done():
	default:
		t.Fatal("helper lifetime did not cancel workflow")
	}
	observed, err := manager.Status(scope, started.AttemptID)
	if err != nil || !observed.FinishedAt.IsZero() {
		t.Fatal("helper cancellation claimed stopped work before workflow exit")
	}
	workflow.finish <- call.ctx.Err()
	awaitTask(t, manager)
	observed, err = manager.Status(scope, started.AttemptID)
	if err != nil || observed.State != StateCancelled {
		t.Fatal("workflow exit was not acknowledged")
	}
	_, err = manager.Start(scope)
	if !errors.Is(err, ErrUnavailable) {
		t.Fatal("stopped helper accepted new task")
	}
}

func TestManagerAttemptAndLateCallbackFences(t *testing.T) {
	t.Parallel()
	manager, workflow, scope, _ := managerFixture(t)
	first, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	call := awaitWorkflow(t, workflow)
	workflow.finish <- nil
	awaitTask(t, manager)
	second, err := manager.Start(scope)
	if err != nil || first.AttemptID == second.AttemptID {
		t.Fatal("terminal task did not get a new attempt")
	}
	awaitWorkflow(t, workflow)
	call.report(Progress{Stage: StageChecking, CompletedBytes: 999})
	current, err := manager.Status(scope, second.AttemptID)
	if err != nil || current != second {
		t.Fatal("late old callback overwrote current attempt")
	}
	for _, operation := range []string{"status", "cancel"} {
		var result Snapshot
		if operation == "status" {
			result, err = manager.Status(scope, first.AttemptID)
		} else {
			result, err = manager.Cancel(scope, first.AttemptID)
		}
		if !errors.Is(err, ErrAttemptChanged) || result != (Snapshot{}) {
			t.Fatal("old attempt was accepted")
		}
	}
}

func TestManagerFiniteFailureGuidanceAndRedaction(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name   string
		err    error
		reason Reason
		action Action
	}{
		{"raw", errors.New("secret URL or bearer"), ReasonSetupFailed, ActionRetry},
		{"unknown", &Failure{Reason: "secret"}, ReasonSetupFailed, ActionRetry},
		{"artifact", &Failure{Reason: ReasonArtifactUnavailable}, ReasonArtifactUnavailable, ActionRetry},
		{"integrity", &Failure{Reason: ReasonIntegrityFailed}, ReasonIntegrityFailed, ActionRetry},
		{"component", &Failure{Reason: ReasonComponentUnverified}, ReasonComponentUnverified, ActionUpdateApp},
		{"status", &Failure{Reason: ReasonStatusUnavailable}, ReasonStatusUnavailable, ActionRetry},
		{"local data", &Failure{Reason: ReasonLocalDataUnavailable}, ReasonLocalDataUnavailable, ActionDetails},
		{"resource", &Failure{Reason: ReasonResourceUnavailable}, ReasonResourceUnavailable, ActionRetry},
		{"permission", fmt.Errorf("wrapped secret: %w", &Failure{Reason: ReasonPermissionRequired}), ReasonPermissionRequired, ActionOpenSettings},
		{"host", &Failure{Reason: ReasonUnsupportedHost}, ReasonUnsupportedHost, ActionNone},
		{"uncancelled", context.Canceled, ReasonSetupFailed, ActionRetry},
		{"typed nil", (*Failure)(nil), ReasonSetupFailed, ActionRetry},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			manager, workflow, scope, _ := managerFixture(t)
			started, err := manager.Start(scope)
			if err != nil {
				t.Fatal(err)
			}
			awaitWorkflow(t, workflow)
			workflow.finish <- test.err
			awaitTask(t, manager)
			observed, err := manager.Status(scope, started.AttemptID)
			if err != nil || observed.State != StateFailed || observed.Reason != test.reason || observed.Action != test.action {
				t.Fatalf("unsafe failure guidance: %+v %v", observed, err)
			}
			if observed.Message == "" || strings.Contains(observed.Message, "secret") {
				t.Fatal("workflow error text entered safe guidance")
			}
			if test.reason == ReasonSetupFailed && observed.Message != "Local cluster setup could not finish. Try again." {
				t.Fatal("generic setup message changed")
			}

		})
	}
}

func TestManagerRejectsMalformedScopeAndInvalidProgress(t *testing.T) {
	t.Parallel()
	manager, workflow, scope, _ := managerFixture(t)
	invalid := []Scope{}
	for _, origin := range []string{"", "https://app.test/path", "https://user:secret@app.test", "file:///tmp/cluster", "https://app.test?token=secret", "https://app.test#secret", "https://", "https://" + strings.Repeat("a", 512)} {
		bad := scope
		bad.AppOrigin = origin
		invalid = append(invalid, bad)
	}
	for _, account := range []string{"", "  ", "with\ncontrol", strings.Repeat("a", 257), string([]byte{0xff})} {
		bad := scope
		bad.AccountID = account
		invalid = append(invalid, bad)
	}
	bad := scope
	bad.WorkspaceID = ""
	invalid = append(invalid, bad)
	bad = scope
	bad.DocumentID = "not-a-document"
	invalid = append(invalid, bad)
	for _, bad := range invalid {
		_, err := manager.Start(bad)
		if !errors.Is(err, ErrInvalidScope) {
			t.Fatalf("invalid scope accepted: %+v %v", bad, err)
		}
	}
	select {
	case <-workflow.calls:
		t.Fatal("invalid scope invoked workflow")
	default:
	}
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	call := awaitWorkflow(t, workflow)
	valid := Progress{Stage: StageVerifying, CompletedBytes: 10, TotalBytes: 100}
	call.report(valid)
	for _, invalid := range []Progress{{Stage: "secret", CompletedBytes: 10}, {Stage: StageDownloading, CompletedBytes: 11}, {Stage: StageChecking, CompletedBytes: 9}, {Stage: StageChecking, CompletedBytes: 10, TotalBytes: -1}, {Stage: StageChecking, CompletedBytes: 101, TotalBytes: 100}, {Stage: StageCompleted, CompletedBytes: 100}} {
		call.report(invalid)
		observed, err := manager.Status(scope, started.AttemptID)
		if err != nil || observed.Progress != valid {
			t.Fatalf("invalid progress accepted: %+v %v", observed, err)
		}
	}
}

func TestManagerRequiresInitializedWorkflow(t *testing.T) {
	t.Parallel()
	manager, err := NewManager(context.Background(), nil, nil)
	if manager != nil || !errors.Is(err, ErrUnavailable) {
		t.Fatal("nil workflow claimed availability")
	}
}

func TestManagerObservationWithoutTaskAndTerminalCancel(t *testing.T) {
	t.Parallel()
	manager, workflow, scope, _ := managerFixture(t)
	for _, operation := range []string{"status", "cancel"} {
		var result Snapshot
		var err error
		if operation == "status" {
			result, err = manager.Status(scope, uuid.NewString())
		} else {
			result, err = manager.Cancel(scope, uuid.NewString())
		}
		if result != (Snapshot{}) || !errors.Is(err, ErrAttemptChanged) {
			t.Fatal("absent task exposed status")
		}
		invalid := scope
		invalid.WorkspaceID = ""
		if operation == "status" {
			result, err = manager.Status(invalid, uuid.NewString())
		} else {
			result, err = manager.Cancel(invalid, uuid.NewString())
		}
		if result != (Snapshot{}) || !errors.Is(err, ErrInvalidScope) {
			t.Fatal("invalid scope exposed status")
		}
	}
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	call := awaitWorkflow(t, workflow)
	workflow.finish <- nil
	awaitTask(t, manager)
	finished, err := manager.Status(scope, started.AttemptID)
	if err != nil {
		t.Fatal(err)
	}
	cancelled, err := manager.Cancel(scope, started.AttemptID)
	if err != nil || cancelled != finished {
		t.Fatal("terminal cancellation changed completed work")
	}
	call.report(Progress{Stage: StageChecking, CompletedBytes: 900})
	observed, err := manager.Status(scope, started.AttemptID)
	if err != nil || observed != finished {
		t.Fatal("terminal callback changed completed work")
	}
}

func TestManagerCancellationFailureIsFailedRatherThanAcknowledged(t *testing.T) {
	t.Parallel()
	manager, workflow, scope, _ := managerFixture(t)
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	awaitWorkflow(t, workflow)
	_, err = manager.Cancel(scope, started.AttemptID)
	if err != nil {
		t.Fatal(err)
	}
	workflow.finish <- errors.New("child process stop failed: private details")
	awaitTask(t, manager)
	observed, err := manager.Status(scope, started.AttemptID)
	if err != nil || observed.State != StateFailed || observed.Reason != ReasonSetupFailed {
		t.Fatal("stop failure claimed cancellation success")
	}
}

func TestManagerPassiveStatusDiscoversSameOwnerTaskWithoutStarting(t *testing.T) {
	t.Parallel()
	manager, workflow, scope, _ := managerFixture(t)
	absent, err := manager.Status(scope, "")
	if err != nil || absent.State != StateNoTask {
		t.Fatalf("no-task status: %+v %v", absent, err)
	}
	raw, err := json.Marshal(absent)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != `{"state":"no_task","action":"none"}` {
		t.Fatalf("no-task status claimed installation state: %s", raw)
	}
	select {
	case <-workflow.calls:
		t.Fatal("passive lookup started installation")
	default:
	}
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	awaitWorkflow(t, workflow)
	reopened := scope
	reopened.DocumentID = uuid.NewString()
	observed, err := manager.Status(reopened, "")
	if err != nil || observed != started {
		t.Fatalf("reopened document did not discover original attempt: %+v %v", observed, err)
	}
	foreign := reopened
	foreign.AccountID = "another-account"
	observed, err = manager.Status(foreign, "")
	if !errors.Is(err, ErrOccupied) || observed != (Snapshot{}) {
		t.Fatal("passive lookup leaked a foreign task")
	}
	_, err = manager.Cancel(reopened, "")
	if !errors.Is(err, ErrAttemptChanged) {
		t.Fatal("cancel accepted an omitted attempt")
	}
	workflow.finish <- nil
	awaitTask(t, manager)
	observed, err = manager.Status(reopened, "")
	if err != nil || observed.AttemptID != started.AttemptID || observed.State != StateInstalled {
		t.Fatal("passive terminal lookup replaced the attempt")
	}
	select {
	case <-workflow.calls:
		t.Fatal("terminal lookup restarted installation")
	default:
	}
}

type runtimeWorkflowFake struct {
	*controlledWorkflow
	probe    func(context.Context, Scope) (RuntimeStatus, error)
	resume   func(context.Context, Scope) error
	stop     func(context.Context) error
	apply    func(context.Context, Scope, TargetBinding, []byte) error
	binding  func(context.Context, Scope) (TargetBindingStatus, error)
	remove   func(context.Context, Scope, TargetBinding) error
	newSetup func(context.Context, Scope, TargetBinding) error
}

func (f *runtimeWorkflowFake) Probe(ctx context.Context, scope Scope) (RuntimeStatus, error) {
	if f.probe == nil {
		return RuntimeStatus{}, errors.New("unexpected probe")
	}
	return f.probe(ctx, scope)
}
func (f *runtimeWorkflowFake) Start(ctx context.Context, scope Scope) error {
	if f.resume == nil {
		return errors.New("unexpected resume")
	}
	return f.resume(ctx, scope)
}
func (f *runtimeWorkflowFake) Stop(ctx context.Context) error {
	if f.stop == nil {
		return errors.New("unexpected stop")
	}
	return f.stop(ctx)
}
func (f *runtimeWorkflowFake) ApplyManifest(ctx context.Context, scope Scope, binding TargetBinding, manifest []byte) error {
	if f.apply == nil {
		return errors.New("unexpected apply")
	}
	return f.apply(ctx, scope, binding, manifest)
}

func (f *runtimeWorkflowFake) Binding(ctx context.Context, scope Scope) (TargetBindingStatus, error) {
	if f.binding == nil {
		return TargetBindingStatus{}, errors.New("unexpected binding read")
	}
	return f.binding(ctx, scope)
}
func (f *runtimeWorkflowFake) RemoveData(ctx context.Context, scope Scope, binding TargetBinding) error {
	if f.remove == nil {
		return errors.New("unexpected remove")
	}
	return f.remove(ctx, scope, binding)
}
func (f *runtimeWorkflowFake) NewSetupAfterRemoval(ctx context.Context, scope Scope, binding TargetBinding) error {
	if f.newSetup == nil {
		return errors.New("unexpected new setup")
	}
	return f.newSetup(ctx, scope, binding)
}
func managerBinding() TargetBinding {
	return TargetBinding{IntegrationID: "cluster-one", InstallationID: strings.Repeat("a", 64)}
}

func runtimeManagerFixture(t *testing.T) (*Manager, *runtimeWorkflowFake, Scope) {
	t.Helper()
	base, controlled, scope, _ := managerFixture(t)
	workflow := &runtimeWorkflowFake{controlledWorkflow: controlled}
	manager, err := NewManager(base.ctx, workflow, base.now)
	if err != nil {
		t.Fatal(err)
	}
	return manager, workflow, scope
}

func TestManagerRuntimeResumeSharesTaskOwner(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	started := make(chan Scope, 1)
	release := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	workflow.resume = func(ctx context.Context, owner Scope) error { started <- owner; <-release; return nil }
	snapshot, err := manager.Resume(scope)
	if err != nil || snapshot.Operation != OperationResume {
		t.Fatalf("resume: %+v %v", snapshot, err)
	}
	select {
	case owner := <-started:
		if owner != scope {
			t.Fatal("resume owner changed")
		}
	case <-time.After(time.Second):
		t.Fatal("resume did not start")
	}
	if _, err = manager.Start(scope); !errors.Is(err, ErrBusy) {
		t.Fatal("install overlapped resume")
	}
	if _, err = manager.Apply(scope, snapshot.AttemptID, managerBinding(), []byte("manifest")); !errors.Is(err, ErrBusy) {
		t.Fatal("apply overlapped resume")
	}
	foreign := scope
	foreign.WorkspaceID = "other"
	if _, err = manager.Resume(foreign); !errors.Is(err, ErrOccupied) {
		t.Fatal("foreign resume accepted")
	}
	once.Do(func() { close(release) })
	awaitTask(t, manager)
	completed, err := manager.Status(scope, snapshot.AttemptID)
	if err != nil || completed.State != StateCompleted || completed.Operation != OperationResume {
		t.Fatal("resume claimed installation or did not complete")
	}
}

func TestManagerApplyRequiresCompletedOwnerAndCopiesTransientManifest(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	if _, err := manager.Apply(scope, uuid.NewString(), managerBinding(), []byte("manifest")); !errors.Is(err, ErrAttemptChanged) {
		t.Fatal("apply without preparation accepted")
	}
	installed, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	awaitWorkflow(t, workflow.controlledWorkflow)
	workflow.finish <- nil
	awaitTask(t, manager)
	for _, manifest := range [][]byte{nil, []byte{0xff}, bytes.Repeat([]byte("a"), MaxManifestBytes+1)} {
		if _, err = manager.Apply(scope, installed.AttemptID, managerBinding(), manifest); !errors.Is(err, ErrInvalidManifest) {
			t.Fatal("invalid manifest accepted")
		}
	}
	if _, err = manager.Apply(scope, uuid.NewString(), managerBinding(), []byte("manifest")); !errors.Is(err, ErrAttemptChanged) {
		t.Fatal("stale apply accepted")
	}
	foreign := scope
	foreign.AccountID = "other"
	if _, err = manager.Apply(foreign, installed.AttemptID, managerBinding(), []byte("manifest")); !errors.Is(err, ErrOccupied) {
		t.Fatal("foreign apply accepted")
	}
	manifest := []byte("private credential manifest")
	observed := make(chan []byte, 1)
	read := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	workflow.apply = func(ctx context.Context, owner Scope, binding TargetBinding, input []byte) error {
		<-read
		if owner != scope || binding != managerBinding() {
			return errors.New("wrong scope or binding")
		}
		observed <- input
		<-release
		return nil
	}
	applying, err := manager.Apply(scope, installed.AttemptID, managerBinding(), manifest)
	if err != nil || applying.Operation != OperationApply {
		t.Fatalf("apply: %+v %v", applying, err)
	}
	clear(manifest)
	close(read)
	var transient []byte
	select {
	case transient = <-observed:
	case <-time.After(time.Second):
		t.Fatal("apply did not start")
	}
	if string(transient) != "private credential manifest" {
		t.Fatal("manifest was not privately copied")
	}
	if _, err = manager.Start(scope); !errors.Is(err, ErrBusy) {
		t.Fatal("install overlapped apply")
	}
	once.Do(func() { close(release) })
	awaitTask(t, manager)
	for _, value := range transient {
		if value != 0 {
			t.Fatal("transient manifest survived task completion")
		}
	}
	completed, err := manager.Status(scope, applying.AttemptID)
	if err != nil || completed.State != StateCompleted {
		t.Fatal("apply did not complete")
	}
}

func TestManagerStopCancelsAndJoinsInstallBeforeRuntimeStop(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	stopStarted := make(chan struct{}, 1)
	stopRelease := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(stopRelease) }) })
	workflow.stop = func(ctx context.Context) error { stopStarted <- struct{}{}; <-stopRelease; return nil }
	initial, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	install := awaitWorkflow(t, workflow.controlledWorkflow)
	accepted, err := manager.Stop()
	if err != nil || !accepted.Active || !manager.Active() {
		t.Fatal("stop did not become active")
	}
	raw, err := json.Marshal(accepted)
	if err != nil || string(raw) != `{"active":true}` {
		t.Fatal("scope-free stop exposed private task metadata")
	}
	select {
	case <-install.ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("stop did not cancel prior install")
	}
	select {
	case <-stopStarted:
		t.Fatal("runtime stop ran before installer exited")
	default:
	}
	status, err := manager.RuntimeStatus(context.Background())
	if err != nil || !status.InstallerActive {
		t.Fatal("pending stop appeared idle")
	}
	if _, err = manager.Start(scope); !errors.Is(err, ErrBusy) {
		t.Fatal("new install overlapped stop")
	}
	workflow.finish <- context.Canceled
	select {
	case <-stopStarted:
	case <-time.After(time.Second):
		t.Fatal("runtime stop did not follow installer exit")
	}
	install.report(Progress{Stage: StageChecking, CompletedBytes: 999})
	if _, err = manager.Status(scope, ""); !errors.Is(err, ErrBusy) {
		t.Fatal("machine stop exposed a scoped task")
	}
	manager.mu.Lock()
	stopTask := manager.task.snapshot
	manager.mu.Unlock()
	if stopTask.Operation != OperationStop || stopTask.AttemptID == initial.AttemptID || stopTask.Progress.CompletedBytes != 0 {
		t.Fatal("old install overwrote stop task")
	}
	once.Do(func() { close(stopRelease) })
	awaitTask(t, manager)
	if manager.Active() {
		t.Fatal("verified stop remained active")
	}
}

func TestManagerStopFailureCannotBecomeStoppedProof(t *testing.T) {
	t.Parallel()
	manager, workflow, _ := runtimeManagerFixture(t)
	workflow.stop = func(context.Context) error { return errors.New("private process stderr") }
	workflow.probe = func(context.Context, Scope) (RuntimeStatus, error) { return RuntimeStatus{Installed: true}, nil }
	if _, err := manager.Stop(); err != nil {
		t.Fatal(err)
	}
	awaitTask(t, manager)
	status, err := manager.RuntimeStatus(context.Background())
	if err != nil || status.Reason != ReasonStopFailed || status.Message != "The local cluster could not stop. Try again." || status.InstallerActive {
		t.Fatalf("stop error vanished: %+v %v", status, err)
	}
	keep, err := manager.RetainForBackgroundStop(context.Background())
	if err != nil || !keep {
		t.Fatal("failed stop allowed background unregister")
	}
	workflow.stop = func(context.Context) error { return nil }
	if _, err = manager.Stop(); err != nil {
		t.Fatal(err)
	}
	awaitTask(t, manager)
	status, err = manager.RuntimeStatus(context.Background())
	if err != nil || status.Reason != ReasonNone || status.Running || status.InstallerActive {
		t.Fatal("successful verified stop retained old failure")
	}
}

func TestManagerBackgroundStopFencesConcurrentTaskAndQuiescesAdmission(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	probeStarted := make(chan struct{}, 1)
	probeRelease := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(probeRelease) }) })
	workflow.probe = func(context.Context, Scope) (RuntimeStatus, error) {
		probeStarted <- struct{}{}
		<-probeRelease
		return RuntimeStatus{}, nil
	}
	keepResult := make(chan bool, 1)
	go func() {
		keep, err := manager.RetainForBackgroundStop(context.Background())
		keepResult <- keep && err == nil
	}()
	select {
	case <-probeStarted:
	case <-time.After(time.Second):
		t.Fatal("native stopped probe did not start")
	}
	started, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	awaitWorkflow(t, workflow.controlledWorkflow)
	once.Do(func() { close(probeRelease) })
	select {
	case keep := <-keepResult:
		if !keep {
			t.Fatal("concurrent task escaped helper retention")
		}
	case <-time.After(time.Second):
		t.Fatal("background stop did not finish")
	}
	workflow.finish <- nil
	awaitTask(t, manager)
	workflow.probe = func(context.Context, Scope) (RuntimeStatus, error) { return RuntimeStatus{}, nil }
	keep, err := manager.RetainForBackgroundStop(context.Background())
	if err != nil || keep {
		t.Fatal("stopped idle helper could not unregister")
	}
	if _, err = manager.Start(scope); !errors.Is(err, ErrBusy) {
		t.Fatal("install escaped unregister fence")
	}
	if _, err = manager.Resume(scope); !errors.Is(err, ErrBusy) {
		t.Fatal("resume escaped unregister fence")
	}
	if _, err = manager.Apply(scope, started.AttemptID, managerBinding(), []byte("manifest")); !errors.Is(err, ErrBusy) {
		t.Fatal("apply escaped unregister fence")
	}
}

func TestManagerFailedApplyRetriesCustodyAndCompletedApplyIsIdempotent(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	workflow.resume = func(context.Context, Scope) error { return nil }
	prepared, err := manager.Resume(scope)
	if err != nil {
		t.Fatal(err)
	}
	awaitTask(t, manager)
	var calls atomic.Int32
	workflow.apply = func(context.Context, Scope, TargetBinding, []byte) error {
		calls.Add(1)
		return &Failure{Reason: ReasonResourceUnavailable}
	}
	first, err := manager.Apply(scope, prepared.AttemptID, managerBinding(), []byte("retained custody"))
	if err != nil {
		t.Fatal(err)
	}
	awaitTask(t, manager)
	workflow.apply = func(context.Context, Scope, TargetBinding, []byte) error { calls.Add(1); return nil }
	retried, err := manager.Apply(scope, first.AttemptID, managerBinding(), []byte("retained custody"))
	if err != nil || retried.AttemptID == first.AttemptID {
		t.Fatal("failed apply could not retry retained custody")
	}
	awaitTask(t, manager)
	duplicate, err := manager.Apply(scope, retried.AttemptID, managerBinding(), []byte("retained custody"))
	if err != nil || duplicate.AttemptID != retried.AttemptID || duplicate.State != StateCompleted || calls.Load() != 2 {
		t.Fatal("completed apply duplicate mutated credentials")
	}
}

type restoringWorkflow struct {
	*runtimeWorkflowFake
	restore func(context.Context) error
}

func (f *restoringWorkflow) Restore(ctx context.Context) error { return f.restore(ctx) }

func TestManagerStartupRestoreUsesCommonTaskAndNoCloudScope(t *testing.T) {
	t.Parallel()
	base, runtime, scope := runtimeManagerFixture(t)
	started := make(chan context.Context, 1)
	release := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	workflow := &restoringWorkflow{runtimeWorkflowFake: runtime, restore: func(ctx context.Context) error { started <- ctx; <-release; return nil }}
	manager, err := NewManager(base.ctx, workflow, base.now)
	if err != nil {
		t.Fatal(err)
	}
	if err = manager.RestoreLocal(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("restore did not start")
	}
	if !manager.Active() {
		t.Fatal("restore bypassed task owner")
	}
	if _, err = manager.Resume(scope); !errors.Is(err, ErrBusy) {
		t.Fatal("scoped resume inherited machine restore")
	}
	if _, err = manager.Status(scope, ""); !errors.Is(err, ErrBusy) {
		t.Fatal("active restore exposed a scoped snapshot")
	}
	once.Do(func() { close(release) })
	awaitTask(t, manager)
	status, err := manager.Status(scope, "")
	if err != nil || status.State != StateNoTask || status.AttemptID != "" || status.Scope != (Scope{}) {
		t.Fatal("terminal restore poisoned reopened scope or created authority")
	}
	manager.mu.Lock()
	attemptID := manager.task.snapshot.AttemptID
	manager.mu.Unlock()
	if _, err = manager.Apply(scope, attemptID, managerBinding(), []byte("manifest")); !errors.Is(err, ErrAttemptChanged) {
		t.Fatal("machine restore authorized manifest apply")
	}
}

func TestManagerBackgroundStopRetainsEnabledOrUnverifiedNativeState(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name   string
		status RuntimeStatus
		err    error
	}{
		{"enabled", RuntimeStatus{Installed: true, Enabled: true}, nil},
		{"running", RuntimeStatus{Installed: true, Running: true}, nil},
		{"unverified", RuntimeStatus{Reason: ReasonIntegrityFailed}, nil},
		{"failed probe", RuntimeStatus{}, errors.New("private process stderr")},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			manager, workflow, _ := runtimeManagerFixture(t)
			workflow.probe = func(context.Context, Scope) (RuntimeStatus, error) { return test.status, test.err }
			keep, err := manager.RetainForBackgroundStop(context.Background())
			if err != nil || !keep {
				t.Fatal("enabled, running or unverified runtime permitted helper unregister")
			}
			if manager.quiesced {
				t.Fatal("retained helper unexpectedly quiesced future work")
			}
		})
	}
}

func TestManagerStopPreservesActionableComponentAndLocalDataGuidance(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name    string
		reason  Reason
		action  Action
		message string
	}{
		{"component", ReasonComponentUnverified, ActionUpdateApp, "The installed app component could not be verified. Update PersonaStack for macOS."},
		{"local data", ReasonLocalDataUnavailable, ActionDetails, "Existing local cluster files could not be verified. Review details before continuing."},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			manager, workflow, _ := runtimeManagerFixture(t)
			workflow.stop = func(context.Context) error {
				return fmt.Errorf("private path or stderr: %w", &Failure{Reason: test.reason})
			}
			workflow.probe = func(context.Context, Scope) (RuntimeStatus, error) { return RuntimeStatus{}, nil }
			if _, err := manager.Stop(); err != nil {
				t.Fatal(err)
			}
			awaitTask(t, manager)
			status, err := manager.RuntimeStatus(context.Background())
			if err != nil || status.Reason != test.reason || status.Action != test.action || status.Message != test.message {
				t.Fatalf("actionable stop error lost: %+v %v", status, err)
			}
			keep, err := manager.RetainForBackgroundStop(context.Background())
			if err != nil || !keep {
				t.Fatal("unverified component/data allowed helper unregister")
			}
		})
	}
}

func TestManagerTargetBindingRemovalAndExplicitBlankSetup(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	binding := managerBinding()
	var removed atomic.Bool
	workflow.binding = func(ctx context.Context, owner Scope) (TargetBindingStatus, error) {
		if !sameOwner(owner, scope) {
			return TargetBindingStatus{}, ErrOccupied
		}
		if removed.Load() {
			return TargetBindingStatus{Removed: true, PreviousRemovedBinding: &binding}, nil
		}
		return TargetBindingStatus{Binding: &binding}, nil
	}
	status, err := manager.Binding(context.Background(), scope)
	if err != nil || status.Binding == nil || *status.Binding != binding {
		t.Fatal("native binding read lost verified target")
	}
	removeStarted := make(chan struct{}, 1)
	release := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	workflow.remove = func(ctx context.Context, owner Scope, target TargetBinding) error {
		if owner != scope || target != binding {
			return errors.New("unexpected removal target")
		}
		removeStarted <- struct{}{}
		<-release
		removed.Store(true)
		return nil
	}
	task, err := manager.Remove(scope, binding)
	if err != nil || task.Operation != OperationRemove {
		t.Fatal("removal did not enter common task owner")
	}
	select {
	case <-removeStarted:
	case <-time.After(time.Second):
		t.Fatal("removal did not start")
	}
	if _, err = manager.Binding(context.Background(), scope); !errors.Is(err, ErrBusy) {
		t.Fatal("binding read bypassed active mutation")
	}
	if _, err = manager.Resume(scope); !errors.Is(err, ErrBusy) {
		t.Fatal("resume overlapped removal")
	}
	foreign := scope
	foreign.AccountID = "another-owner"
	if _, err = manager.Remove(foreign, binding); !errors.Is(err, ErrOccupied) {
		t.Fatal("foreign removal accepted")
	}
	once.Do(func() { close(release) })
	awaitTask(t, manager)
	completed, err := manager.Status(scope, task.AttemptID)
	if err != nil || completed.State != StateCompleted || completed.Operation != OperationRemove {
		t.Fatal("removal completion lost")
	}
	status, err = manager.Binding(context.Background(), scope)
	if err != nil || !status.Removed || status.PreviousRemovedBinding == nil || *status.PreviousRemovedBinding != binding {
		t.Fatal("native removed binding observation lost")
	}
	workflow.newSetup = func(ctx context.Context, owner Scope, target TargetBinding) error {
		if owner != scope || target != binding {
			return errors.New("unexpected blank setup target")
		}
		return nil
	}
	blank, err := manager.NewSetupAfterRemoval(scope, binding)
	if err != nil || blank.Operation != OperationNewSetup {
		t.Fatal("explicit blank setup did not get a task")
	}
	awaitTask(t, manager)
	newOwner := scope
	newOwner.AccountID = "new-owner"
	newOwner.DocumentID = uuid.NewString()
	observed, err := manager.Status(newOwner, "")
	if err != nil || observed.State != StateNoTask || observed.Scope != (Scope{}) {
		t.Fatal("blank setup exposed previous owner or kept reservation")
	}
	if _, err = manager.Status(newOwner, blank.AttemptID); !errors.Is(err, ErrOccupied) {
		t.Fatal("new owner read previous owner's reset callback")
	}
	select {
	case <-workflow.calls:
		t.Fatal("blank setup automatically installed")
	default:
	}
	if _, err = manager.Start(newOwner); err != nil {
		t.Fatal("explicit new authenticated owner could not start blank setup")
	}
	call := awaitWorkflow(t, workflow.controlledWorkflow)
	if call.scope != newOwner {
		t.Fatal("new blank install reused removed owner")
	}
}

func TestManagerRemovedStatusIsInformationalAndAllowsHelperStop(t *testing.T) {
	t.Parallel()
	manager, workflow, _ := runtimeManagerFixture(t)
	workflow.probe = func(context.Context, Scope) (RuntimeStatus, error) {
		return RuntimeStatus{Reason: ReasonLocalDataRemoved}, nil
	}
	status, err := manager.RuntimeStatus(context.Background())
	if err != nil || status.Reason != ReasonLocalDataRemoved || status.Action != ActionNone || status.Message != "Local cluster files were removed." || status.InstallerActive || status.Installed || status.Running || status.Enabled || status.KubernetesAvailable {
		t.Fatalf("removed runtime status claimed work/readiness: %+v %v", status, err)
	}
	keep, err := manager.RetainForBackgroundStop(context.Background())
	if err != nil || keep {
		t.Fatal("informational removal state retained idle helper")
	}
}

func TestManagerBindingValidationAndChangedApplyTarget(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	for _, invalid := range []TargetBinding{{}, {IntegrationID: "cluster", InstallationID: "invalid"}, {IntegrationID: "\n", InstallationID: strings.Repeat("a", 64)}} {
		if _, err := manager.Apply(scope, uuid.NewString(), invalid, []byte("manifest")); !errors.Is(err, ErrInvalidBinding) {
			t.Fatal("apply accepted invalid binding")
		}
	}
	workflow.resume = func(context.Context, Scope) error { return nil }
	prepared, err := manager.Resume(scope)
	if err != nil {
		t.Fatal(err)
	}
	awaitTask(t, manager)
	workflow.apply = func(context.Context, Scope, TargetBinding, []byte) error { return errors.New("fixture apply failed") }
	failed, err := manager.Apply(scope, prepared.AttemptID, managerBinding(), []byte("custody"))
	if err != nil {
		t.Fatal(err)
	}
	awaitTask(t, manager)
	changed := managerBinding()
	changed.IntegrationID = "different-cluster"
	if _, err = manager.Apply(scope, failed.AttemptID, changed, []byte("custody")); !errors.Is(err, ErrAttemptChanged) {
		t.Fatal("failed apply retry changed target binding")
	}
}

func TestManagerExplicitBlankResetScopesCallbacksToNewHuman(t *testing.T) {
	t.Parallel()
	for _, success := range []bool{false, true} {
		t.Run(fmt.Sprint(success), func(t *testing.T) {
			t.Parallel()
			manager, workflow, oldScope := runtimeManagerFixture(t)
			workflow.resume = func(context.Context, Scope) error { return nil }
			if _, err := manager.Resume(oldScope); err != nil {
				t.Fatal(err)
			}
			awaitTask(t, manager)
			newScope := oldScope
			newScope.AccountID = "current-human"
			newScope.DocumentID = uuid.NewString()
			started := make(chan struct{}, 1)
			release := make(chan struct{})
			var once sync.Once
			t.Cleanup(func() { once.Do(func() { close(release) }) })
			workflow.newSetup = func(ctx context.Context, scope Scope, binding TargetBinding) error {
				if scope != newScope || binding != managerBinding() {
					return errors.New("unexpected reset authority")
				}
				started <- struct{}{}
				<-release
				if !success {
					return &Failure{Reason: ReasonLocalDataUnavailable}
				}
				return nil
			}
			task, err := manager.NewSetupAfterRemoval(newScope, managerBinding())
			if err != nil {
				t.Fatal("manager rejected new reset scope before runtime removed guard")
			}
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("reset was not scheduled")
			}
			observed, err := manager.Status(newScope, task.AttemptID)
			if err != nil || observed.Scope != newScope {
				t.Fatal("pending reset callback lost new scope")
			}
			if _, err = manager.Status(oldScope, task.AttemptID); !errors.Is(err, ErrOccupied) {
				t.Fatal("old scope read new human reset task")
			}
			once.Do(func() { close(release) })
			awaitTask(t, manager)
			if success {
				observed, err = manager.Status(newScope, "")
				if err != nil || observed.State != StateNoTask {
					t.Fatal("completed blank reset retained scoped task")
				}
				select {
				case <-workflow.calls:
					t.Fatal("reset automatically installed")
				default:
				}
			} else {
				if _, err = manager.Start(newScope); !errors.Is(err, ErrOccupied) {
					t.Fatal("failed reset released previous owner")
				}
			}
		})
	}
}

func TestManagerLocalRemoveDoesNotInventCloudScopeOrDiscloseBinding(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	called := make(chan struct{}, 1)
	workflow.remove = func(ctx context.Context, owner Scope, binding TargetBinding) error {
		if owner != (Scope{}) || binding != (TargetBinding{}) {
			return errors.New("machine remove fabricated cloud identity")
		}
		called <- struct{}{}
		return nil
	}
	accepted, err := manager.RemoveLocal()
	if err != nil || !accepted.Active {
		t.Fatal("machine remove not accepted asynchronously")
	}
	awaitTask(t, manager)
	select {
	case <-called:
	default:
		t.Fatal("machine remove not called")
	}
	raw, err := json.Marshal(accepted)
	if err != nil || string(raw) != `{"active":true}` {
		t.Fatal("machine remove exposed native target")
	}
	status, err := manager.Status(scope, "")
	if err != nil || status.State != StateNoTask || status.Scope != (Scope{}) {
		t.Fatal("machine remove created scoped authority")
	}
}
