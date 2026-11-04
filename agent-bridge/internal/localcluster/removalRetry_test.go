package localcluster

import (
	"context"
	"errors"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRemoveOwnsInitialStopBeforeErasingData(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	ctx := context.Background()
	err := fixture.runtime.RemoveData(ctx, runtimeTestScope(), runtimeTestBinding())
	if err != nil {
		t.Fatalf("canonical removal did not own initial stop: %v", err)
	}
	if fixture.running {
		t.Fatal("local data removal left the owned VM running")
	}
	_, err = os.Stat(filepath.Join(fixture.runtime.options.Root, "l", InstanceName))
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatal("canonical local removal left VM data")
	}
}

func rejectInstanceDevice(t *testing.T, fixture *runtimeFixture) {
	t.Helper()
	path := filepath.Join(fixture.runtime.options.Root, "l", InstanceName)
	rejectDeviceForPath(t, fixture, path)
}

func rejectDeviceForPath(t *testing.T, fixture *runtimeFixture, path string) {
	t.Helper()
	var instance unix.Stat_t
	err := unix.Stat(path, &instance)
	if err != nil {
		t.Fatal(err)
	}
	fixture.runtime.dependencies.device = func(fd int) (uint64, error) {
		var stat unix.Stat_t
		err := unix.Fstat(fd, &stat)
		if err != nil {
			return 0, err
		}
		device := uint64(stat.Dev)
		if stat.Ino == instance.Ino {
			device++
		}
		return device, nil
	}
}

func TestRemovalDoesNotTraverseMountedSubdirectory(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	ctx := context.Background()
	mounted := filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "mounted-directory")
	err := os.Mkdir(mounted, 0700)
	if err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(mounted, "outside-data")
	err = os.WriteFile(sentinel, []byte("not VM data"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	rejectDeviceForPath(t, fixture, mounted)
	err = fixture.runtime.RemoveData(ctx, runtimeTestScope(), runtimeTestBinding())
	if err == nil {
		t.Fatal("mounted subtree was traversed")
	}
	data, err := os.ReadFile(sentinel)
	if err != nil || string(data) != "not VM data" {
		t.Fatal("cross-device subtree data was erased")
	}
}

func TestRemovalRejectsCrossDeviceBeforeDeletingFiles(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	ctx := context.Background()
	rejectInstanceDevice(t, fixture)
	err := fixture.runtime.RemoveData(ctx, runtimeTestScope(), runtimeTestBinding())
	if err == nil {
		t.Fatal("cross-device VM root was traversed")
	}
	instance := filepath.Join(fixture.runtime.options.Root, "l", InstanceName)
	for _, name := range []string{"disk", "lima.yaml"} {
		_, err = os.Stat(filepath.Join(instance, name))
		if err != nil {
			t.Fatalf("mount rejection deleted %s: %v", name, err)
		}
	}
	status, err := fixture.runtime.Binding(ctx, runtimeTestScope())
	if err != nil || status.Removed {
		t.Fatal("rejected mount claimed completed removal")
	}
}

func TestTombstonedRemovalRetryIgnoresLimaMetadataButGuardsLiveResources(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	ctx := context.Background()
	scope := runtimeTestScope()
	fixture.requireMetadata = true
	rejectInstanceDevice(t, fixture)
	err := fixture.runtime.RemoveData(ctx, scope, runtimeTestBinding())
	if err == nil {
		t.Fatal("planned partial removal did not fail")
	}
	instance := filepath.Join(fixture.runtime.options.Root, "l", InstanceName)
	err = os.Remove(filepath.Join(instance, "lima.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	fixture.runtime.dependencies.device = removalDevice
	before := len(fixture.calls)
	err = os.WriteFile(filepath.Join(instance, "ha.pid"), []byte("12345\n"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	fixture.runtime.dependencies.alive = func(pid int) bool { return pid == 12345 }
	if fixture.runtime.RemoveData(ctx, scope, runtimeTestBinding()) == nil {
		t.Fatal("tombstone retry ignored a live owned PID")
	}
	fixture.runtime.dependencies.alive = func(int) bool { return false }
	fixture.openHandles = true
	if fixture.runtime.RemoveData(ctx, scope, runtimeTestBinding()) == nil {
		t.Fatal("tombstone retry ignored open disk handles")
	}
	fixture.openHandles = false
	err = fixture.runtime.RemoveData(ctx, scope, runtimeTestBinding())
	if err != nil {
		t.Fatal(err)
	}
	for _, call := range fixture.calls[before:] {
		if call.Operation == "stop_vm" || call.Operation == "probe_vm" || call.Operation == "verify_signature" {
			t.Fatalf("tombstone retry depended on Lima: %s", call.Operation)
		}
	}
	status, err := fixture.runtime.Binding(ctx, scope)
	if err != nil || !status.Removed {
		t.Fatalf("retry did not finish removal: %+v %v", status, err)
	}
}

func TestManagerLocalRemoveCancelsAndJoinsPriorWork(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	_, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	call := awaitWorkflow(t, workflow.controlledWorkflow)
	removed := make(chan struct{}, 1)
	workflow.remove = func(ctx context.Context, scope Scope, binding TargetBinding) error {
		if scope != (Scope{}) || binding != (TargetBinding{}) {
			return errors.New("machine removal leaked a cloud target")
		}
		removed <- struct{}{}
		return nil
	}
	_, err = manager.RemoveLocal()
	if err != nil {
		workflow.finish <- context.Canceled
		t.Fatal(err)
	}
	select {
	case <-call.ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("machine removal did not cancel prior work")
	}
	select {
	case <-removed:
		t.Fatal("machine removal raced an active child")
	default:
	}
	workflow.finish <- context.Canceled
	awaitTask(t, manager)
	select {
	case <-removed:
	default:
		t.Fatal("machine removal never ran after join")
	}
}

func TestManagerRemoveCancelsAndJoinsPriorWork(t *testing.T) {
	t.Parallel()
	manager, workflow, scope := runtimeManagerFixture(t)
	_, err := manager.Start(scope)
	if err != nil {
		t.Fatal(err)
	}
	call := awaitWorkflow(t, workflow.controlledWorkflow)
	removed := make(chan struct{}, 1)
	workflow.remove = func(ctx context.Context, owner Scope, binding TargetBinding) error { removed <- struct{}{}; return nil }
	task, err := manager.Remove(scope, managerBinding())
	if err != nil {
		workflow.finish <- context.Canceled
		t.Fatalf("remove did not replace active preparation: %v", err)
	}
	select {
	case <-call.ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("prior work was not cancelled")
	}
	select {
	case <-removed:
		t.Fatal("removal ran before prior child exit")
	default:
	}
	workflow.finish <- context.Canceled
	awaitTask(t, manager)
	select {
	case <-removed:
	default:
		t.Fatal("removal did not run after prior exit")
	}
	observed, err := manager.Status(scope, task.AttemptID)
	if err != nil || observed.State != StateCompleted {
		t.Fatalf("joined removal did not complete: %+v %v", observed, err)
	}
}
