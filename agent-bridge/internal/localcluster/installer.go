package localcluster

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// Install implements the one Manager workflow. Cancellation joins the command
// process group and confirms stop of any VM this attempt started. Verified
// artifacts and the VM disk are retained. It never creates a cloud connection.
func (runtime *Runtime) Install(ctx context.Context, scope Scope, report func(Progress)) (result error) {
	lockErr := runtime.acquire(ctx)
	if lockErr != nil {
		return lockErr
	}
	defer runtime.release()
	ctx, cancel := context.WithTimeout(ctx, 20*time.Minute)
	defer cancel()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if !runtime.dependencies.supported() {
		return runtimeFailure(ctx, ReasonUnsupportedHost, fmt.Errorf("requires an Apple Silicon Mac with macOS 14 or newer"))
	}
	if !validScope(scope) {
		return ErrInvalidScope
	}
	tree, err := runtime.tree(true)
	if err != nil {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	defer tree.directory.Close()
	owner, err := runtime.reserve(tree, scope)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	if owner.Removed {
		return runtimeFailure(ctx, ReasonLocalDataRemoved, fmt.Errorf("explicit blank setup is required after removal"))
	}
	if owner.Bootstrapped {
		return runtime.start(ctx, tree, owner)
	}
	return runtime.installFresh(ctx, tree, owner, report)
}

func (runtime *Runtime) installFresh(ctx context.Context, tree *ownedTree, owner runtimeOwner, report func(Progress)) (result error) {
	err := runtime.prepareDirectories()
	if err != nil {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	err = runtime.verifyBundle(ctx)
	if err != nil {
		return err
	}
	inputs, total := installerArtifacts()
	err = runtime.checkCapacity(ctx, tree, total)
	if err != nil {
		return runtimeFailure(ctx, ReasonResourceUnavailable, err)
	}
	completed := int64(0)
	progress := func(stage Stage) {
		if report != nil {
			report(Progress{Stage: stage, CompletedBytes: completed, TotalBytes: total})
		}
	}
	progress(StageDownloading)
	for _, artifact := range inputs {
		err = runtime.dependencies.fetch(ctx, tree, runtime.dependencies.client, artifact)
		if err != nil {
			return runtimeFailure(ctx, ReasonArtifactUnavailable, err)
		}
		completed += artifact.Size
		progress(StageDownloading)
	}
	progress(StageVerifying)
	bootstrap, err := Bootstrap()
	if err != nil {
		return runtimeFailure(ctx, ReasonComponentUnverified, err)
	}
	config, err := runtime.prepareVM(ctx, tree)
	if err != nil {
		return err
	}
	started := false
	defer func() {
		if result != nil && started {
			result = runtime.abortStartedVM(ctx, result)
		}
	}()
	progress(StageStarting)
	started = true
	err = runtime.startVM(ctx, config)
	if err != nil {
		return runtimeFailure(ctx, ReasonSetupFailed, err)
	}
	err = runtime.bootstrapGuest(ctx, tree, bootstrap)
	if err != nil {
		return runtimeFailure(ctx, ReasonSetupFailed, err)
	}
	progress(StageChecking)
	err = runtime.checkBootstrap(ctx)
	if err != nil {
		return runtimeFailure(ctx, ReasonSetupFailed, err)
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	owner.Enabled, owner.Bootstrapped = true, true
	owner.pinBootstrapInputs()
	err = writeRuntimeOwner(tree, owner)
	if err != nil {
		return runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	return nil
}

func (runtime *Runtime) prepareVM(ctx context.Context, tree *ownedTree) (*VMConfiguration, error) {
	config, err := RenderVMConfig(VMPaths{LimaHome: filepath.Join(runtime.options.Root, "l"), GuestImage: filepath.Join(runtime.options.Root, "artifacts", string(Guest))}, runtime.options.Resources)
	if err != nil {
		return nil, runtimeFailure(ctx, ReasonUnsupportedHost, err)
	}
	err = tree.write("vm.yaml", []byte(config.YAML))
	if err != nil {
		return nil, runtimeFailure(ctx, ReasonLocalDataUnavailable, err)
	}
	existing := runtime.retainedDisk(tree)
	if errors.Is(existing, os.ErrNotExist) {
		return &config, nil
	}
	if existing != nil {
		return nil, runtimeFailure(ctx, ReasonLocalDataUnavailable, existing)
	}
	state, err := runtime.vmState(ctx)
	if err != nil {
		return nil, err
	}
	if state != "Stopped" {
		return nil, runtimeFailure(ctx, ReasonSetupFailed, fmt.Errorf("stop the existing VM before retrying setup"))
	}
	return nil, nil
}

func installerArtifacts() ([]Artifact, int64) {
	var inputs []Artifact
	total := int64(0)
	for _, artifact := range PinnedDescriptor().Artifacts {
		if artifact.Component == Guest || artifact.Component == K3s || artifact.Component == SystemImages {
			inputs = append(inputs, artifact)
			total += artifact.Size
		}
	}
	return inputs, total
}

func (runtime *Runtime) prepareDirectories() error {
	for _, name := range []string{"home", "tmp", "l"} {
		tree, err := openOwnedTree(filepath.Join(runtime.options.Root, name), true)
		if err != nil {
			return err
		}
		tree.directory.Close()
	}
	return nil
}

func (runtime *Runtime) checkCapacity(ctx context.Context, tree *ownedTree, downloadBytes int64) error {
	resources := runtime.options.Resources
	if runtime.dependencies.capacity != nil {
		return runtime.dependencies.capacity(ctx, tree, resources, downloadBytes)
	}
	requirements := runtime.Requirements()
	if requirements.CPUs > goruntime.NumCPU() {
		return fmt.Errorf("requested local runtime CPU capacity is unavailable")
	}
	output, err := runtime.command(ctx, "check_host_memory", "/usr/sbin/sysctl", []string{"-n", "hw.memsize"}, nil, true)
	if err != nil {
		return err
	}
	memory, err := strconv.ParseUint(strings.TrimSpace(string(output.Stdout)), 10, 64)
	if err != nil {
		return fmt.Errorf("observe local runtime host memory: %w", err)
	}
	err = checkHostMemory(memory, requirements)
	if err != nil {
		return err
	}
	var disk unix.Statfs_t
	err = unix.Fstatfs(int(tree.directory.Fd()), &disk)
	if err != nil {
		return fmt.Errorf("observe local runtime disk: %w", err)
	}
	available := uint64(disk.Bavail) * uint64(disk.Bsize)
	if requirements.DiskBytes > available || uint64(downloadBytes) > available-requirements.DiskBytes {
		return fmt.Errorf("requested local runtime disk capacity is unavailable")
	}
	return nil
}

func (runtime *Runtime) bootstrapGuest(ctx context.Context, tree *ownedTree, bootstrap BootstrapConfiguration) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	for _, item := range []struct {
		component Component
		name      string
	}{{K3s, "k3s"}, {SystemImages, "airgap.tar.zst"}} {
		file, err := tree.open("artifacts/"+string(item.component), os.O_RDONLY)
		if err != nil {
			return err
		}
		err = runtime.uploadGuest(ctx, item.name, file)
		file.Close()
		if err != nil {
			return err
		}
	}
	for _, item := range []struct{ name, content string }{{"k3s.yaml", bootstrap.K3s}, {"registries.yaml", bootstrap.Registries}, {"provisioner.yaml", bootstrap.Provisioner}, {"prepare-storage.sh", bootstrap.PrepareStorage}, {"k3s.service", k3sUnit}} {
		err := runtime.uploadGuest(ctx, item.name, strings.NewReader(item.content))
		if err != nil {
			return err
		}
	}
	_, err := runtime.guest(ctx, "bootstrap_kubernetes", []string{"/bin/sh", "-c", guestBootstrapScript()}, nil, false)
	if err != nil {
		return err
	}
	err = runtime.waitKubernetes(ctx)
	if err != nil {
		return err
	}
	_, err = runtime.guest(ctx, "apply_provisioner", kubeArguments("apply", "-f", "/var/lib/personastack/bootstrap/provisioner.yaml"), nil, false)
	return err
}

func (runtime *Runtime) uploadGuest(ctx context.Context, name string, input io.Reader) error {
	switch name {
	case "k3s", "airgap.tar.zst", "k3s.yaml", "registries.yaml", "provisioner.yaml", "prepare-storage.sh", "k3s.service":
	default:
		return fmt.Errorf("unsupported source-owned guest file")
	}
	path := "/var/lib/personastack/bootstrap/" + name
	script := "set -eu\numask 077\ntest ! -L /var/lib/personastack\ntest ! -L /var/lib/personastack/bootstrap\nmkdir -p /var/lib/personastack/bootstrap\ntest ! -L " + path + "\ncat > " + path + "\n"
	_, err := runtime.guest(ctx, "stage_bootstrap_file", []string{"/bin/sh", "-c", script}, input, false)
	return err
}

func guestBootstrapScript() string {
	pins := PinnedDescriptor().Artifacts
	return fmt.Sprintf(`set -eu
cd /var/lib/personastack/bootstrap
test "$(stat -c %%s k3s)" = %d
test "$(stat -c %%s airgap.tar.zst)" = %d
printf '%%s  %%s\n' %s k3s %s airgap.tar.zst | sha256sum -c -
/bin/sh prepare-storage.sh
install -m 0755 k3s /usr/local/bin/k3s
mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/agent/images
install -m 0600 k3s.yaml /etc/rancher/k3s/config.yaml
install -m 0600 registries.yaml /etc/rancher/k3s/registries.yaml
install -m 0600 airgap.tar.zst /var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar.zst
install -m 0644 k3s.service /etc/systemd/system/personastack-k3s.service
systemctl daemon-reload
systemctl enable --now personastack-k3s.service
`, pins[2].Size, pins[3].Size, pins[2].SHA256, pins[3].SHA256)
}

const k3sUnit = `[Unit]
Description=PersonaStack managed Kubernetes
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server --config /etc/rancher/k3s/config.yaml
KillMode=process
Delegate=yes
LimitNOFILE=1048576
TasksMax=infinity
TimeoutStartSec=180
[Install]
WantedBy=multi-user.target
`

func (runtime *Runtime) checkBootstrap(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	commands := [][]string{
		kubeArguments("wait", "--for=condition=Ready", "node/personastack-local", "--timeout=90s"),
		kubeArguments("-n", "local-path-storage", "rollout", "status", "deployment/local-path-provisioner", "--timeout=90s"),
		kubeArguments("-n", "kube-system", "rollout", "status", "deployment/coredns", "--timeout=90s"),
		kubeArguments("-n", "kube-system", "rollout", "status", "deployment/metrics-server", "--timeout=90s"),
	}
	for _, args := range commands {
		_, err := runtime.guest(ctx, "check_bootstrap", args, nil, false)
		if err != nil {
			return err
		}
	}
	return nil
}

var _ Workflow = (*Runtime)(nil)
