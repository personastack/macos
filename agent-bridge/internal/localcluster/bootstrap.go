package localcluster

import (
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"strings"

	"gopkg.in/yaml.v3"
)

//go:embed localPath.upstream.yaml
var provisionerSource string

// BootstrapConfiguration supplies only installer-owned guest configuration.
// Built-in K3s CoreDNS and metrics-server remain under their normal owner.
type BootstrapConfiguration struct {
	K3s            string
	Registries     string
	Provisioner    string
	PrepareStorage string
}

// Bootstrap renders the qualified single-node bootstrap. The native installer
// must stage the verified airgap archive before starting K3s. K3s imports it and
// adds the cache aliases under system-default-registry during normal startup.
func Bootstrap() (BootstrapConfiguration, error) {
	err := VerifyArtifact(ProvisionerManifest, strings.NewReader(provisionerSource))
	if err != nil {
		return BootstrapConfiguration{}, fmt.Errorf("verify embedded provisioner: %w", err)
	}
	storage, err := renderProvisioner()
	if err != nil {
		return BootstrapConfiguration{}, fmt.Errorf("render provisioner: %w", err)
	}
	config := k3sConfiguration + "system-default-registry: " + bootstrapRegistry + "\npause-image: " + bootstrapImage("rancher/mirrored-pause").CacheReference() + "\ndisable-default-registry-endpoint: true\n"
	return BootstrapConfiguration{K3s: config, Registries: registryConfiguration, Provisioner: storage, PrepareStorage: prepareStorage}, nil
}

// The dead loopback endpoint prevents accidental Docker Hub fallback. There is
// deliberately no listener or registry service at localhost:5000 or port 9.
const registryConfiguration = `mirrors:
  docker.io:
    endpoint:
      - "https://127.0.0.1:9"
`

func renderProvisioner() (string, error) {
	decoder := yaml.NewDecoder(strings.NewReader(provisionerSource))
	var output bytes.Buffer
	encoder := yaml.NewEncoder(&output)
	encoder.SetIndent(2)
	for {
		var document yaml.Node
		err := decoder.Decode(&document)
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", fmt.Errorf("decode upstream document: %w", err)
		}
		err = transformProvisioner(document.Content[0])
		if err != nil {
			return "", err
		}
		err = encoder.Encode(&document)
		if err != nil {
			return "", fmt.Errorf("encode provisioner document: %w", err)
		}
	}
	err := encoder.Close()
	if err != nil {
		return "", fmt.Errorf("finish provisioner YAML: %w", err)
	}
	return output.String(), nil
}

// yaml.Node preserves the exact upstream RBAC, probes, setup/teardown and
// supported Pod shape. Only these explicit resource paths are changed.
func transformProvisioner(document *yaml.Node) error {
	kind := yamlField(document, "kind").Value
	switch kind {
	case "Namespace", "ServiceAccount", "Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding":
		return nil
	case "Deployment":
		spec := yamlField(yamlField(yamlField(document, "spec"), "template"), "spec")
		return pinContainer(yamlField(spec, "containers").Content[0], "rancher/local-path-provisioner")
	case "StorageClass":
		metadata := yamlField(document, "metadata")
		yamlField(metadata, "name").Value = "personastack-local"
		annotations := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		setYAMLField(annotations, "storageclass.kubernetes.io/is-default-class", "true")
		setYAMLField(annotations, "defaultVolumeType", "hostPath")
		metadata.Content = append(metadata.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "annotations"}, annotations)
		yamlField(document, "volumeBindingMode").Value = "Immediate"
		return nil
	case "ConfigMap":
		data := yamlField(document, "data")
		yamlField(data, "config.json").Value = `{"nodePathMap":[],"sharedFileSystemPath":"/var/lib/personastack/storage"}`
		helper := yamlField(data, "helperPod.yaml")
		var pod yaml.Node
		err := yaml.Unmarshal([]byte(helper.Value), &pod)
		if err != nil {
			return fmt.Errorf("decode upstream helper Pod: %w", err)
		}
		container := yamlField(yamlField(pod.Content[0], "spec"), "containers").Content[0]
		err = pinContainer(container, "rancher/mirrored-library-busybox")
		if err != nil {
			return err
		}
		rendered, err := yaml.Marshal(&pod)
		if err != nil {
			return fmt.Errorf("encode helper Pod: %w", err)
		}
		helper.Value = string(rendered)
		return nil
	default:
		return fmt.Errorf("unsupported pinned provisioner resource %q", kind)
	}
}

func pinContainer(container *yaml.Node, repository string) error {
	image := yamlField(container, "image")
	if image.Kind != yaml.ScalarNode {
		return fmt.Errorf("missing pinned provisioner image")
	}
	image.Value = bootstrapImage(repository).CacheReference()
	yamlField(container, "imagePullPolicy").Value = "Never"
	return nil
}

// These field helpers operate only on the hash-verified source template.
func yamlField(node *yaml.Node, key string) *yaml.Node {
	for index := 0; index+1 < len(node.Content); index += 2 {
		if node.Content[index].Value == key {
			return node.Content[index+1]
		}
	}
	return &yaml.Node{}
}

func setYAMLField(node *yaml.Node, key, value string) {
	node.Content = append(node.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key},
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value})
}
