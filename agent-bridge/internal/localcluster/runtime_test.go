package localcluster

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type runtimeFixture struct {
	t               *testing.T
	runtime         *Runtime
	running         bool
	calls           []nativeCommand
	inputs          []string
	fetched         []Component
	failOperation   RuntimeOperation
	openHandles     bool
	start           func(context.Context) error
	unreadyChecks   int
	requireMetadata bool
}

func newRuntimeFixture(t *testing.T) *runtimeFixture {
	t.Helper()
	root := privateRuntimeTestDirectory(t)
	var err error
	fixture := &runtimeFixture{t: t}
	options := RuntimeOptions{Root: filepath.Join(root, "r"), BundleDirectory: filepath.Join(root, "app.app"), Resources: VMResources{2, 2, 8}}
	dependencies := runtimeDependencies{
		runner: fixture, supported: func() bool { return true }, alive: func(int) bool { return false },
		capacity: func(context.Context, *ownedTree, VMResources, int64) error { return nil },
		fetch: func(ctx context.Context, tree *ownedTree, _ *http.Client, artifact Artifact) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			fixture.fetched = append(fixture.fetched, artifact.Component)
			return tree.write("artifacts/"+string(artifact.Component), []byte("test verified bytes"))
		},
	}
	fixture.runtime, err = newRuntime(options, dependencies)
	if err != nil {
		t.Fatal(err)
	}
	writeTestBundle(t, options.BundleDirectory)
	return fixture
}

func privateRuntimeTestDirectory(t *testing.T) string {
	t.Helper()
	// Native custody rejects symlinked ancestors, and Lima needs short sockets.
	// macOS's default temporary directory can violate both constraints.
	root, err := os.MkdirTemp("/tmp", "ps-runtime-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	return canonical
}

func writeTestBundle(t *testing.T, bundle string) {
	t.Helper()
	base := filepath.Join(bundle, "Contents", "Resources", "LocalCluster", "lima")
	var manifest sealedLimaManifest
	manifest.Schema, manifest.Sealed = 1, true
	pin := PinnedDescriptor().Artifacts[0]
	manifest.Artifact.Version, manifest.Artifact.URL, manifest.Artifact.SHA256, manifest.Artifact.Size = pin.Version, pin.URL, pin.SHA256, pin.Size
	files := []struct {
		path   string
		target *string
	}{{"bin/limactl", &manifest.Files.Launcher}, {"share/lima/lima-guestagent.Linux-aarch64.gz", &manifest.Files.Agent}, {"share/doc/lima/LICENSE", &manifest.Files.License}, {"share/doc/lima/VERSION", &manifest.Files.Version}}
	for _, file := range files {
		path := filepath.Join(base, file.path)
		err := os.MkdirAll(filepath.Dir(path), 0700)
		if err != nil {
			t.Fatal(err)
		}
		content := []byte("sealed test resource " + file.path)
		err = os.WriteFile(path, content, 0600)
		if err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(content)
		*file.target = hex.EncodeToString(digest[:])
	}
	content, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	err = os.WriteFile(filepath.Join(base, "runtime-manifest.json"), content, 0600)
	if err != nil {
		t.Fatal(err)
	}
}

func runtimeTestScope() Scope {
	return Scope{AppOrigin: "https://my.personastack.ai", AccountID: "account-a", WorkspaceID: "workspace-a", DocumentID: "550e8400-e29b-41d4-a716-446655440000"}
}

func (fixture *runtimeFixture) Run(ctx context.Context, command nativeCommand) (commandOutput, error) {
	fixture.calls = append(fixture.calls, command)
	if command.Capture && command.Input != nil {
		return commandOutput{}, fmt.Errorf("unplanned captured secret input")
	}
	if command.Operation == fixture.failOperation {
		return commandOutput{}, fmt.Errorf("planned native failure")
	}
	if fixture.requireMetadata && (command.Operation == "probe_vm" || command.Operation == "stop_vm") {
		_, err := os.Stat(filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "lima.yaml"))
		if err != nil {
			return commandOutput{}, &commandExit{Code: 1}
		}
	}
	if command.Operation == "check_kubernetes" && fixture.unreadyChecks > 0 {
		fixture.unreadyChecks--
		return commandOutput{}, &commandExit{Code: 1}
	}
	if command.Input != nil {
		data, err := io.ReadAll(io.LimitReader(command.Input, 1024*1024+1))
		if err != nil {
			return commandOutput{}, err
		}
		fixture.inputs = append(fixture.inputs, string(data))
	}
	switch command.Operation {
	case "verify_signature":
		if command.Executable != "/usr/bin/codesign" {
			return commandOutput{}, fmt.Errorf("unexpected signature executable")
		}
		if !strings.Contains(strings.Join(command.Arguments, " "), `certificate leaf = H"bbafb291a3d54ff75ea476a66b60878a81754e4d"`) {
			return commandOutput{}, fmt.Errorf("missing persistent certificate pin")
		}
		return commandOutput{}, nil
	case "inspect_launcher":
		return commandOutput{Stdout: []byte(`<plist><dict><key>com.apple.security.virtualization</key><true/></dict></plist>`), Stderr: []byte("flags=0x10000(runtime)")}, nil
	case "start_vm":
		fixture.running = true
		path := filepath.Join(fixture.runtime.options.Root, "l", InstanceName)
		err := os.MkdirAll(path, 0700)
		if err != nil {
			return commandOutput{}, err
		}
		err = os.WriteFile(filepath.Join(path, "disk"), []byte("retained data"), 0600)
		if err != nil {
			return commandOutput{}, err
		}
		err = os.WriteFile(filepath.Join(path, "lima.yaml"), []byte("owned VM definition"), 0600)
		if err != nil {
			return commandOutput{}, err
		}
		if fixture.start != nil {
			return commandOutput{}, fixture.start(ctx)
		}
		return commandOutput{}, nil
	case "probe_vm":
		state := "Stopped"
		if fixture.running {
			state = "Running"
		}
		return commandOutput{Stdout: []byte(`{"name":"` + InstanceName + `","status":"` + state + `"}`)}, nil
	case "stop_vm":
		fixture.running = false
		return commandOutput{}, nil
	case "check_disk_handles":
		if fixture.openHandles {
			return commandOutput{Stdout: []byte("123\n")}, nil
		}
		return commandOutput{}, &commandExit{Code: 1}
	case "probe_kubernetes", "check_kubernetes", "check_bootstrap", "stage_bootstrap_file", "bootstrap_kubernetes", "apply_provisioner", "apply_native_manifest":
		if command.Executable != fixture.runtime.lima || len(command.Arguments) < 6 || command.Arguments[0] != "shell" {
			return commandOutput{}, fmt.Errorf("unexpected guest command")
		}
		return commandOutput{}, nil
	default:
		return commandOutput{}, fmt.Errorf("unplanned operation %q", command.Operation)
	}
}

