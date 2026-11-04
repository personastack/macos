package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/personastack/macos/agent-bridge/internal/localcluster"
)

// These are product budgets, not measurements of the K3s-only fixture. The
// runtime owner checks host headroom before installing or starting the VM.
var localClusterResources = localcluster.VMResources{CPUs: 4, MemoryGiB: 8, DiskGiB: 64}

func createLocalCluster(ctx context.Context, directory string) (*localcluster.Manager, *localcluster.Runtime, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, nil, fmt.Errorf("locate signed background helper: %w", err)
	}
	bundle := filepath.Dir(filepath.Dir(filepath.Dir(executable)))
	return localClusterForBundle(ctx, directory, bundle)
}

func localClusterForBundle(ctx context.Context, directory, bundle string) (*localcluster.Manager, *localcluster.Runtime, error) {
	cluster, err := localcluster.NewRuntime(localcluster.RuntimeOptions{
		Root: filepath.Join(filepath.Dir(filepath.Dir(directory)), "PSK8s"), BundleDirectory: bundle,
		Resources: localClusterResources,
	})
	if err != nil {
		return nil, nil, fmt.Errorf("prepare owned local runtime: %w", err)
	}
	manager, err := localcluster.NewManager(ctx, cluster, nil)
	if err != nil {
		return nil, nil, fmt.Errorf("prepare local runtime task owner: %w", err)
	}
	return manager, cluster, nil
}
