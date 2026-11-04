package localcluster

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func boundRuntimeFixture(t *testing.T) *runtimeFixture {
	t.Helper()
	fixture := newRuntimeFixture(t)
	ctx := context.Background()
	err := fixture.runtime.Install(ctx, runtimeTestScope(), nil)
	if err != nil {
		t.Fatal(err)
	}
	err = fixture.runtime.ApplyManifest(ctx, runtimeTestScope(), runtimeTestBinding(), []byte("trusted native install"))
	if err != nil {
		t.Fatal(err)
	}
	return fixture
}

func TestTargetBindingPersistsBeforeApplyAndRejectsReplacement(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx := context.Background()
	scope := runtimeTestScope()
	binding := runtimeTestBinding()
	err := fixture.runtime.Install(ctx, scope, nil)
	if err != nil {
		t.Fatal(err)
	}
	fixture.failOperation = "apply_native_manifest"
	err = fixture.runtime.ApplyManifest(ctx, scope, binding, []byte("manifest"))
	if err == nil {
		t.Fatal("planned apply failure disappeared")
	}
	status, err := fixture.runtime.Binding(ctx, scope)
	if err != nil || status.Binding == nil || *status.Binding != binding {
		t.Fatalf("target was not retained before apply: %+v %v", status, err)
	}
	fixture.failOperation = ""
	for _, changed := range []TargetBinding{{IntegrationID: "different-target", InstallationID: binding.InstallationID}, {IntegrationID: binding.IntegrationID, InstallationID: strings.Repeat("b", 64)}} {
		inputs := len(fixture.inputs)
		err = fixture.runtime.ApplyManifest(ctx, scope, changed, []byte("must not apply"))
		if err == nil || len(fixture.inputs) != inputs {
			t.Fatal("changed target/key received native credentials")
		}
	}
}

