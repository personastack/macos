package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/personastack/macos/agent-bridge/internal/localcluster"
)

func TestLocalClusterSupportsLongAccountHomePath(t *testing.T) {
	t.Parallel()
	home := filepath.Join("/Users", strings.Repeat("u", 32))
	directory := filepath.Join(home, "Library", "Application Support", "PersonaStack", "AgentBridge")
	_, _, err := localClusterForBundle(context.Background(), directory, "/Applications/PersonaStack.app")
	if err != nil {
		t.Fatalf("native socket paths do not fit a long account home: %v", err)
	}
}

func TestLocalClusterHelperPreparationDoesNotInstallOrCreateData(t *testing.T) {
	t.Parallel()
	// Keep this synthetic path below the real macOS Unix-socket limit.
	directory, err := os.MkdirTemp("/tmp", "ps-mac-main-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	canonical, err := filepath.EvalSymlinks(directory)
	if err != nil {
		t.Fatal(err)
	}
	directory = canonical
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	manager, cluster, err := localClusterForBundle(ctx, filepath.Join(directory, "PersonaStack", "AgentBridge"), filepath.Join(directory, "PersonaStack.app"))
	if err != nil {
		t.Fatal(err)
	}
	requirements := cluster.Requirements()
	if requirements.CPUs != localClusterResources.CPUs || requirements.MemoryBytes != uint64(localClusterResources.MemoryGiB)*(1<<30) || requirements.DiskBytes != uint64(localClusterResources.DiskGiB)*(1<<30) || requirements.InitialDownloadBytes != 870442303 || requirements.MinimumHostMemoryBytes != 2*requirements.MemoryBytes {
		t.Fatalf("helper requirements diverge from runtime inputs: %+v", requirements)
	}
	status, err := manager.RuntimeStatus(ctx)
	if err != nil || status.Installed || status.Running || status.Enabled || status.InstallerActive || status.Reason != localcluster.ReasonNone {
		t.Fatalf("helper preparation claimed a local runtime: %+v, %v", status, err)
	}
	enabled, err := cluster.Enabled()
	if err != nil || enabled {
		t.Fatalf("helper preparation enabled a local runtime: %t, %v", enabled, err)
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 0 {
		t.Fatalf("passive helper preparation created runtime files: %v, %v", entries, err)
	}
}
