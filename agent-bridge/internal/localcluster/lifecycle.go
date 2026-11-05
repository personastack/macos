package localcluster

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Enabled reads persisted native intent without probing or mutating the VM.
func (runtime *Runtime) Enabled() (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	lockErr := runtime.acquire(ctx)
	if lockErr != nil {
		return false, lockErr
	}
	defer runtime.release()
	tree, err := runtime.tree(false)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer tree.directory.Close()
	owner, err := readRuntimeOwner(tree)
	if errors.Is(err, os.ErrNotExist) {
		return false, runtime.missingOwnerObservation(ctx, tree)
	}
	return owner.Enabled, err
}

func (runtime *Runtime) Start(ctx context.Context, scope Scope) error {
	lockErr := runtime.acquire(ctx)
	if lockErr != nil {
		return lockErr
	}
	defer runtime.release()
	tree, err := runtime.tree(false)
	if err != nil {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	defer tree.directory.Close()
	owner, err := runtime.owner(tree, scope)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	return runtime.start(ctx, tree, owner, false)
}

// Restore runs once on helper startup. It never creates a VM or authorizes a new
// enrollment. A removed/missing retained disk remains an explicit failure.
func (runtime *Runtime) Restore(ctx context.Context) error {
	lockErr := runtime.acquire(ctx)
	if lockErr != nil {
		return lockErr
	}
	defer runtime.release()
	tree, err := runtime.tree(false)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer tree.directory.Close()
	owner, err := readRuntimeOwner(tree)
	if errors.Is(err, os.ErrNotExist) {
		return runtime.missingOwnerObservation(ctx, tree)
	}
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	if !owner.Enabled {
		return nil
	}
	return runtime.start(ctx, tree, owner, false)
}

func (runtime *Runtime) start(ctx context.Context, tree *ownedTree, owner runtimeOwner, explicitRepair bool) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if owner.Removed {
		return runtimeFailure(ctx, ReasonLocalDataRemoved, fmt.Errorf("explicit blank setup is required after removal"))
	}
	if !owner.Bootstrapped {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, fmt.Errorf("runtime bootstrap is incomplete"))
	}
	if !owner.compatibleInputs() {
		return runtimeCustodyFailure(ctx, errors.New("retained runtime input version requires explicit repair"))
	}
	err := runtime.retainedDisk(tree)
	if err != nil {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	err = runtime.verifyBundle(ctx)
	if err != nil {
		return err
	}
	state, err := runtime.vmState(ctx)
	if err != nil {
		return err
	}
	started := state == "Stopped"
	if started {
		err = runtime.startVM(ctx, nil)
		if err != nil {
			return runtime.abortStartedVM(ctx, err)
		}
	}
	err = runtime.waitKubernetes(ctx)
	if err == nil && explicitRepair {
		err = runtime.repairBootstrap(ctx)
	}
	if err != nil {
		if started {
			return runtime.abortStartedVM(ctx, err)
		}
		return runtimeFailure(ctx, ReasonSetupFailed, err)
	}
	owner.Enabled = true
	return writeRuntimeOwner(tree, owner)
}

