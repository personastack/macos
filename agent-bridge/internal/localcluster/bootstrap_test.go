package localcluster

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"io"
	"reflect"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestBootstrapImageInventory(t *testing.T) {
	t.Parallel()
	images := BootstrapImages()
	for index, image := range images {
		if image.Repository == "" || image.Tag == "" {
			t.Fatal("missing archive identity")
		}
		for _, digest := range []string{image.IndexDigest, image.ARM64ManifestDigest, image.ARM64ConfigDigest} {
			data, err := hex.DecodeString(strings.TrimPrefix(digest, "sha256:"))
			if err != nil || len(data) != 32 || !strings.HasPrefix(digest, "sha256:") {
				t.Fatalf("invalid %s digest", image.Repository)
			}
		}
		if image.CacheReference() != "localhost:5000/"+image.Repository+"@"+image.IndexDigest || image.CacheTag() != "localhost:5000/"+image.Repository+":"+image.Tag {
			t.Fatal("cache aliases must retain the exact repository and immutable index")
		}
		if image.ArchiveReference() != "docker.io/"+image.Repository+":"+image.Tag {
			t.Fatal("archive provenance changed")
		}
		for other := 0; other < index; other++ {
			if images[other].Repository == image.Repository {
				t.Fatal("duplicate bootstrap image")
			}
		}
	}
	images[0].Repository = "changed"
	if BootstrapImages()[0].Repository == "changed" {
		t.Fatal("caller mutated source image inventory")
	}
}

func TestBootstrapRegistryIsolation(t *testing.T) {
	t.Parallel()
	config, err := Bootstrap()
	if err != nil {
		t.Fatal(err)
	}
	var registries struct {
		Mirrors struct {
			DockerHub struct {
				Endpoint []string `yaml:"endpoint"`
			} `yaml:"docker.io"`
		} `yaml:"mirrors"`
	}
	decoder := yaml.NewDecoder(strings.NewReader(config.Registries))
	decoder.KnownFields(true)
	err = decoder.Decode(&registries)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(registries.Mirrors.DockerHub.Endpoint, []string{"https://127.0.0.1:9"}) {
		t.Fatal("Docker Hub transport must be fenced at the dead loopback endpoint")
	}
	var k3s struct {
		Registry               string `yaml:"system-default-registry"`
		Pause                  string `yaml:"pause-image"`
		DisableDefaultEndpoint bool   `yaml:"disable-default-registry-endpoint"`
	}
	err = yaml.Unmarshal([]byte(config.K3s), &k3s)
	if err != nil {
		t.Fatal(err)
	}
	if k3s.Registry != "localhost:5000" || !k3s.DisableDefaultEndpoint || k3s.Pause != bootstrapImage("rancher/mirrored-pause").CacheReference() {
		t.Fatal("K3s must use the audited cache identity without Docker Hub fallback")
	}
}

type provisionerDocument struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name        string `yaml:"name"`
		Namespace   string `yaml:"namespace"`
		Annotations struct {
			Default    string `yaml:"storageclass.kubernetes.io/is-default-class"`
			VolumeType string `yaml:"defaultVolumeType"`
		} `yaml:"annotations"`
	} `yaml:"metadata"`
	Provisioner   string `yaml:"provisioner"`
	BindingMode   string `yaml:"volumeBindingMode"`
	ReclaimPolicy string `yaml:"reclaimPolicy"`
	Spec          struct {
		Template struct {
			Spec podImageSpec `yaml:"spec"`
		} `yaml:"template"`
	} `yaml:"spec"`
	Data struct {
		Configuration string `yaml:"config.json"`
		Setup         string `yaml:"setup"`
		Teardown      string `yaml:"teardown"`
		HelperPod     string `yaml:"helperPod.yaml"`
	} `yaml:"data"`
}

type podImageSpec struct {
	ServiceAccountName string `yaml:"serviceAccountName"`
	Containers         []struct {
		Name       string `yaml:"name"`
		Image      string `yaml:"image"`
		PullPolicy string `yaml:"imagePullPolicy"`
	} `yaml:"containers"`
}

