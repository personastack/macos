package localcluster

import (
	"fmt"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

const InstanceName = "p"

type vmImage struct {
	Location string `yaml:"location"`
	Arch     string `yaml:"arch"`
	Digest   string `yaml:"digest"`
}

// VMPaths comes only from the native artifact owner. The caller owns private
// directory permissions, symlink rejection, artifact verification and custody.
// Neither path is supplied by a page or accepted as authorization.
type VMPaths struct {
	LimaHome   string
	GuestImage string
}

// VMResources is an explicit native choice. No full-worker resource defaults or
// host availability claims follow from the two-CPU/two-GiB K3s fixture.
type VMResources struct {
	CPUs      int
	MemoryGiB int
	DiskGiB   int
}

// VMConfiguration preserves the private home separately from the YAML. The
// process owner must set LIMA_HOME and use the fixed InstanceName.
type VMConfiguration struct {
	LimaHome string
	YAML     string
}

// RenderVMConfig emits the complete fixed VZ VM configuration. Lima checks the
// source-owned guest digest again before using the local disk image.
func RenderVMConfig(paths VMPaths, resources VMResources) (VMConfiguration, error) {
	err := validateNativePath(paths.LimaHome)
	if err != nil {
		return VMConfiguration{}, fmt.Errorf("private Lima home: %w", err)
	}
	err = validateNativePath(paths.GuestImage)
	if err != nil {
		return VMConfiguration{}, fmt.Errorf("verified guest image: %w", err)
	}
	canonicalHome := paths.LimaHome
	if strings.HasPrefix(canonicalHome, "/tmp/") {
		canonicalHome = "/private" + canonicalHome
	}
	// Pinned Lima filenames.LongestSock includes OpenSSH's temporary suffix.
	// https://github.com/lima-vm/lima/blob/v2.2.1/pkg/limatype/filenames/filenames.go
	if len(filepath.Join(canonicalHome, InstanceName, "ssh.sock.1234567890123456")) >= 104 {
		return VMConfiguration{}, fmt.Errorf("private Lima home exceeds the macOS socket path limit")
	}
	if resources.CPUs < 2 || resources.MemoryGiB < 2 || resources.DiskGiB < 8 {
		return VMConfiguration{}, fmt.Errorf("K3s fixture requires at least two CPUs, two GiB memory and eight GiB disk")
	}
	var config struct {
		CPUs   int       `yaml:"cpus"`
		Memory string    `yaml:"memory"`
		Disk   string    `yaml:"disk"`
		Images []vmImage `yaml:"images"`
	}
	config.CPUs = resources.CPUs
	config.Memory = fmt.Sprintf("%dGiB", resources.MemoryGiB)
	config.Disk = fmt.Sprintf("%dGiB", resources.DiskGiB)
	config.Images = []vmImage{{paths.GuestImage, "aarch64", "sha256:" + PinnedDescriptor().Artifacts[1].SHA256}}
	header, err := yaml.Marshal(config)
	if err != nil {
		return VMConfiguration{}, fmt.Errorf("encode VM inputs: %w", err)
	}
	return VMConfiguration{LimaHome: paths.LimaHome, YAML: string(header) + limaIsolation}, nil
}

func validateNativePath(path string) error {
	if path == "/" || !filepath.IsAbs(path) || filepath.Clean(path) != path || strings.ContainsAny(path, "\x00\r\n") {
		return fmt.Errorf("requires a clean absolute native-owned path")
	}
	for _, part := range strings.Split(path, string(filepath.Separator)) {
		if part == ".lima" || part == ".kube" {
			return fmt.Errorf("must not adopt user Lima or Kubernetes directories")
		}
	}
	return nil
}
