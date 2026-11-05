package localcluster

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

type repairRunner struct {
	*runtimeFixture
	present        bool
	unhealthy      bool
	inspectFailure bool
	diffExit       int
	createConflict bool
	checks         int
	inspections    int
	diffs          int
	creates        int
	writes         int
	prerequisites  string
	deployment     string
}

func (runner *repairRunner) Run(ctx context.Context, command nativeCommand) (commandOutput, error) {
	if command.Operation == "check_bootstrap" && strings.Contains(strings.Join(command.Arguments, " "), "deployment/local-path-provisioner") {
		runner.calls = append(runner.calls, command)
		runner.checks++
		if !runner.present || runner.unhealthy {
			return commandOutput{}, &commandExit{Code: 1}
		}
		return commandOutput{}, nil
	}
	switch command.Operation {
	case "inspect_provisioner":
		runner.calls = append(runner.calls, command)
		runner.inspections++
		err := repairCommand(command, kubeArguments("-n", "local-path-storage", "get", "deployment", "local-path-provisioner", "--ignore-not-found", "-o", "name"), true, false)
		if err != nil {
			return commandOutput{}, err
		}
		if runner.inspectFailure {
			return commandOutput{}, &commandExit{Code: 2}
		}
		if runner.present {
			return commandOutput{Stdout: []byte("deployment.apps/local-path-provisioner\n")}, nil
		}
		return commandOutput{}, nil
	case "check_provisioner_prerequisites":
		runner.calls = append(runner.calls, command)
		runner.diffs++
		err := repairCommand(command, kubeArguments("diff", "--server-side=false", "-f", "-"), false, true)
		if err != nil {
			return commandOutput{}, err
		}
		body, err := io.ReadAll(command.Input)
		if err != nil {
			return commandOutput{}, err
		}
		runner.prerequisites = string(body)
		if runner.diffExit != 0 {
			return commandOutput{}, &commandExit{Code: runner.diffExit}
		}
		return commandOutput{}, nil
	case "create_missing_provisioner":
		runner.calls = append(runner.calls, command)
		runner.creates++
		err := repairCommand(command, kubeArguments("create", "-f", "-"), false, true)
		if err != nil {
			return commandOutput{}, err
		}
		body, err := io.ReadAll(command.Input)
		if err != nil {
			return commandOutput{}, err
		}
		runner.deployment = string(body)
		if runner.createConflict {
			return commandOutput{}, &commandExit{Code: 1}
		}
		if runner.present {
			return commandOutput{}, fmt.Errorf("unexpected overwrite of existing Deployment")
		}
		runner.present = true
		runner.writes++
		return commandOutput{}, nil
	case "apply_provisioner", "bootstrap_kubernetes", "apply_native_manifest", "stage_bootstrap_file":
		return commandOutput{}, fmt.Errorf("unexpected protected mutation during Repair: %s", command.Operation)
	default:
		return runner.runtimeFixture.Run(ctx, command)
	}
}

func repairCommand(command nativeCommand, args []string, capture, input bool) error {
	expected := append([]string{"shell", "--tty=false", InstanceName, "--", "sudo", "-n"}, args...)
	if !reflect.DeepEqual(command.Arguments, expected) || command.Capture != capture || (command.Input != nil) != input {
		return fmt.Errorf("unexpected Repair command contract")
	}
	return nil
}

type repairCustody struct {
	disk              os.FileInfo
	owner, credential []byte
	credentialPath    string
	start             int
	fetches           int
}

