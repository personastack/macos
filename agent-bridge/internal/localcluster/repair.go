package localcluster

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Only explicit Install/Repair may recreate the missing owned Deployment.
// Existing resources are never applied, patched, deleted or restarted here.
func (runtime *Runtime) repairBootstrap(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	healthErr := runtime.checkBootstrap(ctx)
	if healthErr == nil {
		return nil
	}
	output, err := runtime.guest(ctx, "inspect_provisioner", kubeArguments("-n", "local-path-storage", "get", "deployment", "local-path-provisioner", "--ignore-not-found", "-o", "name"), nil, true)
	if err != nil {
		return fmt.Errorf("inspect missing provisioner: %w", err)
	}
	if len(bytes.TrimSpace(output.Stdout)) != 0 {
		return fmt.Errorf("existing bootstrap component is unhealthy: %w", healthErr)
	}
	prerequisites, deployment, err := provisionerRepairDocuments()
	if err != nil {
		return err
	}
	// diff checks the canonical source-owned field change-set. Server defaults
	// and fields outside that ownership remain untouched. Its output is discarded.
	_, err = runtime.guest(ctx, "check_provisioner_prerequisites", kubeArguments("diff", "--server-side=false", "-f", "-"), strings.NewReader(prerequisites), false)
	if err != nil {
		return fmt.Errorf("provisioner prerequisites differ or could not be verified: %w", err)
	}
	// create fails closed if another actor creates the Deployment after inspection.
	_, err = runtime.guest(ctx, "create_missing_provisioner", kubeArguments("create", "-f", "-"), strings.NewReader(deployment), false)
	if err != nil {
		return fmt.Errorf("create missing provisioner: %w", err)
	}
	return runtime.checkBootstrap(ctx)
}

// Both streams come from the same verified source renderer as fresh bootstrap.
func provisionerRepairDocuments() (string, string, error) {
	config, err := Bootstrap()
	if err != nil {
		return "", "", err
	}
	decoder := yaml.NewDecoder(strings.NewReader(config.Provisioner))
	var remaining, missing bytes.Buffer
	for {
		var document yaml.Node
		err = decoder.Decode(&document)
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", "", fmt.Errorf("decode canonical provisioner: %w", err)
		}
		resource := document.Content[0]
		target := &remaining
		if yamlField(resource, "kind").Value == "Deployment" {
			metadata := yamlField(resource, "metadata")
			if missing.Len() != 0 || yamlField(metadata, "name").Value != "local-path-provisioner" || yamlField(metadata, "namespace").Value != "local-path-storage" {
				return "", "", fmt.Errorf("unexpected canonical provisioner identity")
			}
			target = &missing
		}
		if target.Len() != 0 {
			_, _ = target.WriteString("---\n")
		}
		encoder := yaml.NewEncoder(target)
		encoder.SetIndent(2)
		err = encoder.Encode(&document)
		if err != nil {
			return "", "", fmt.Errorf("encode canonical provisioner: %w", err)
		}
		err = encoder.Close()
		if err != nil {
			return "", "", fmt.Errorf("finish canonical provisioner: %w", err)
		}
	}
	if missing.Len() == 0 || remaining.Len() == 0 {
		return "", "", fmt.Errorf("canonical provisioner resources are incomplete")
	}
	return remaining.String(), missing.String(), nil
}
