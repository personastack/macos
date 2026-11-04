package control

import (
	"context"
	"encoding/json"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/personastack/macos/agent-bridge/internal/localcluster"
)

func disclosureFixture() localcluster.RuntimeRequirements {
	return localcluster.RuntimeRequirements{CPUs: 4, MemoryBytes: 8 << 30, DiskBytes: 64 << 30, InitialDownloadBytes: 870442303, MinimumHostMemoryBytes: 16 << 30}
}

func TestUnfilteredStatusDisclosesRuntimeRequirementsWithoutSetup(t *testing.T) {
	t.Parallel()
	for _, unavailable := range []bool{false, true} {
		t.Run(map[bool]string{false: "normal", true: "external credentials unavailable"}[unavailable], func(t *testing.T) {
			t.Parallel()
			controller, _, _ := fixture(t)
			if unavailable {
				controller, _, _ = unavailableCredentialsFixture(t)
			}
			var installs atomic.Int32
			manager, err := localcluster.NewManager(context.Background(), localClusterWorkflowFunc(func(context.Context, localcluster.Scope, func(localcluster.Progress)) error {
				installs.Add(1)
				return nil
			}), nil)
			if err != nil {
				t.Fatal(err)
			}
			requirements := disclosureFixture()
			controller.LocalCluster, controller.LocalClusterRequirements = manager, &requirements
			response := dispatchCluster(t, controller, "status", BindingPayload{})
			if response.Error != nil || response.Result == nil || response.Result.LocalClusterRequirements == nil || *response.Result.LocalClusterRequirements != requirements || installs.Load() != 0 {
				t.Fatalf("passive requirements unavailable or setup ran: %+v", response)
			}
			raw, err := json.Marshal(response.Result)
			if err != nil || !strings.Contains(string(raw), `"local_cluster_requirements":{"cpus":4,"memory_bytes":8589934592,"disk_bytes":68719476736,"initial_download_bytes":870442303,"minimum_host_memory_bytes":17179869184}`) {
				t.Fatalf("requirements DTO missing: %s %v", raw, err)
			}
			if strings.Contains(string(raw), `"external_error"`) != unavailable || strings.Contains(string(raw), `"connections"`) == unavailable {
				t.Fatalf("existing external status contract changed: %s", raw)
			}
		})
	}
}

func TestRequirementsOmittedFromUninitializedStatusAndLegacyResults(t *testing.T) {
	t.Parallel()
	requirements := disclosureFixture()
	controller, _, _ := fixture(t)
	controller.LocalClusterRequirements = &requirements
	response := dispatchCluster(t, controller, "status", BindingPayload{})
	if response.Error != nil || response.Result.LocalClusterRequirements != nil {
		t.Fatal("uninitialized controller advertised install requirements")
	}
	for _, test := range []struct {
		operation    string
		requirements *localcluster.RuntimeRequirements
	}{
		{"status", nil}, {"check", &requirements}, {"repair", &requirements},
	} {
		t.Run(test.operation, func(t *testing.T) {
			t.Parallel()
			raw, err := json.Marshal(Result{Operation: test.operation, LocalClusterRequirements: test.requirements})
			if err != nil || string(raw) != `{"connections":[]}` {
				t.Fatalf("legacy result shape changed: %s %v", raw, err)
			}
		})
	}
}