func TestLocalRemovalIsOfflineAndPreservesOutsideTargets(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	ctx := context.Background()
	scope := runtimeTestScope()
	wrongBinding := runtimeTestBinding()
	wrongBinding.IntegrationID = "wrong-target"
	err := fixture.runtime.RemoveData(ctx, scope, wrongBinding)
	if err == nil || !fixture.running {
		t.Fatal("changed removal target stopped or erased the VM")
	}
	err = fixture.runtime.Stop(ctx)
	if err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(filepath.Dir(fixture.runtime.options.Root), "outside-data")
	err = os.WriteFile(outside, []byte("outside survives"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	instance := filepath.Join(fixture.runtime.options.Root, "l", InstanceName)
	err = os.Symlink(outside, filepath.Join(instance, "outside-symlink"))
	if err != nil {
		t.Fatal(err)
	}
	err = os.Link(outside, filepath.Join(instance, "outside-hardlink"))
	if err != nil {
		t.Fatal(err)
	}
	fetched := len(fixture.fetched)
	err = fixture.runtime.RemoveData(ctx, Scope{}, TargetBinding{})
	if err != nil {
		t.Fatal(err)
	}
	if len(fixture.fetched) != fetched {
		t.Fatal("offline local removal used a downloader")
	}
	content, err := os.ReadFile(outside)
	if err != nil || string(content) != "outside survives" {
		t.Fatal("VM removal traversed an outside target")
	}
	_, err = os.Stat(instance)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatal("local VM directory remains")
	}
	status, err := fixture.runtime.Binding(ctx, scope)
	if err != nil || !status.Removed || status.Binding == nil || *status.Binding != runtimeTestBinding() {
		t.Fatalf("tombstone lost target identity: %+v %v", status, err)
	}
	before := len(fixture.calls)
	for _, operation := range []func() error{func() error { return fixture.runtime.Install(ctx, scope, nil) }, func() error { return fixture.runtime.Start(ctx, Scope{}) }, func() error {
		return fixture.runtime.ApplyManifest(ctx, scope, runtimeTestBinding(), []byte("old manifest"))
	}} {
		if operation() == nil {
			t.Fatal("removed installation was recreated without blank setup")
		}
	}
	err = fixture.runtime.Restore(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(fixture.calls) != before {
		t.Fatal("removed installation ran a command")
	}
}

func TestPartialRemovalFencesRestartUntilCleanupCompletes(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	ctx := context.Background()
	scope := runtimeTestScope()
	err := fixture.runtime.Stop(ctx)
	if err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "non-private-directory")
	err = os.Mkdir(nested, 0755)
	if err != nil {
		t.Fatal(err)
	}
	err = fixture.runtime.RemoveData(ctx, scope, runtimeTestBinding())
	if err == nil {
		t.Fatal("unverified directory was removed")
	}
	status, err := fixture.runtime.Binding(ctx, scope)
	if err != nil || status.Removed {
		t.Fatal("partial cleanup claimed complete local removal")
	}
	if fixture.runtime.NewSetupAfterRemoval(ctx, scope, runtimeTestBinding()) == nil {
		t.Fatal("partial cleanup allowed blank setup")
	}
	if fixture.runtime.Start(ctx, Scope{}) == nil {
		t.Fatal("partial cleanup allowed VM restart")
	}
	err = os.Chmod(nested, 0700)
	if err != nil {
		t.Fatal(err)
	}
	err = fixture.runtime.RemoveData(ctx, scope, runtimeTestBinding())
	if err != nil {
		t.Fatal(err)
	}
	status, err = fixture.runtime.Binding(ctx, scope)
	if err != nil || !status.Removed {
		t.Fatal("completed cleanup did not confirm removal")
	}
}

func TestExplicitBlankSetupRequiresNewTargetAndKey(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	ctx := context.Background()
	scope := runtimeTestScope()
	old := runtimeTestBinding()
	err := fixture.runtime.Stop(ctx)
	if err != nil {
		t.Fatal(err)
	}
	err = fixture.runtime.RemoveData(ctx, scope, old)
	if err != nil {
		t.Fatal(err)
	}
	err = fixture.runtime.NewSetupAfterRemoval(ctx, scope, old)
	if err != nil {
		t.Fatal(err)
	}
	status, err := fixture.runtime.Binding(ctx, scope)
	if err != nil || status.Binding != nil || status.PreviousRemovedBinding == nil || *status.PreviousRemovedBinding != old {
		t.Fatal("blank setup lost the previous identity fence")
	}
	err = fixture.runtime.Install(ctx, scope, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, binding := range []TargetBinding{old, {IntegrationID: "new-target", InstallationID: old.InstallationID}, {IntegrationID: old.IntegrationID, InstallationID: strings.Repeat("b", 64)}} {
		if fixture.runtime.ApplyManifest(ctx, scope, binding, []byte("old identity")) == nil {
			t.Fatal("blank setup reused a removed identity")
		}
	}
	newBinding := TargetBinding{IntegrationID: "new-target", InstallationID: strings.Repeat("b", 64)}
	err = fixture.runtime.ApplyManifest(ctx, scope, newBinding, []byte("fresh target"))
	if err != nil {
		t.Fatal(err)
	}
	status, err = fixture.runtime.Binding(ctx, scope)
	if err != nil || status.Binding == nil || *status.Binding != newBinding || status.PreviousRemovedBinding != nil {
		t.Fatal("fresh binding did not replace the previous fence")
	}
}

func TestBlankSetupCanChangeHumanScopeWithoutForeignDisclosure(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	ctx := context.Background()
	oldScope := runtimeTestScope()
	err := fixture.runtime.Stop(ctx)
	if err != nil {
		t.Fatal(err)
	}
	err = fixture.runtime.RemoveData(ctx, Scope{}, TargetBinding{})
	if err != nil {
		t.Fatal(err)
	}
	newScope := oldScope
	newScope.AccountID = "new-account"
	newScope.WorkspaceID = "new-workspace"
	err = fixture.runtime.NewSetupAfterRemoval(ctx, newScope, TargetBinding{})
	if err != nil {
		t.Fatal(err)
	}
	status, err := fixture.runtime.Binding(ctx, newScope)
	if err != nil || status.Binding != nil || status.PreviousRemovedBinding != nil {
		t.Fatal("blank ownership reset exposed a foreign target")
	}
	_, err = fixture.runtime.Binding(ctx, oldScope)
	if !errors.Is(err, ErrOccupied) {
		t.Fatal("old cloud scope retained native custody")
	}
	err = fixture.runtime.Install(ctx, newScope, nil)
	if err != nil {
		t.Fatal(err)
	}
	if fixture.runtime.ApplyManifest(ctx, newScope, runtimeTestBinding(), []byte("old identity")) == nil {
		t.Fatal("hidden old identity fence was bypassed")
	}
}