func TestProvisionerMatchesQualifiedSchema(t *testing.T) {
	t.Parallel()
	bootstrap, err := Bootstrap()
	if err != nil {
		t.Fatal(err)
	}
	source := yamlDocuments(t, provisionerSource)
	rendered := yamlDocuments(t, bootstrap.Provisioner)
	if len(source) != 9 || len(rendered) != len(source) {
		t.Fatal("provisioner resource set changed")
	}
	classes, deployments, configs := 0, 0, 0
	for index, document := range rendered {
		var got, upstream provisionerDocument
		err = document.Decode(&got)
		if err != nil {
			t.Fatal(err)
		}
		err = source[index].Decode(&upstream)
		if err != nil {
			t.Fatal(err)
		}
		if got.Kind != upstream.Kind || got.APIVersion != upstream.APIVersion || got.Metadata.Namespace != upstream.Metadata.Namespace {
			t.Fatal("upstream API family or namespace changed")
		}
		switch got.Kind {
		case "Deployment":
			deployments++
			assertProvisionerDeployment(t, got)
		case "StorageClass":
			classes++
			assertSharedClass(t, got)
		case "ConfigMap":
			configs++
			assertSharedConfig(t, got, upstream)
		default:
			assertUnchangedResource(t, source[index], document)
		}
	}
	if classes != 1 || deployments != 1 || configs != 1 {
		t.Fatal("duplicate storage owner or unexpected setup gate")
	}
}

func assertProvisionerDeployment(t *testing.T, got provisionerDocument) {
	t.Helper()
	spec := got.Spec.Template.Spec
	if len(spec.Containers) != 1 || spec.ServiceAccountName != "local-path-provisioner-service-account" || spec.Containers[0].Image != bootstrapImage("rancher/local-path-provisioner").CacheReference() || spec.Containers[0].PullPolicy != "Never" {
		t.Fatal("provisioner must use the exact imported image and original ServiceAccount")
	}
}

func assertSharedClass(t *testing.T, got provisionerDocument) {
	t.Helper()
	if got.Metadata.Name != "personastack-local" || got.Metadata.Annotations.Default != "true" || got.Metadata.Annotations.VolumeType != "hostPath" || got.Provisioner != "rancher.io/local-path" || got.BindingMode != "Immediate" || got.ReclaimPolicy != "Delete" {
		t.Fatal("shared default storage class differs from the qualified schema")
	}
}

func assertUnchangedResource(t *testing.T, source, rendered *yaml.Node) {
	t.Helper()
	original, err := yaml.Marshal(source)
	if err != nil {
		t.Fatal(err)
	}
	actual, err := yaml.Marshal(rendered)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(original, actual) {
		t.Fatal("upstream authority/RBAC changed")
	}
}

func assertSharedConfig(t *testing.T, got, upstream provisionerDocument) {
	t.Helper()
	if got.Data.Setup != upstream.Data.Setup || got.Data.Teardown != upstream.Data.Teardown {
		t.Fatal("upstream PVC lifecycle scripts changed")
	}
	var shared struct {
		NodePathMap []struct {
			Node  string
			Paths []string
		} `json:"nodePathMap"`
		SharedPath string `json:"sharedFileSystemPath"`
	}
	jsonDecoder := json.NewDecoder(strings.NewReader(got.Data.Configuration))
	jsonDecoder.DisallowUnknownFields()
	err := jsonDecoder.Decode(&shared)
	if err != nil {
		t.Fatal(err)
	}
	if shared.NodePathMap == nil || len(shared.NodePathMap) != 0 || shared.SharedPath != "/var/lib/personastack/storage" {
		t.Fatal("RWX requires the qualified single-node shared-filesystem mode")
	}
	var helper struct {
		Kind string       `yaml:"kind"`
		Spec podImageSpec `yaml:"spec"`
	}
	err = yaml.Unmarshal([]byte(got.Data.HelperPod), &helper)
	if err != nil {
		t.Fatal(err)
	}
	if helper.Kind != "Pod" || len(helper.Spec.Containers) != 1 || helper.Spec.Containers[0].Image != bootstrapImage("rancher/mirrored-library-busybox").CacheReference() || helper.Spec.Containers[0].PullPolicy != "Never" {
		t.Fatal("helper must use the exact audited busybox bytes without pulls")
	}
}

