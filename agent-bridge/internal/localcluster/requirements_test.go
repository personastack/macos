package localcluster

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

func TestRequirementsUsesConfiguredResourcesAndExactDownloadInputs(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	fixture.runtime.options.Resources = VMResources{CPUs: 4, MemoryGiB: 8, DiskGiB: 64}
	requirements := fixture.runtime.Requirements()
	want := RuntimeRequirements{CPUs: 4, MemoryBytes: 8 << 30, DiskBytes: 64 << 30, InitialDownloadBytes: 870442303, MinimumHostMemoryBytes: 16 << 30}
	if requirements != want {
		t.Fatalf("requirements differ from native runtime inputs: %+v", requirements)
	}
	inputs, total := installerArtifacts()
	if len(inputs) != 3 || uint64(total) != requirements.InitialDownloadBytes || inputs[0].Component != Guest || inputs[1].Component != K3s || inputs[2].Component != SystemImages {
		t.Fatal("disclosure includes different files from installer downloads")
	}
	raw, err := json.Marshal(requirements)
	if err != nil || string(raw) != `{"cpus":4,"memory_bytes":8589934592,"disk_bytes":68719476736,"initial_download_bytes":870442303,"minimum_host_memory_bytes":17179869184}` {
		t.Fatalf("requirements DTO changed: %s %v", raw, err)
	}
	_, err = os.Stat(fixture.runtime.options.Root)
	if !errors.Is(err, os.ErrNotExist) || len(fixture.calls) != 0 || len(fixture.fetched) != 0 {
		t.Fatal("requirements observation created runtime state or processes")
	}
	fixture.runtime.options.Resources = VMResources{CPUs: 2, MemoryGiB: 3, DiskGiB: 9}
	changed := fixture.runtime.Requirements()
	if changed.CPUs != 2 || changed.MemoryBytes != 3<<30 || changed.MinimumHostMemoryBytes != 6<<30 || changed.DiskBytes != 9<<30 {
		t.Fatal("requirements use hardcoded product budgets")
	}
}

func TestHostMemoryPolicyReservesHalfPhysicalMemoryForHost(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	fixture.runtime.options.Resources.MemoryGiB = 8
	for _, test := range []struct {
		name     string
		physical uint64
		allowed  bool
	}{{"eight GiB host", 8 << 30, false}, {"sixteen GiB host", 16 << 30, true}} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			err := checkHostMemory(test.physical, fixture.runtime.Requirements())
			if (err == nil) != test.allowed {
				t.Fatalf("physical-memory policy: %v", err)
			}
		})
	}
}

type memoryCapacityRunner struct{ *runtimeFixture }

func (runner memoryCapacityRunner) Run(ctx context.Context, command nativeCommand) (commandOutput, error) {
	if command.Operation == "check_host_memory" {
		runner.calls = append(runner.calls, command)
		return commandOutput{Stdout: []byte("8589934592\n")}, nil
	}
	return runner.runtimeFixture.Run(ctx, command)
}

func TestInsufficientPhysicalMemoryRejectsInstallBeforeDownloadOrStart(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	fixture.runtime.options.Resources.MemoryGiB = 8
	fixture.runtime.dependencies.capacity = nil
	fixture.runtime.dependencies.runner = memoryCapacityRunner{fixture}
	err := fixture.runtime.Install(context.Background(), runtimeTestScope(), nil)
	var failure *Failure
	if !errors.As(err, &failure) || failure.Reason != ReasonResourceUnavailable {
		t.Fatalf("eight GiB host admitted an eight GiB VM: %v", err)
	}
	if len(fixture.fetched) != 0 || fixture.running {
		t.Fatal("memory rejection downloaded files or started a VM")
	}
	for _, call := range fixture.calls {
		if call.Operation == "start_vm" {
			t.Fatal("rejected memory capacity invoked VM start")
		}
	}
}