func TestRuntimePassiveAbsentDoesNotCreateNativeData(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	status, err := fixture.runtime.Probe(context.Background(), Scope{})
	if err != nil || status.Installed || status.Enabled || status.Running {
		t.Fatalf("absent status: %+v %v", status, err)
	}
	enabled, err := fixture.runtime.Enabled()
	if err != nil || enabled {
		t.Fatalf("absent intent: %v %v", enabled, err)
	}
	if len(fixture.calls) != 0 {
		t.Fatal("passive absent status ran commands")
	}
	_, err = os.Stat(fixture.runtime.options.Root)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatal("passive observation created root")
	}
}

func TestRuntimeInstallProbeStopAndRetainedResume(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx := context.Background()
	scope := runtimeTestScope()
	var progress []Progress
	err := fixture.runtime.Install(ctx, scope, func(value Progress) { progress = append(progress, value) })
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(fixture.fetched, []Component{Guest, K3s, SystemImages}) {
		t.Fatalf("unplanned artifact sources: %v", fixture.fetched)
	}
	for index := 1; index < len(progress); index++ {
		if !validProgress(progress[index-1], progress[index]) {
			t.Fatal("installer progress regressed")
		}
	}
	status, err := fixture.runtime.Probe(ctx, scope)
	if err != nil || !status.Installed || !status.Running || !status.Enabled || !status.KubernetesAvailable {
		t.Fatalf("installed status: %+v %v", status, err)
	}
	foreign := scope
	foreign.WorkspaceID = "workspace-b"
	before := len(fixture.calls)
	_, err = fixture.runtime.Probe(ctx, foreign)
	if !errors.Is(err, ErrOccupied) || len(fixture.calls) != before {
		t.Fatal("foreign observation accessed protected runtime")
	}
	err = fixture.runtime.Stop(ctx)
	if err != nil {
		t.Fatal(err)
	}
	status, err = fixture.runtime.Probe(ctx, Scope{})
	if err != nil || !status.Installed || status.Running || status.Enabled {
		t.Fatalf("stopped status: %+v %v", status, err)
	}
	fetched := len(fixture.fetched)
	err = fixture.runtime.Start(ctx, Scope{})
	if err != nil {
		t.Fatal(err)
	}
	if len(fixture.fetched) != fetched {
		t.Fatal("resume downloaded or recreated installation")
	}
	err = fixture.runtime.Shutdown(ctx)
	if err != nil {
		t.Fatal(err)
	}
	enabled, err := fixture.runtime.Enabled()
	if err != nil || !enabled {
		t.Fatal("shutdown erased enabled intent")
	}
	err = fixture.runtime.Restore(ctx)
	if err != nil || !fixture.running {
		t.Fatalf("restore failed: %v", err)
	}
}

