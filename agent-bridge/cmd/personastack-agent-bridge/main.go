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

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/buildinfo"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/control"
	"github.com/personastack/macos/agent-bridge/internal/daemon"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println(buildinfo.VersionString())
		return
	}
	if len(os.Args) != 1 || runtime.GOOS != "darwin" || os.Geteuid() == 0 {
		log.Print("Private macOS user-session helper required.")
		os.Exit(1)
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
	secrets := config.KeychainStore{}
	seed, err := config.InstallationSeed(secrets)
	if err != nil {
		return err
	}
	store := config.NewFileStoreWithSecrets(filepath.Join(directory, "state.json"), secrets).WithInventorySeed(seed)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	runner := daemon.Runner{Store: store, ServiceScope: externalagentprotocol.ServiceScopeUserLaunchAgent}
	controller := &control.Controller{Store: store, Seed: seed, Environments: func() ([]control.Environment, error) { return control.LoadEnvironments(directory) }, Check: runner.CheckBinding, Repair: runner.RepairBinding, Shutdown: cancel, Stop: func() error { return os.WriteFile(filepath.Join(directory, "disabled"), []byte("disabled\n"), 0o600) }}
	if _, err := os.Stat(filepath.Join(directory, "disabled")); err == nil {
		return fmt.Errorf("background agents disabled")
	}
	errors := make(chan error, 2)
	go func() { errors <- runner.RunForeground(ctx) }()
	go func() { errors <- control.Serve(ctx, directory, controller) }()
	err = <-errors
	cancel()
	<-errors
	return err
}
