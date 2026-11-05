package localcluster

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// RuntimeOptions is constructed by native code, never decoded from a page.
type RuntimeOptions struct {
	Root            string
	BundleDirectory string
	Resources       VMResources
}

type RuntimeStatus struct {
	Installed           bool   `json:"installed"`
	Running             bool   `json:"running"`
	KubernetesAvailable bool   `json:"kubernetes_available"`
	Enabled             bool   `json:"enabled"`
	Reason              Reason `json:"safe_reason,omitempty"`
	Action              Action `json:"action"`
	Message             string `json:"message,omitempty"`
}

type RuntimeOperation string

type RuntimeEvent struct {
	Operation RuntimeOperation
	Duration  time.Duration
	Succeeded bool
}
type runtimeDependencies struct {
	client    *http.Client
	runner    commandRunner
	supported func() bool
	alive     func(int) bool
	fetch     func(context.Context, *ownedTree, *http.Client, Artifact, func(int64)) error
	capacity  func(context.Context, *ownedTree, VMResources, int64) error
	device    func(int) (uint64, error)
}

// Runtime owns one private VM. It never publishes cloud readiness or credentials.
type Runtime struct {
	gate         chan struct{}
	options      RuntimeOptions
	dependencies runtimeDependencies
	lima         string
	events       []RuntimeEvent
	eventsMu     sync.Mutex
}

func NewRuntime(options RuntimeOptions) (*Runtime, error) {
	return newRuntime(options, runtimeDependencies{client: artifactClient(), runner: processRunner{}, supported: supportedRuntimeHost, alive: func(pid int) bool { return unix.Kill(pid, 0) != unix.ESRCH }})
}

func newRuntime(options RuntimeOptions, dependencies runtimeDependencies) (*Runtime, error) {
	err := validateNativePath(options.Root)
	if err != nil {
		return nil, fmt.Errorf("configure native runtime root: %w", err)
	}
	_, err = RenderVMConfig(VMPaths{LimaHome: filepath.Join(options.Root, "l"), GuestImage: filepath.Join(options.Root, "artifacts", string(Guest))}, options.Resources)
	if err != nil {
		return nil, fmt.Errorf("configure private runtime: %w", err)
	}
	err = validateNativePath(options.BundleDirectory)
	if err != nil {
		return nil, fmt.Errorf("configure signed runtime bundle: %w", err)
	}
	if dependencies.fetch == nil {
		dependencies.fetch = acquireArtifact
	}
	if dependencies.device == nil {
		dependencies.device = removalDevice
	}
	return &Runtime{gate: make(chan struct{}, 1), options: options, dependencies: dependencies, lima: filepath.Join(options.BundleDirectory, "Contents", "Resources", "LocalCluster", "lima", "bin", "limactl")}, nil
}

func supportedRuntimeHost() bool {
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		return false
	}
	var host unix.Utsname
	if unix.Uname(&host) != nil {
		return false
	}
	major, _, _ := strings.Cut(string(host.Release[:]), ".")
	version, err := strconv.Atoi(major)
	return err == nil && version >= 23
}

func (runtime *Runtime) command(ctx context.Context, operation RuntimeOperation, executable string, args []string, input io.Reader, capture bool) (commandOutput, error) {
	if ctx.Err() != nil {
		return commandOutput{}, ctx.Err()
	}
	start := time.Now()
	root := runtime.options.Root
	command := nativeCommand{Operation: operation, Executable: executable, Arguments: args, Input: input, Capture: capture,
		Environment: []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + filepath.Join(root, "home"), "LIMA_HOME=" + filepath.Join(root, "l"), "TMPDIR=" + filepath.Join(root, "tmp"), "LANG=C", "LC_ALL=C"}}
	output, err := runtime.dependencies.runner.Run(ctx, command)
	runtime.eventsMu.Lock()
	if len(runtime.events) == 32 {
		runtime.events = runtime.events[1:]
	}
	runtime.events = append(runtime.events, RuntimeEvent{Operation: operation, Duration: time.Since(start), Succeeded: err == nil})
	runtime.eventsMu.Unlock()
	return output, err
}

func (runtime *Runtime) limaCommand(ctx context.Context, operation RuntimeOperation, args []string, input io.Reader, capture bool) (commandOutput, error) {
	return runtime.command(ctx, operation, runtime.lima, args, input, capture)
}

func (runtime *Runtime) guest(ctx context.Context, operation RuntimeOperation, args []string, input io.Reader, capture bool) (commandOutput, error) {
	prefix := []string{"shell", "--tty=false", InstanceName, "--", "sudo", "-n"}
	return runtime.limaCommand(ctx, operation, append(prefix, args...), input, capture)
}

// Diagnostics contains finite operation names only. Child output, arguments,
// manifests, filesystem contents and credentials are never retained as logs.
func (runtime *Runtime) Diagnostics() []RuntimeEvent {
	runtime.eventsMu.Lock()
	defer runtime.eventsMu.Unlock()
	return append([]RuntimeEvent(nil), runtime.events...)
}

func runtimeFailure(ctx context.Context, reason Reason, err error) error {
	if errors.Is(ctx.Err(), context.Canceled) {
		return ctx.Err()
	}
	var failure *Failure
	if errors.As(err, &failure) {
		return err
	}
	if errors.Is(err, unix.ENOSPC) || errors.Is(err, unix.EDQUOT) {
		reason = ReasonResourceUnavailable
	}
	return fmt.Errorf("%w: %w", &Failure{Reason: reason}, err)
}