func (runtime *Runtime) waitKubernetes(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	for {
		_, err := runtime.guest(ctx, "check_kubernetes", kubeArguments("get", "--raw=/readyz"), nil, false)
		if err == nil {
			return nil
		}
		timer := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

func (runtime *Runtime) startVM(ctx context.Context, config *VMConfiguration) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	args := []string{"start", "--tty=false"}
	if config == nil {
		args = append(args, InstanceName)
	} else {
		args = append(args, "--name="+InstanceName, filepath.Join(runtime.options.Root, "vm.yaml"))
	}
	_, err := runtime.limaCommand(ctx, "start_vm", args, nil, false)
	return err
}

// Stop records disabled intent before stopping. A stop failure remains a failure
// even when disabled intent was saved. It never deletes the retained disk.
func (runtime *Runtime) Stop(ctx context.Context) error {
	lockErr := runtime.acquire(ctx)
	if lockErr != nil {
		return lockErr
	}
	defer runtime.release()
	return runtime.stop(ctx, false)
}

// Shutdown observes VM stop while retaining enabled intent for the next login.
func (runtime *Runtime) Shutdown(ctx context.Context) error {
	lockErr := runtime.acquire(ctx)
	if lockErr != nil {
		return lockErr
	}
	defer runtime.release()
	return runtime.stop(ctx, true)
}

func (runtime *Runtime) stop(ctx context.Context, preserveIntent bool) error {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	tree, err := runtime.tree(false)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	defer tree.directory.Close()
	owner, err := readRuntimeOwner(tree)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	if err == nil && !preserveIntent {
		owner.Enabled = false
		err = writeRuntimeOwner(tree, owner)
		if err != nil {
			return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
		}
	}
	err = runtime.retainedDisk(tree)
	if errors.Is(err, os.ErrNotExist) {
		_, instanceErr := os.Lstat(filepath.Join(runtime.options.Root, "l", InstanceName))
		if errors.Is(instanceErr, os.ErrNotExist) {
			return nil
		}
		if instanceErr != nil {
			return runtimeFailure(ctx, ReasonLocalDataUnavailable, instanceErr)
		}
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	err = runtime.verifyBundle(ctx)
	if err != nil {
		return err
	}
	return runtime.observeStoppedVM(ctx, tree)
}

func (runtime *Runtime) observeStoppedVM(ctx context.Context, tree *ownedTree) error {
	pid, err := runtime.hostAgentPID(tree)
	if err != nil {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	_, err = runtime.limaCommand(ctx, "stop_vm", []string{"stop", "--tty=false", InstanceName}, nil, false)
	if err != nil {
		return runtimeFailure(ctx, ReasonStopFailed, err)
	}
	state, err := runtime.vmState(ctx)
	if err != nil {
		return err
	}
	if state != "Stopped" {
		return runtimeFailure(ctx, ReasonStopFailed, errors.New("VM stop not observed"))
	}
	if pid > 0 && runtime.dependencies.alive(pid) {
		return runtimeFailure(ctx, ReasonStopFailed, errors.New("owned host agent still running"))
	}
	return runtime.observeClosedDisk(ctx)
}

func (runtime *Runtime) observeClosedDisk(ctx context.Context) error {
	disk := filepath.Join(runtime.options.Root, "l", InstanceName, "disk")
	output, err := runtime.command(ctx, "check_disk_handles", "/usr/sbin/lsof", []string{"-t", disk}, nil, true)
	var exit *commandExit
	if errors.As(err, &exit) && exit.Code == 1 && len(bytes.TrimSpace(output.Stderr)) == 0 && len(bytes.TrimSpace(output.Stdout)) == 0 {
		return nil
	}
	if err != nil || len(bytes.TrimSpace(output.Stdout)) != 0 {
		return runtimeFailure(ctx, ReasonStopFailed, errors.New("runtime disk stop not observed"))
	}
	return nil
}

func (runtime *Runtime) hostAgentPID(tree *ownedTree) (int, error) {
	file, err := tree.open(filepath.Join("l", InstanceName, "ha.pid"), os.O_RDONLY)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, 32))
	if err != nil {
		return 0, fmt.Errorf("read owned host agent identity: %w", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(content)))
	if err != nil || pid <= 0 {
		return 0, fmt.Errorf("invalid owned host agent identity")
	}
	return pid, nil
}

func (runtime *Runtime) abortStartedVM(ctx context.Context, cause error) error {
	cleanup, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	err := runtime.stop(cleanup, true)
	if err != nil {
		return err
	}
	return runtimeFailure(ctx, ReasonSetupFailed, cause)
}

func kubeArguments(args ...string) []string {
	prefix := []string{"/usr/local/bin/k3s", "kubectl", "--kubeconfig", "/etc/rancher/k3s/k3s.yaml"}
	return append(prefix, args...)
}

// ApplyManifest accepts the API-owned installation response only from trusted
// native code. It carries secrets over stdin and never saves or logs the bytes.
func (runtime *Runtime) ApplyManifest(ctx context.Context, scope Scope, binding TargetBinding, manifest []byte) error {
	lockErr := runtime.acquire(ctx)
	if lockErr != nil {
		return lockErr
	}
	defer runtime.release()
	if !validScope(scope) {
		return ErrInvalidScope
	}
	if !validTargetBinding(binding) {
		return ErrInvalidManifest
	}
	if len(manifest) == 0 || len(manifest) > 1024*1024 {
		return runtimeFailure(ctx, ReasonSetupFailed, fmt.Errorf("native install manifest exceeds its bound"))
	}
	tree, err := runtime.tree(false)
	if err != nil {
		return err
	}
	defer tree.directory.Close()
	owner, err := runtime.owner(tree, scope)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	if owner.Removed {
		return runtimeFailure(ctx, ReasonLocalDataRemoved, fmt.Errorf("explicit blank setup is required after removal"))
	}
	if !owner.Bootstrapped || !owner.Enabled {
		return runtimeFailure(ctx, ReasonSetupFailed, fmt.Errorf("local runtime is not enabled"))
	}
	if !owner.compatibleInputs() {
		return runtimeCustodyFailure(ctx, errors.New("retained runtime input version requires explicit repair"))
	}
	err = runtime.retainedDisk(tree)
	if err != nil {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	err = runtime.verifyBundle(ctx)
	if err != nil {
		return err
	}
	err = runtime.bindTarget(ctx, tree, owner, binding)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	_, err = runtime.guest(ctx, "apply_native_manifest", kubeArguments("apply", "-f", "-"), bytes.NewReader(manifest), false)
	if err != nil {
		return runtimeFailure(ctx, ReasonSetupFailed, err)
	}
	return nil
}
