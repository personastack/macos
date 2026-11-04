// Package localcluster owns source-only inputs for the managed Mac runtime.
package localcluster

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/url"
	"strings"
)

// Component identifies one immutable upstream qualification input.
type Component string

const (
	Lima                Component = "lima"
	Guest               Component = "guest"
	K3s                 Component = "k3s"
	SystemImages        Component = "system_images"
	ProvisionerManifest Component = "provisioner_manifest"
)

// Artifact records upstream bytes. A verified archive is not execution approval.
type Artifact struct {
	Component     Component
	Version       string
	OS            string
	Architecture  string
	URL           string
	SHA256        string
	Size          int64
	ProvenanceURL string
}

// Descriptor pins the feasibility candidate. The kernel is inside the guest disk.
// This is not an installer input until native images and signed VZ qualify.
type Descriptor struct {
	MinimumMacOS string
	GuestKernel  string
	Artifacts    [5]Artifact
}

// PinnedDescriptor returns an independent copy of the source-owned candidate.
func PinnedDescriptor() Descriptor {
	return Descriptor{
		MinimumMacOS: "14.0",
		GuestKernel:  "6.8.0-142.142",
		Artifacts: [5]Artifact{
			{Lima, "2.2.1", "darwin", "arm64",
				"https://github.com/lima-vm/lima/releases/download/v2.2.1/lima-2.2.1-Darwin-arm64.tar.gz",
				"9e9eacce88f37e185c346bad73aa6136f738d8cdf8c3bb23cd42b071824bc66e", 38328082,
				"https://github.com/lima-vm/lima/releases/download/v2.2.1/SHA256SUMS"},
			{Guest, "24.04-20260926", "linux", "arm64",
				"https://cloud-images.ubuntu.com/releases/noble/release-20260926/ubuntu-24.04-server-cloudimg-arm64.img",
				"1d6bffe64b848468ac97f821d369a4846d983de1800ccf6b5ec8853e85cefc55", 620224512,
				"https://cloud-images.ubuntu.com/releases/noble/release-20260926/SHA256SUMS"},
			{K3s, "1.37.1+k3s1", "linux", "arm64",
				"https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s-arm64",
				"a1561ca4aef8b99f5588a840d4468ac39c8c1cd92470bbcb9634823fa221741a", 73728162,
				"https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/sha256sum-arm64.txt"},
			{SystemImages, "1.37.1+k3s1", "linux", "arm64",
				"https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s-airgap-images-arm64.tar.zst",
				"b3bd28d3a20144927b25ebb1d255a16ce55bb050b9af5e63abd1bf91c0838fe5", 176489629,
				"https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/sha256sum-arm64.txt"},
			{ProvisionerManifest, "0.0.37", "", "",
				"https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml",
				"9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65", 4547,
				"https://github.com/rancher/local-path-provisioner/blob/v0.0.37/deploy/local-path-storage.yaml"},
		},
	}
}

// VerifyArtifact checks exact length and SHA-256 against the source pin. It reads
// at most one byte beyond the expected size. It does not download or extract.
func VerifyArtifact(component Component, input io.Reader) error {
	for _, artifact := range PinnedDescriptor().Artifacts {
		if artifact.Component == component {
			return verifyArtifact(artifact, input)
		}
	}
	return fmt.Errorf("unsupported local runtime component %q", component)
}

func verifyArtifact(artifact Artifact, input io.Reader) error {
	err := artifact.validate()
	if err != nil {
		return fmt.Errorf("validate %s artifact pin: %w", artifact.Component, err)
	}
	hash := sha256.New()
	size, err := io.Copy(hash, io.LimitReader(input, artifact.Size+1))
	if err != nil {
		return fmt.Errorf("read %s artifact: %w", artifact.Component, err)
	}
	if size != artifact.Size {
		return fmt.Errorf("%s artifact size mismatch", artifact.Component)
	}
	if hex.EncodeToString(hash.Sum(nil)) != artifact.SHA256 {
		return fmt.Errorf("%s artifact digest mismatch", artifact.Component)
	}
	return nil
}

func (artifact Artifact) validate() error {
	parsed, err := url.Parse(artifact.URL)
	if err != nil {
		return fmt.Errorf("parse %s artifact URL: %w", artifact.Component, err)
	}
	if parsed.Scheme != "https" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return fmt.Errorf("%s artifact needs a pinned HTTPS URL", artifact.Component)
	}
	switch parsed.Host {
	case "github.com", "raw.githubusercontent.com", "cloud-images.ubuntu.com":
	default:
		return fmt.Errorf("%s artifact has an unsupported origin", artifact.Component)
	}
	digest, err := hex.DecodeString(artifact.SHA256)
	if err != nil || len(digest) != sha256.Size || artifact.SHA256 != strings.ToLower(artifact.SHA256) {
		return fmt.Errorf("%s artifact needs a SHA-256 pin", artifact.Component)
	}
	if artifact.Size <= 0 || artifact.Version == "" {
		return fmt.Errorf("%s artifact needs a version and size", artifact.Component)
	}
	for _, moving := range []string{"/latest/", "/release/", "/master/", "/main/"} {
		if strings.Contains(parsed.Path, moving) {
			return fmt.Errorf("%s artifact must not use a moving URL", artifact.Component)
		}
	}
	return nil
}
