package localcluster

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestRemovalErasesOwnedPayloadAndPreservesUnrelatedEntries(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	root := fixture.runtime.options.Root
	outside := filepath.Join(filepath.Dir(root), "external-profile")
	err := os.WriteFile(outside, []byte("preserve"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"unrelated", "l/another-instance"} {
		err = os.MkdirAll(filepath.Join(root, name), 0700)
		if err != nil {
			t.Fatal(err)
		}
		err = os.WriteFile(filepath.Join(root, name, "data"), []byte("preserve"), 0600)
		if err != nil {
			t.Fatal(err)
		}
	}
	err = os.Symlink(outside, filepath.Join(root, "artifacts", "outside"))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"home", "tmp"} {
		err = os.WriteFile(filepath.Join(root, name, "cache"), []byte("erase"), 0600)
		if err != nil {
			t.Fatal(err)
		}
	}
	for attempt := 0; attempt < 2; attempt++ {
		err = fixture.runtime.RemoveData(context.Background(), Scope{}, TargetBinding{})
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range append([]string{"l/" + InstanceName}, removalCacheNames...) {
		_, err = os.Lstat(filepath.Join(root, name))
		if !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("payload remains: %s: %v", name, err)
		}
	}
	for _, name := range []string{outside, filepath.Join(root, "unrelated/data"), filepath.Join(root, "l/another-instance/data")} {
		data, readErr := os.ReadFile(name)
		if readErr != nil || string(data) != "preserve" {
			t.Fatalf("unrelated data changed: %s: %v", name, readErr)
		}
	}
	status, err := fixture.runtime.Probe(context.Background(), Scope{})
	if err != nil || status.Reason != ReasonLocalDataRemoved {
		t.Fatalf("completion missing: %+v %v", status, err)
	}
}

func TestRemovalPayloadFailureRemainsIncompleteUntilRetry(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	rejectDeviceForPath(t, fixture, filepath.Join(fixture.runtime.options.Root, "artifacts"))
	err := fixture.runtime.RemoveData(context.Background(), Scope{}, TargetBinding{})
	if err == nil {
		t.Fatal("cache mount rejection disappeared")
	}
	status, err := fixture.runtime.Probe(context.Background(), Scope{})
	if err == nil || status.Reason == ReasonLocalDataRemoved {
		t.Fatalf("incomplete removal claimed success: %+v %v", status, err)
	}
	binding, err := fixture.runtime.Binding(context.Background(), runtimeTestScope())
	if err != nil || binding.Removed {
		t.Fatalf("binding claimed complete removal: %+v %v", binding, err)
	}
	fixture.runtime.dependencies.device = removalDevice
	before := len(fixture.calls)
	err = fixture.runtime.RemoveData(context.Background(), Scope{}, TargetBinding{})
	if err != nil {
		t.Fatal(err)
	}
	if len(fixture.calls) != before {
		t.Fatal("cache-only retry launched a VM command")
	}
	status, err = fixture.runtime.Probe(context.Background(), Scope{})
	if err != nil || status.Reason != ReasonLocalDataRemoved {
		t.Fatalf("retry not complete: %+v %v", status, err)
	}
}

func TestRemovalWithoutInstallationIsIdempotentAndRejectsUnownedPayload(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx := context.Background()
	err := fixture.runtime.RemoveData(ctx, Scope{}, TargetBinding{})
	if err != nil {
		t.Fatal(err)
	}
	tree, err := fixture.runtime.tree(true)
	if err != nil {
		t.Fatal(err)
	}
	defer tree.directory.Close()
	if err = fixture.runtime.RemoveData(ctx, Scope{}, TargetBinding{}); err != nil {
		t.Fatal(err)
	}
	err = tree.write("artifacts/unknown", []byte("preserve"))
	if err != nil {
		t.Fatal(err)
	}
	if fixture.runtime.RemoveData(ctx, Scope{}, TargetBinding{}) == nil {
		t.Fatal("unowned payload was accepted")
	}
	if len(fixture.calls) != 0 {
		t.Fatal("absent/unowned cleanup launched commands")
	}
}

func TestManagerRemoveFailureSurvivesStoppedProbeAndStopUntilRemovalSucceeds(t *testing.T) {
	t.Parallel()
	manager, workflow, _ := runtimeManagerFixture(t)
	workflow.remove = func(context.Context, Scope, TargetBinding) error { return &Failure{Reason: ReasonLocalDataUnavailable} }
	workflow.probe = func(context.Context, Scope) (RuntimeStatus, error) { return RuntimeStatus{}, nil }
	_, err := manager.RemoveLocal()
	if err != nil {
		t.Fatal(err)
	}
	awaitTask(t, manager)
	status, err := manager.RuntimeStatus(context.Background())
	if err != nil || status.Reason != ReasonLocalDataUnavailable {
		t.Fatalf("remove failure vanished: %+v %v", status, err)
	}
	workflow.stop = func(context.Context) error { return nil }
	_, err = manager.Stop()
	if err != nil {
		t.Fatal(err)
	}
	awaitTask(t, manager)
	status, err = manager.RuntimeStatus(context.Background())
	if err != nil || status.Reason != ReasonLocalDataUnavailable {
		t.Fatalf("stop cleared failed removal: %+v %v", status, err)
	}
	workflow.remove = func(context.Context, Scope, TargetBinding) error { return nil }
	_, err = manager.RemoveLocal()
	if err != nil {
		t.Fatal(err)
	}
	awaitTask(t, manager)
	status, err = manager.RuntimeStatus(context.Background())
	if err != nil || status.Reason != ReasonLocalDataRemoved {
		t.Fatalf("successful retry retained failure or lost completion: %+v %v", status, err)
	}
}