func TestRuntimeMissingRetainedDiskNeverRecreatesIdentity(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx := context.Background()
	scope := runtimeTestScope()
	err := fixture.runtime.Install(ctx, scope, nil)
	if err != nil {
		t.Fatal(err)
	}
	err = fixture.runtime.Shutdown(ctx)
	if err != nil {
		t.Fatal(err)
	}
	err = os.Remove(filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "disk"))
	if err != nil {
		t.Fatal(err)
	}
	before := len(fixture.calls)
	for _, operation := range []func() error{func() error { return fixture.runtime.Restore(ctx) }, func() error { return fixture.runtime.Start(ctx, Scope{}) }, func() error { return fixture.runtime.Install(ctx, scope, nil) }} {
		err = operation()
		if err == nil {
			t.Fatal("missing retained disk was recreated")
		}
	}
	if len(fixture.calls) != before {
		t.Fatal("missing retained disk caused a process or download")
	}
}

func TestRuntimeCancelledStartJoinsAndStopsOwnedVM(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fixture.start = func(ctx context.Context) error { cancel(); <-ctx.Done(); return ctx.Err() }
	err := fixture.runtime.Install(ctx, runtimeTestScope(), nil)
	if !errors.Is(err, context.Canceled) || fixture.running {
		t.Fatalf("cancelled install retained a running VM: %v", err)
	}
	fileErr := func() error {
		_, err := os.Stat(filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "disk"))
		return err
	}()
	if fileErr != nil {
		t.Fatal("cancellation removed retained disk")
	}
}

func TestRuntimeManifestUsesScopedStdinAndNoCredentialLogs(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx := context.Background()
	scope := runtimeTestScope()
	err := fixture.runtime.Install(ctx, scope, nil)
	if err != nil {
		t.Fatal(err)
	}
	foreign := scope
	foreign.AccountID = "another-account"
	before := len(fixture.calls)
	err = fixture.runtime.ApplyManifest(ctx, foreign, runtimeTestBinding(), []byte("secret-value"))
	if !errors.Is(err, ErrOccupied) || len(fixture.calls) != before {
		t.Fatal("foreign manifest caused protected work")
	}
	err = fixture.runtime.ApplyManifest(ctx, scope, runtimeTestBinding(), []byte("native-secret-value"))
	if err != nil {
		t.Fatal(err)
	}
	last := fixture.calls[len(fixture.calls)-1]
	if last.Capture || strings.Contains(strings.Join(last.Arguments, " "), "secret") || fixture.inputs[len(fixture.inputs)-1] != "native-secret-value" {
		t.Fatal("manifest escaped native stdin custody")
	}
	logs, _ := json.Marshal(fixture.runtime.Diagnostics())
	if strings.Contains(string(logs), "secret") {
		t.Fatal("credentials entered diagnostic logs")
	}
	err = fixture.runtime.ApplyManifest(ctx, scope, runtimeTestBinding(), make([]byte, 1024*1024+1))
	if err == nil {
		t.Fatal("unbounded native manifest accepted")
	}
}

func TestRuntimeStopRequiresObservedDiskHandleClosure(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx := context.Background()
	err := fixture.runtime.Install(ctx, runtimeTestScope(), nil)
	if err != nil {
		t.Fatal(err)
	}
	fixture.openHandles = true
	err = fixture.runtime.Stop(ctx)
	if err == nil {
		t.Fatal("stop succeeded with retained disk handles")
	}
	enabled, err := fixture.runtime.Enabled()
	if err != nil || enabled {
		t.Fatal("failed explicit stop retained automatic resume intent")
	}
	fixture.openHandles = false
	err = fixture.runtime.Stop(ctx)
	if err != nil {
		t.Fatal(err)
	}
}

func runtimeTestBinding() TargetBinding {
	return TargetBinding{IntegrationID: "cluster-a", InstallationID: strings.Repeat("a", 64)}
}

func TestRetainedResumeWaitsForKubernetesStartup(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	ctx := context.Background()
	err := fixture.runtime.Install(ctx, runtimeTestScope(), nil)
	if err != nil {
		t.Fatal(err)
	}
	err = fixture.runtime.Stop(ctx)
	if err != nil {
		t.Fatal(err)
	}
	fixture.unreadyChecks = 1
	err = fixture.runtime.Start(ctx, Scope{})
	if err != nil || !fixture.running || fixture.unreadyChecks != 0 {
		t.Fatalf("ordinary K3s startup was treated as terminal: %v", err)
	}
}