func yamlDocuments(t *testing.T, input string) []*yaml.Node {
	t.Helper()
	decoder := yaml.NewDecoder(strings.NewReader(input))
	var documents []*yaml.Node
	for {
		var node yaml.Node
		err := decoder.Decode(&node)
		if err == io.EOF {
			return documents
		}
		if err != nil {
			t.Fatal(err)
		}
		documents = append(documents, &node)
	}
}

func TestVMConfigUsesOnlyPinnedLocalInputs(t *testing.T) {
	t.Parallel()
	paths := VMPaths{LimaHome: "/tmp/ps-vm/home", GuestImage: "/tmp/ps-vm/image with spaces.img"}
	config, err := RenderVMConfig(paths, VMResources{CPUs: 2, MemoryGiB: 2, DiskGiB: 8})
	if err != nil {
		t.Fatal(err)
	}
	var vm struct {
		CPUs   int       `yaml:"cpus"`
		Memory string    `yaml:"memory"`
		Disk   string    `yaml:"disk"`
		Images []vmImage `yaml:"images"`
		Ports  []struct {
			MustBeZero bool `yaml:"guestIPMustBeZero"`
		} `yaml:"portForwards"`
	}
	err = yaml.Unmarshal([]byte(config.YAML), &vm)
	if err != nil {
		t.Fatal(err)
	}
	if config.LimaHome != paths.LimaHome || vm.CPUs != 2 || vm.Memory != "2GiB" || vm.Disk != "8GiB" || len(vm.Images) != 1 || vm.Images[0].Location != paths.GuestImage || vm.Images[0].Arch != "aarch64" || vm.Images[0].Digest != "sha256:"+PinnedDescriptor().Artifacts[1].SHA256 {
		t.Fatal("VM must select only the pinned native guest disk")
	}
	if len(vm.Ports) != 1 || vm.Ports[0].MustBeZero {
		t.Fatal("deny-forward rule must include every guest interface")
	}
}

func TestVMConfigRejectsUnsafeNativeInputs(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		paths     VMPaths
		resources VMResources
	}{
		{"relative", VMPaths{"relative", "/tmp/image"}, VMResources{2, 2, 8}},
		{"root", VMPaths{"/", "/tmp/image"}, VMResources{2, 2, 8}},
		{"parent", VMPaths{"/tmp/root/../other", "/tmp/image"}, VMResources{2, 2, 8}},
		{"userLima", VMPaths{"/Users/test/.lima", "/tmp/image"}, VMResources{2, 2, 8}},
		{"userKube", VMPaths{"/tmp/private", "/Users/test/.kube/image"}, VMResources{2, 2, 8}},
		{"remoteImage", VMPaths{"/tmp/private", "https://example.com/image"}, VMResources{2, 2, 8}},
		{"newline", VMPaths{"/tmp/private", "/tmp/image\ncommand"}, VMResources{2, 2, 8}},
		{"longSocket", VMPaths{"/tmp/" + strings.Repeat("x", 90), "/tmp/image"}, VMResources{2, 2, 8}},
		{"cpu", VMPaths{"/tmp/private", "/tmp/image"}, VMResources{1, 2, 8}},
		{"memory", VMPaths{"/tmp/private", "/tmp/image"}, VMResources{2, 1, 8}},
		{"disk", VMPaths{"/tmp/private", "/tmp/image"}, VMResources{2, 2, 7}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			_, err := RenderVMConfig(test.paths, test.resources)
			if err == nil {
				t.Fatal("unsafe native VM inputs were accepted")
			}
		})
	}
}

func TestPrivateVMPathFitsLongNativeUserHome(t *testing.T) {
	t.Parallel()
	root := "/Users/" + strings.Repeat("u", 32) + "/Library/Application Support/PSK8s"
	_, err := RenderVMConfig(VMPaths{LimaHome: root + "/l", GuestImage: root + "/artifacts/guest"}, VMResources{2, 2, 8})
	if err != nil {
		t.Fatalf("bounded native home did not fit private socket paths: %v", err)
	}
	_, err = RenderVMConfig(VMPaths{LimaHome: root + strings.Repeat("/custom-home", 12), GuestImage: root + "/artifacts/guest"}, VMResources{2, 2, 8})
	if err == nil {
		t.Fatal("oversized custom home was accepted")
	}
}