func captureRepairCustody(t *testing.T, fixture *runtimeFixture) repairCustody {
	t.Helper()
	disk, err := os.Stat(filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "disk"))
	if err != nil {
		t.Fatal(err)
	}
	owner, err := os.ReadFile(filepath.Join(fixture.runtime.options.Root, "owner.json"))
	if err != nil {
		t.Fatal(err)
	}
	credentialPath := filepath.Join(fixture.runtime.options.Root, "tmp", "fixture-credentials")
	credential := []byte("synthetic credential bytes remain unchanged")
	err = os.WriteFile(credentialPath, credential, 0600)
	if err != nil {
		t.Fatal(err)
	}
	return repairCustody{disk, owner, credential, credentialPath, len(fixture.calls), len(fixture.fetched)}
}
func assertRepairCustody(t *testing.T, fixture *runtimeFixture, before repairCustody) {
	t.Helper()
	after, err := os.Stat(filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "disk"))
	if err != nil || !os.SameFile(before.disk, after) {
		t.Fatal("Repair replaced retained disk")
	}
	owner, err := os.ReadFile(filepath.Join(fixture.runtime.options.Root, "owner.json"))
	if err != nil || string(owner) != string(before.owner) {
		t.Fatal("Repair changed bound owner bytes")
	}
	credential, err := os.ReadFile(before.credentialPath)
	if err != nil || string(credential) != string(before.credential) {
		t.Fatal("Repair changed credential bytes")
	}
	binding, err := fixture.runtime.Binding(context.Background(), runtimeTestScope())
	if err != nil || binding.Binding == nil || *binding.Binding != runtimeTestBinding() {
		t.Fatal("Repair changed binding")
	}
	if len(fixture.fetched) != before.fetches {
		t.Fatal("bootstrapped Repair downloaded artifacts")
	}
}

func TestExplicitRepairRejectsUnavailableProvisionerDespiteReadyAPI(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name      string
		present   bool
		unhealthy bool
		diff      int
	}{
		{"missing with changed prerequisite", false, false, 1}, {"existing unhealthy", true, true, 0}, {"existing modified and unhealthy", true, true, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := boundRuntimeFixture(t)
			before := captureRepairCustody(t, fixture)
			runner := &repairRunner{runtimeFixture: fixture, present: test.present, unhealthy: test.unhealthy, diffExit: test.diff}
			fixture.runtime.dependencies.runner = runner
			err := fixture.runtime.Install(context.Background(), runtimeTestScope(), nil)
			if err == nil || runner.checks == 0 {
				t.Fatal("Repair accepted unavailable provisioner despite ready API")
			}
			if runner.creates != 0 || runner.writes != 0 || !fixture.running {
				t.Fatal("unhealthy or ambiguous Repair mutated existing component/VM")
			}
			for _, call := range fixture.calls[before.start:] {
				if call.Operation == "start_vm" || call.Operation == "stop_vm" {
					t.Fatal("unhealthy running component triggered restart")
				}
			}
			assertRepairCustody(t, fixture, before)
		})
	}
}

func TestExplicitRepairCreatesOnlyMissingDeploymentAfterCleanDiff(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"canonical prerequisites", "extra unmanaged metadata and server defaults"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			fixture := boundRuntimeFixture(t)
			before := captureRepairCustody(t, fixture)
			runner := &repairRunner{runtimeFixture: fixture}
			fixture.runtime.dependencies.runner = runner
			err := fixture.runtime.Install(context.Background(), runtimeTestScope(), nil)
			if err != nil || runner.checks != 2 || runner.inspections != 1 || runner.diffs != 1 || runner.creates != 1 || runner.writes != 1 {
				t.Fatalf("missing component recovery: %v %+v", err, runner)
			}
			prerequisites, deployment, renderErr := provisionerRepairDocuments()
			if renderErr != nil || runner.prerequisites != prerequisites || runner.deployment != deployment {
				t.Fatal("Repair did not use canonical source renderer")
			}
			assertRepairCustody(t, fixture, before)
		})
	}
}

func TestExplicitRepairFailsClosedOnUncertainPrerequisitesOrCreateRace(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name     string
		inspect  bool
		diff     int
		conflict bool
		creates  int
	}{
		{"read unavailable", true, 0, false, 0}, {"source-owned field differs", false, 1, false, 0}, {"missing prerequisite", false, 1, false, 0}, {"diff unavailable", false, 2, false, 0}, {"create AlreadyExists race", false, 0, true, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := boundRuntimeFixture(t)
			before := captureRepairCustody(t, fixture)
			runner := &repairRunner{runtimeFixture: fixture, inspectFailure: test.inspect, diffExit: test.diff, createConflict: test.conflict}
			fixture.runtime.dependencies.runner = runner
			err := fixture.runtime.Install(context.Background(), runtimeTestScope(), nil)
			var failure *Failure
			if !errors.As(err, &failure) || failure.Reason != ReasonSetupFailed || runner.creates != test.creates || runner.writes != 0 {
				t.Fatalf("uncertain Repair did not fail closed: %v", err)
			}
			assertRepairCustody(t, fixture, before)
		})
	}
}

