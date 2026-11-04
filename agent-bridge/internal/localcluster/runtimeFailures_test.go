package localcluster

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestRuntimePreflightFailuresNeverDownloadOrStart(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		reason  Reason
		prepare func(*runtimeFixture)
	}{
		{"unsupported", ReasonUnsupportedHost, func(fixture *runtimeFixture) { fixture.runtime.dependencies.supported = func() bool { return false } }},
		{"signature", ReasonComponentUnverified, func(fixture *runtimeFixture) { fixture.failOperation = "verify_signature" }},
		{"resource", ReasonResourceUnavailable, func(fixture *runtimeFixture) {
			fixture.runtime.dependencies.capacity = func(context.Context, *ownedTree, VMResources, int64) error {
				return fmt.Errorf("insufficient capacity")
			}
		}},
		{"sealedResource", ReasonComponentUnverified, func(fixture *runtimeFixture) {
			path := filepath.Join(fixture.runtime.options.BundleDirectory, "Contents/Resources/LocalCluster/lima/share/lima/lima-guestagent.Linux-aarch64.gz")
			err := os.WriteFile(path, []byte("tampered"), 0600)
			if err != nil {
				fixture.t.Fatal(err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := newRuntimeFixture(t)
			test.prepare(fixture)
			err := fixture.runtime.Install(context.Background(), runtimeTestScope(), nil)
			var failure *Failure
			if !errors.As(err, &failure) || failure.Reason != test.reason {
				t.Fatalf("got %v, want %s", err, test.reason)
			}
			if len(fixture.fetched) != 0 || fixture.running {
				t.Fatal("preflight failure downloaded or started a VM")
			}
		})
	}
}

func TestRuntimeCancellationStopFailureNeverAcknowledgesCancelled(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fixture.failOperation = "stop_vm"
	fixture.start = func(ctx context.Context) error { cancel(); <-ctx.Done(); return ctx.Err() }
	err := fixture.runtime.Install(ctx, runtimeTestScope(), nil)
	var failure *Failure
	if errors.Is(err, context.Canceled) || !errors.As(err, &failure) || !fixture.running {
		t.Fatalf("unobserved stop acknowledged cancellation: %v", err)
	}
}

func TestRuntimeExpiredStopDoesNotDisableOrMutate(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	err := fixture.runtime.Install(context.Background(), runtimeTestScope(), nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	before := len(fixture.calls)
	err = fixture.runtime.Stop(ctx)
	if !errors.Is(err, context.Canceled) || len(fixture.calls) != before {
		t.Fatal("expired stop ran native commands")
	}
	enabled, err := fixture.runtime.Enabled()
	if err != nil || !enabled {
		t.Fatal("expired stop changed native intent")
	}
}

func TestNativeCustodyRejectsFIFOWithoutBlocking(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	err := os.Chmod(root, 0700)
	if err != nil {
		t.Fatal(err)
	}
	tree, err := openOwnedTree(root, true)
	if err != nil {
		t.Fatal(err)
	}
	defer tree.directory.Close()
	err = unix.Mkfifo(filepath.Join(root, "fifo"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	file, err := tree.open("fifo", os.O_RDONLY)
	if file != nil {
		file.Close()
	}
	if err == nil {
		t.Fatal("native custody accepted a FIFO")
	}
}

func TestMissingOwnerNeverLooksLikeAnEmptyInstallation(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx := context.Background()
	scope := runtimeTestScope()
	err := fixture.runtime.Install(ctx, scope, nil)
	if err != nil {
		t.Fatal(err)
	}
	err = fixture.runtime.Shutdown(ctx)
	if err != nil {
		t.Fatal(err)
	}
	err = os.Remove(filepath.Join(fixture.runtime.options.Root, "owner.json"))
	if err != nil {
		t.Fatal(err)
	}
	before := len(fixture.calls)
	_, err = fixture.runtime.Probe(ctx, Scope{})
	if err == nil {
		t.Fatal("retained VM with missing owner appeared absent")
	}
	_, err = fixture.runtime.Enabled()
	if err == nil {
		t.Fatal("missing owner appeared safely disabled")
	}
	_, err = fixture.runtime.Binding(ctx, scope)
	if err == nil {
		t.Fatal("missing owner appeared never bound")
	}
	err = fixture.runtime.Restore(ctx)
	if err == nil {
		t.Fatal("missing owner allowed startup restore")
	}
	if len(fixture.calls) != before {
		t.Fatal("inconsistent native custody ran a process")
	}
}

func TestBoundedProcessOutputNeverRetainsExcessBytes(t *testing.T) {
	t.Parallel()
	var output boundedOutput
	input := make([]byte, commandOutputLimit+1024)
	written, err := output.Write(input)
	if err != nil || written != len(input) || output.Len() != commandOutputLimit || !output.overflow {
		t.Fatal("native process output exceeded its memory bound")
	}
}