func runtimeCustodyFailure(ctx context.Context, err error) error {
	if errors.Is(err, ErrOccupied) || errors.Is(err, ErrInvalidScope) {
		return err
	}
	return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
}

func (runtime *Runtime) tree(create bool) (*ownedTree, error) {
	return openOwnedTree(runtime.options.Root, create)
}

func (runtime *Runtime) reserve(tree *ownedTree, scope Scope) (runtimeOwner, error) {
	if !validScope(scope) {
		return runtimeOwner{}, ErrInvalidScope
	}
	owner, err := readRuntimeOwner(tree)
	if err == nil {
		if !owner.matches(scope) {
			return runtimeOwner{}, ErrOccupied
		}
		return owner, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return runtimeOwner{}, err
	}
	_, statErr := os.Lstat(filepath.Join(runtime.options.Root, "l", InstanceName))
	if !errors.Is(statErr, os.ErrNotExist) {
		return runtimeOwner{}, fmt.Errorf("unowned runtime instance exists")
	}
	owner = runtimeOwner{Version: 1, AppOrigin: scope.AppOrigin, AccountID: scope.AccountID, WorkspaceID: scope.WorkspaceID}
	err = writeRuntimeOwner(tree, owner)
	return owner, err
}

func (runtime *Runtime) owner(tree *ownedTree, scope Scope) (runtimeOwner, error) {
	owner, err := readRuntimeOwner(tree)
	if err != nil {
		return owner, err
	}
	if scope != (Scope{}) && (!validScope(scope) || !owner.matches(scope)) {
		return owner, ErrOccupied
	}
	return owner, nil
}

func (runtime *Runtime) retainedDisk(tree *ownedTree) error {
	file, err := tree.open(filepath.Join("l", InstanceName, "disk"), os.O_RDONLY)
	if err != nil {
		return fmt.Errorf("retained runtime disk unavailable: %w", err)
	}
	return file.Close()
}

func (runtime *Runtime) Probe(ctx context.Context, scope Scope) (RuntimeStatus, error) {
	err := runtime.acquire(ctx)
	if err != nil {
		return RuntimeStatus{}, err
	}
	defer runtime.release()
	return runtime.probe(ctx, scope)
}

func (runtime *Runtime) probe(ctx context.Context, scope Scope) (RuntimeStatus, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	status := RuntimeStatus{Action: ActionNone}
	tree, err := runtime.tree(false)
	if errors.Is(err, os.ErrNotExist) {
		return status, nil
	}
	if err != nil {
		return status, runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	defer tree.directory.Close()
	owner, err := runtime.owner(tree, scope)
	if errors.Is(err, os.ErrNotExist) {
		return status, runtime.missingOwnerObservation(ctx, tree)
	}
	if err != nil {
		return status, runtimeCustodyFailure(ctx, err)
	}
	status.Enabled = owner.Enabled
	if owner.Removed {
		present, presentErr := tree.hasDirectory("l/" + InstanceName)
		if presentErr != nil {
			return status, runtimeCustodyFailure(ctx, presentErr)
		}
		if present {
			return status, runtimeCustodyFailure(ctx, fmt.Errorf("local removal has not finished"))
		}
		status.Reason = ReasonLocalDataRemoved
		return status, nil
	}
	err = runtime.retainedDisk(tree)
	if err != nil {
		if !owner.Bootstrapped && errors.Is(err, os.ErrNotExist) {
			return status, nil
		}
		return status, runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	status.Installed = owner.Bootstrapped
	if owner.Bootstrapped && !owner.compatibleInputs() {
		return status, runtimeCustodyFailure(ctx, errors.New("retained runtime input version requires explicit repair"))
	}
	err = runtime.verifyBundle(ctx)
	if err != nil {
		return status, err
	}
	state, err := runtime.vmState(ctx)
	if err != nil {
		return status, err
	}
	status.Running = state == "Running"
	if status.Running {
		_, healthErr := runtime.guest(ctx, "probe_kubernetes", kubeArguments("get", "--raw=/readyz"), nil, false)
		status.KubernetesAvailable = healthErr == nil
		if healthErr != nil {
			return status, runtimeFailure(ctx, ReasonStatusUnavailable, healthErr)
		}
	}
	return status, nil
}

func (runtime *Runtime) vmState(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	output, err := runtime.limaCommand(ctx, "probe_vm", []string{"list", "--json", InstanceName}, nil, true)
	if err != nil {
		return "", runtimeFailure(ctx, ReasonStatusUnavailable, err)
	}
	var vm struct {
		Name   string `json:"name"`
		Status string `json:"status"`
	}
	err = json.Unmarshal(output.Stdout, &vm)
	if err != nil || vm.Name != InstanceName {
		return "", runtimeFailure(ctx, ReasonLocalDataUnavailable, errors.New("private VM observation unavailable"))
	}
	if vm.Status != "Running" && vm.Status != "Stopped" {
		return "", runtimeFailure(ctx, ReasonStatusUnavailable, errors.New("private VM state unknown"))
	}
	return vm.Status, nil
}

func (runtime *Runtime) acquire(ctx context.Context) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	select {
	case runtime.gate <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (runtime *Runtime) release() { <-runtime.gate }

var _ RuntimeWorkflow = (*Runtime)(nil)

func (runtime *Runtime) missingOwnerObservation(ctx context.Context, tree *ownedTree) error {
	present, err := tree.hasDirectory("l/" + InstanceName)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	if present {
		return runtimeCustodyFailure(ctx, fmt.Errorf("native owner metadata is missing for a retained VM"))
	}
	return nil
}
