package localcluster

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// There is one qualified input set. No older supported VM format or input
// migration exists. Unknown past/future hashes must use the same custody fence.
func TestRetainedInputCompatibilityFailureMatrix(t *testing.T) {
	t.Parallel()
	inputs := []struct{ name, guest, k3s string }{
		{"missing", "", ""},
		{"unrecognizedGuest", strings.Repeat("1", 64), PinnedDescriptor().Artifacts[2].SHA256},
		{"unrecognizedK3s", PinnedDescriptor().Artifacts[1].SHA256, strings.Repeat("f", 64)},
	}
	actions := []struct {
		name string
		run  func(*Runtime) error
	}{
		{"probe", func(r *Runtime) error { _, err := r.Probe(context.Background(), runtimeTestScope()); return err }},
		{"start", func(r *Runtime) error { return r.Start(context.Background(), runtimeTestScope()) }},
		{"restore", func(r *Runtime) error { return r.Restore(context.Background()) }},
		{"install", func(r *Runtime) error { return r.Install(context.Background(), runtimeTestScope(), nil) }},
		{"apply", func(r *Runtime) error {
			return r.ApplyManifest(context.Background(), runtimeTestScope(), runtimeTestBinding(), []byte("must not apply"))
		}},
	}
	for _, input := range inputs {
		for _, action := range actions {
			t.Run(input.name+"/"+action.name, func(t *testing.T) {
				t.Parallel()
				fixture := boundRuntimeFixture(t)
				tree, err := fixture.runtime.tree(false)
				if err != nil {
					t.Fatal(err)
				}
				owner, err := readRuntimeOwner(tree)
				if err != nil {
					t.Fatal(err)
				}
				owner.GuestSHA256, owner.K3sSHA256 = input.guest, input.k3s
				err = writeRuntimeOwner(tree, owner)
				tree.directory.Close()
				if err != nil {
					t.Fatal(err)
				}
				before := captureRepairCustody(t, fixture)
				err = action.run(fixture.runtime)
				assertMatrixFailure(t, err, ReasonLocalDataUnavailable)
				if len(fixture.calls) != before.start {
					t.Fatal("incompatible inputs ran native commands")
				}
				assertMatrixCustody(t, fixture, before)
			})
		}
	}
}