func TestHealthyExplicitRepairValidatesWithoutRecoveryWrites(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	before := captureRepairCustody(t, fixture)
	runner := &repairRunner{runtimeFixture: fixture, present: true}
	fixture.runtime.dependencies.runner = runner
	err := fixture.runtime.Install(context.Background(), runtimeTestScope(), nil)
	if err != nil || runner.checks != 1 || runner.inspections != 0 || runner.diffs != 0 || runner.creates != 0 {
		t.Fatalf("healthy Repair performed recovery: %v", err)
	}
	assertRepairCustody(t, fixture, before)
}

func TestOrdinaryStartAndRestoreCannotRepairComponents(t *testing.T) {
	t.Parallel()
	for _, restore := range []bool{false, true} {
		t.Run(fmt.Sprint(restore), func(t *testing.T) {
			t.Parallel()
			fixture := boundRuntimeFixture(t)
			runner := &repairRunner{runtimeFixture: fixture, present: false}
			fixture.runtime.dependencies.runner = runner
			var err error
			if restore {
				err = fixture.runtime.Restore(context.Background())
			} else {
				err = fixture.runtime.Start(context.Background(), Scope{})
			}
			if err != nil || runner.checks != 0 || runner.inspections != 0 || runner.diffs != 0 || runner.creates != 0 {
				t.Fatal("ordinary startup acquired component repair authority")
			}
		})
	}
}

func TestFailedExplicitRepairStopsOnlyVMStartedByThatAttempt(t *testing.T) {
	t.Parallel()
	fixture := boundRuntimeFixture(t)
	err := fixture.runtime.Stop(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	before := captureRepairCustody(t, fixture)
	runner := &repairRunner{runtimeFixture: fixture, present: true, unhealthy: true}
	fixture.runtime.dependencies.runner = runner
	err = fixture.runtime.Install(context.Background(), runtimeTestScope(), nil)
	if err == nil || fixture.running {
		t.Fatal("failed Repair left its newly started VM running")
	}
	assertRepairCustody(t, fixture, before)
}

func TestRepairStreamsSeparateCanonicalDeploymentAndPrerequisites(t *testing.T) {
	t.Parallel()
	prerequisites, deployment, err := provisionerRepairDocuments()
	if err != nil {
		t.Fatal(err)
	}
	decoder := yaml.NewDecoder(strings.NewReader(prerequisites))
	var kinds []string
	for {
		var doc yaml.Node
		err = decoder.Decode(&doc)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		kinds = append(kinds, yamlField(doc.Content[0], "kind").Value)
	}
	if !reflect.DeepEqual(kinds, []string{"Namespace", "ServiceAccount", "Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding", "StorageClass", "ConfigMap"}) {
		t.Fatalf("prerequisite schema: %v", kinds)
	}
	var doc yaml.Node
	createDecoder := yaml.NewDecoder(strings.NewReader(deployment))
	err = createDecoder.Decode(&doc)
	if err != nil {
		t.Fatal(err)
	}
	var extra yaml.Node
	if createDecoder.Decode(&extra) != io.EOF {
		t.Fatal("create stream contains more than the missing Deployment")
	}
	resource := doc.Content[0]
	metadata := yamlField(resource, "metadata")
	if yamlField(resource, "kind").Value != "Deployment" || yamlField(metadata, "name").Value != "local-path-provisioner" || yamlField(metadata, "namespace").Value != "local-path-storage" {
		t.Fatal("create stream changed resource identity")
	}
	container := yamlField(yamlField(yamlField(yamlField(resource, "spec"), "template"), "spec"), "containers").Content[0]
	if yamlField(container, "image").Value != bootstrapImage("rancher/local-path-provisioner").CacheReference() || yamlField(container, "imagePullPolicy").Value != "Never" {
		t.Fatal("Repair changed image custody")
	}
}
