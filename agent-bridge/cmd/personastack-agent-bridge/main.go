package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/buildinfo"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/control"
	"github.com/personastack/macos/agent-bridge/internal/daemon"
	"github.com/personastack/macos/agent-bridge/internal/localcluster"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println(buildinfo.VersionString())
		return
	}
	removeLocalRuntime := len(os.Args) == 2 && os.Args[1] == "--remove-local-runtime"
	if (len(os.Args) != 1 && !removeLocalRuntime) || runtime.GOOS != "darwin" || os.Geteuid() == 0 {
		log.Print("Private macOS user-session helper required.")
		os.Exit(1)
	}
	if removeLocalRuntime {
		err := removeLocalRuntimeData()
		if err != nil {
			log.Print("Local runtime removal failed. Stop background agents and retry before uninstalling PersonaStack.")
			os.Exit(1)
		}
		return
	}
	err := run()
	if err != nil {
		log.Print("Background agents unavailable. Open PersonaStack to check setup.")
		os.Exit(1)
	}
}
func run() error {
	directory, err := control.DefaultDirectory()
	if err != nil {
		return err
	}
	err = control.EnsurePrivateDirectory(directory)
	if err != nil {
		return err
	}
	owner, err := localcluster.AcquireProcessOwner(directory)
	if err != nil {
		return err
	}
	defer owner.Close()
	secrets := config.KeychainStore{}
	seed, seedErr := config.InstallationSeed(secrets)
	if seedErr != nil {
		// Local VM control does not require external-agent credentials. Keep
		// Stop and Remove available while Keychain access is unavailable.
		log.Print("External agent credentials unavailable. Open PersonaStack to check Keychain access.")
	}
	store := config.NewFileStoreWithSecrets(filepath.Join(directory, "state.json"), secrets).WithInventorySeed(seed)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	clusterManager, clusterRuntime, clusterErr := createLocalCluster(ctx, directory)
	if clusterErr != nil {
		// Cluster component failure must not disable independently enrolled
		// external agents. Native cluster operations remain unsupported.
		log.Print("Local cluster components unavailable. Open PersonaStack to check setup.")
	}
	runner := daemon.Runner{Store: store, ServiceScope: externalagentprotocol.ServiceScopeUserLaunchAgent}
	controller := &control.Controller{LocalCluster: clusterManager, Store: store, Seed: seed, ExternalCredentialsUnavailable: seedErr != nil, Environments: func() ([]control.Environment, error) { return control.LoadEnvironments(directory) }, Check: runner.CheckBinding, Repair: runner.RepairBinding, Shutdown: cancel, Stop: func() error { return os.WriteFile(filepath.Join(directory, "disabled"), []byte("disabled\n"), 0o600) }}
	if clusterRuntime != nil {
		requirements := clusterRuntime.Requirements()
		controller.LocalClusterRequirements = &requirements
	}
	if _, err := os.Stat(filepath.Join(directory, "disabled")); err == nil {
		if clusterRuntime == nil {
			return fmt.Errorf("background agents disabled")
		}
		if !localControlNeeded(clusterRuntime.Enabled) {
			return fmt.Errorf("background agents disabled and no enabled local runtime")
		}
	}
	if clusterManager != nil {
		restoreErr := clusterManager.RestoreLocal()
		if restoreErr != nil {
			log.Print("Local agents could not resume. Open PersonaStack to check this Mac.")
		}
	}
	errors := make(chan error, 2)
	go func() { errors <- runExternalAgents(ctx, seedErr == nil, runner.RunForeground) }()
	go func() { errors <- control.Serve(ctx, directory, controller) }()
	err = <-errors
	cancel()
	<-errors
	if clusterRuntime != nil {
		shutdownContext, stop := context.WithTimeout(context.Background(), 45*time.Second)
		shutdownErr := clusterRuntime.Shutdown(shutdownContext)
		stop()
		if shutdownErr != nil {
			return fmt.Errorf("stop local runtime during helper shutdown: %w", shutdownErr)
		}
	}
	return err
}

// An unreadable local intent is not proof that the VM is stopped. Retain the
// control socket so the app can report the problem and offer recovery actions.
func localControlNeeded(enabled func() (bool, error)) bool {
	value, err := enabled()
	return err != nil || value
}

func runExternalAgents(ctx context.Context, credentialsReady bool, run func(context.Context) error) error {
	if !credentialsReady {
		<-ctx.Done()
		return nil
	}
	return run(ctx)
}