func TestRetainedCurrentInputsReuseWithoutBootstrapWrites(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	err := fixture.runtime.Shutdown(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	before := captureRepairCustody(t, fixture)
	// The fixture's generic start simulates fresh creation. A retained start must
	// instead leave the existing files untouched, as the production command asks.
	runner := &matrixRunner{runtimeFixture: fixture, retainedStart: true}
	fixture.runtime.dependencies.runner = runner
	err = fixture.runtime.Restore(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	assertMatrixCustody(t, fixture, before)
	want := []RuntimeOperation{"verify_signature", "verify_signature", "inspect_launcher", "probe_vm", "start_vm", "check_kubernetes"}
	assertMatrixOperations(t, fixture.calls[before.start:], want)
}

type matrixRunner struct {
	*runtimeFixture
	retainedStart       bool
	failure             RuntimeOperation
	output              string
	checks              int
	deadlineAfterChecks int
	createdDisk         os.FileInfo
}

func (runner *matrixRunner) Run(ctx context.Context, command nativeCommand) (commandOutput, error) {
	if command.Operation == "start_vm" && runner.retainedStart {
		runner.calls = append(runner.calls, command)
		if !reflect.DeepEqual(command.Arguments, []string{"start", "--tty=false", InstanceName}) || command.Input != nil || command.Capture {
			runner.t.Fatal("retained start changed command contract")
		}
		runner.running = true
		if runner.failure == "start_vm" {
			return commandOutput{}, &commandExit{Code: 1}
		}
		return commandOutput{}, nil
	}
	if command.Operation == runner.failure && (command.Operation != "check_bootstrap" || strings.Contains(strings.Join(command.Arguments, " "), "deployment/local-path-provisioner")) {
		runner.calls = append(runner.calls, command)
		switch command.Operation {
		case "check_bootstrap":
			err := repairCommand(command, kubeArguments("-n", "local-path-storage", "rollout", "status", "deployment/local-path-provisioner", "--timeout=90s"), false, false)
			if err != nil {
				runner.t.Fatal(err)
			}
		case "apply_provisioner":
			err := repairCommand(command, kubeArguments("apply", "-f", "/var/lib/personastack/bootstrap/provisioner.yaml"), false, false)
			if err != nil {
				runner.t.Fatal(err)
			}
		case "check_kubernetes":
			err := repairCommand(command, kubeArguments("get", "--raw=/readyz"), false, false)
			if err != nil {
				runner.t.Fatal(err)
			}
			runner.checks++
			if runner.checks == runner.deadlineAfterChecks {
				<-ctx.Done()
				return commandOutput{}, ctx.Err()
			}
		}
		return commandOutput{Stderr: []byte(runner.output)}, &commandExit{Code: 1}
	}
	output, err := runner.runtimeFixture.Run(ctx, command)
	if command.Operation == "start_vm" && err == nil {
		runner.createdDisk, err = os.Stat(filepath.Join(runner.runtime.options.Root, "l", InstanceName, "disk"))
	}
	return output, err
}

func TestRetainedIndependentStartFailureStopsOwnedVMAndKeepsCustody(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	err := fixture.runtime.Shutdown(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	before := captureRepairCustody(t, fixture)
	fixture.runtime.dependencies.runner = &matrixRunner{runtimeFixture: fixture, retainedStart: true, failure: "start_vm"}
	err = fixture.runtime.Start(context.Background(), runtimeTestScope())
	assertMatrixFailure(t, err, ReasonSetupFailed)
	if errors.Is(err, context.Canceled) || fixture.running {
		t.Fatal("independent start failure was cancellation or left VM running")
	}
	assertMatrixCustody(t, fixture, before)
	assertMatrixOperations(t, fixture.calls[before.start:], []RuntimeOperation{"verify_signature", "verify_signature", "inspect_launcher", "probe_vm", "start_vm", "verify_signature", "verify_signature", "inspect_launcher", "stop_vm", "probe_vm", "check_disk_handles"})
}

func TestRetainedKubernetesDeadlineExhaustsRetriesWithoutRepair(t *testing.T) {
	t.Parallel()
	for _, running := range []bool{false, true} {
		t.Run(map[bool]string{false: "startedByAttempt", true: "alreadyRunning"}[running], func(t *testing.T) {
			t.Parallel()
			fixture := boundRuntimeFixture(t)
			if !running {
				err := fixture.runtime.Shutdown(context.Background())
				if err != nil {
					t.Fatal(err)
				}
			}
			before := captureRepairCustody(t, fixture)
			runner := &matrixRunner{runtimeFixture: fixture, retainedStart: true, failure: "check_kubernetes", deadlineAfterChecks: 2}
			fixture.runtime.dependencies.runner = runner
			ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
			defer cancel()
			err := fixture.runtime.Start(ctx, runtimeTestScope())
			assertMatrixFailure(t, err, ReasonSetupFailed)
			if !errors.Is(err, context.DeadlineExceeded) || runner.checks != 2 || fixture.running != running {
				t.Fatalf("deadline/ownership contract: checks=%d running=%v err=%v", runner.checks, fixture.running, err)
			}
			assertMatrixCustody(t, fixture, before)
			want := []RuntimeOperation{"verify_signature", "verify_signature", "inspect_launcher", "probe_vm"}
			if !running {
				want = append(want, "start_vm")
			}
			want = append(want, "check_kubernetes", "check_kubernetes")
			if !running {
				want = append(want, "verify_signature", "verify_signature", "inspect_launcher", "stop_vm", "probe_vm", "check_disk_handles")
			}
			assertMatrixOperations(t, fixture.calls[before.start:], want)
		})
	}
}

func TestInstallerDependencyFailureRetainsUnfinishedInstallation(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name      string
		operation RuntimeOperation
		output    string
	}{
		{"imagePull", "check_bootstrap", "ImagePullBackOff: synthetic unavailable image"},
		{"rbacDenied", "apply_provisioner", "Forbidden: synthetic RBAC denial"},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := newRuntimeFixture(t)
			// Reserve only synthetic local custody. Bootstrap may write its owned files,
			// but failed readiness may not promote ownership or issue a cloud binding.
			tree, err := fixture.runtime.tree(true)
			if err != nil {
				t.Fatal(err)
			}
			_, err = fixture.runtime.reserve(tree, runtimeTestScope())
			if err != nil {
				t.Fatal(err)
			}
			ownerBefore, err := os.ReadFile(filepath.Join(fixture.runtime.options.Root, "owner.json"))
			if err != nil {
				t.Fatal(err)
			}
			sentinel := []byte("synthetic untouched credential and user data")
			err = tree.write("sentinel", sentinel)
			tree.directory.Close()
			if err != nil {
				t.Fatal(err)
			}
			runner := &matrixRunner{runtimeFixture: fixture, failure: test.operation, output: test.output}
			fixture.runtime.dependencies.runner = runner
			err = fixture.runtime.Install(context.Background(), runtimeTestScope(), nil)
			assertMatrixFailure(t, err, ReasonSetupFailed)
			if fixture.running || strings.Contains(err.Error(), test.output) {
				t.Fatal("failure left VM running or leaked subprocess output")
			}
			after, err := os.ReadFile(filepath.Join(fixture.runtime.options.Root, "owner.json"))
			if err != nil || string(after) != string(ownerBefore) {
				t.Fatal("failed install promoted or replaced owner")
			}
			after, err = os.ReadFile(filepath.Join(fixture.runtime.options.Root, "sentinel"))
			if err != nil || string(after) != string(sentinel) {
				t.Fatal("failed install changed sentinel")
			}
			disk, err := os.Stat(filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "disk"))
			if err != nil || runner.createdDisk == nil || !os.SameFile(runner.createdDisk, disk) {
				t.Fatal("failed install replaced disk identity")
			}
			after, err = os.ReadFile(filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "disk"))
			if err != nil || string(after) != "retained data" {
				t.Fatal("failed install removed disk")
			}
			counts := map[RuntimeOperation]int{}
			for _, call := range fixture.calls {
				counts[call.Operation]++
				if strings.Contains(strings.Join(call.Arguments, " "), "delete") || call.Operation == "apply_native_manifest" {
					t.Fatal("failed install deleted resources or enrolled target")
				}
			}
			expectedDependencyCalls := 1
			if test.operation == "check_bootstrap" {
				expectedDependencyCalls = 2 // Ready node, then failed provisioner image rollout.
			}
			if counts["start_vm"] != 1 || counts["stop_vm"] != 1 || counts[test.operation] != expectedDependencyCalls {
				t.Fatalf("unexpected dependency retry or VM lifecycle: %v", counts)
			}
		})
	}
}

func assertMatrixFailure(t *testing.T, err error, reason Reason) {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) || failure.Reason != reason {
		t.Fatalf("got %v, want %s", err, reason)
	}
}
func assertMatrixOperations(t *testing.T, calls []nativeCommand, want []RuntimeOperation) {
	t.Helper()
	got := make([]RuntimeOperation, len(calls))
	for index, call := range calls {
		got[index] = call.Operation
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("native operations got %v, want %v", got, want)
	}
}

func assertMatrixCustody(t *testing.T, fixture *runtimeFixture, before repairCustody) {
	t.Helper()
	assertRepairCustody(t, fixture, before)
	content, err := os.ReadFile(filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "disk"))
	if err != nil || string(content) != "retained data" {
		t.Fatal("retained operation changed disk content")
	}
}
