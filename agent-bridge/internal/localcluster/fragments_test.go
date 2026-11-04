package localcluster

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestLimaIsolationFragment(t *testing.T) {
	t.Parallel()
	fragment := limaIsolation
	var config struct {
		VMType     string      `yaml:"vmType"`
		Arch       string      `yaml:"arch"`
		Mounts     []yaml.Node `yaml:"mounts"`
		CopyToHost []yaml.Node `yaml:"copyToHost"`
		Networks   []struct {
			VZNAT bool `yaml:"vzNAT"`
		} `yaml:"networks"`
		SSH struct {
			LoadDotSSHPubKeys bool `yaml:"loadDotSSHPubKeys"`
			ForwardAgent      bool `yaml:"forwardAgent"`
			ForwardX11        bool `yaml:"forwardX11"`
			OverVsock         bool `yaml:"overVsock"`
		} `yaml:"ssh"`
		Containerd struct {
			System bool
			User   bool
		} `yaml:"containerd"`
		PortForwards []struct {
			GuestIP           string `yaml:"guestIP"`
			GuestIPMustBeZero *bool  `yaml:"guestIPMustBeZero"`
			GuestPortRange    [2]int `yaml:"guestPortRange"`
			Proto             string
			Ignore            bool
		} `yaml:"portForwards"`
		VMOpts struct {
			VZ struct {
				DiskImageFormat string `yaml:"diskImageFormat"`
				Rosetta         struct {
					Enabled bool
					Binfmt  bool
				}
			} `yaml:"vz"`
		} `yaml:"vmOpts"`
		NestedVirtualization bool `yaml:"nestedVirtualization"`
		UpgradePackages      bool `yaml:"upgradePackages"`
	}
	decoder := yaml.NewDecoder(strings.NewReader(fragment))
	decoder.KnownFields(true)
	err := decoder.Decode(&config)
	if err != nil {
		t.Fatal(err)
	}
	if config.VMType != "vz" || config.Arch != "aarch64" || len(config.Networks) != 1 || !config.Networks[0].VZNAT {
		t.Fatal("runtime must use one native ARM64 VZ NAT instance")
	}
	if config.Mounts == nil || len(config.Mounts) != 0 || config.CopyToHost == nil || len(config.CopyToHost) != 0 {
		t.Fatal("host mounts and guest-to-host kubeconfig copying must be explicitly disabled")
	}
	if config.SSH.LoadDotSSHPubKeys || config.SSH.ForwardAgent || config.SSH.ForwardX11 || !config.SSH.OverVsock {
		t.Fatal("guest control must not adopt host SSH identities or forwarding")
	}
	if config.Containerd.System || config.Containerd.User || config.NestedVirtualization || config.UpgradePackages {
		t.Fatal("unexpected second runtime or unpinned guest upgrade")
	}
	if config.VMOpts.VZ.DiskImageFormat != "raw" || config.VMOpts.VZ.Rosetta.Enabled || config.VMOpts.VZ.Rosetta.Binfmt {
		t.Fatal("runtime must retain the macOS 14-compatible raw disk and native architecture")
	}
	if len(config.PortForwards) != 1 {
		t.Fatal("expected one deny-all service forwarding rule")
	}
	rule := config.PortForwards[0]
	if rule.GuestIP != "0.0.0.0" || rule.GuestIPMustBeZero == nil || *rule.GuestIPMustBeZero || rule.GuestPortRange != [2]int{1, 65535} || rule.Proto != "any" || !rule.Ignore {
		t.Fatal("automatic service forwarding must be disabled for every port/protocol")
	}
}

func TestK3sKeepsOneStorageOwner(t *testing.T) {
	t.Parallel()
	bootstrap, err := Bootstrap()
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		NodeName                       string   `yaml:"node-name"`
		KubeconfigMode                 string   `yaml:"write-kubeconfig-mode"`
		Disable                        []string `yaml:"disable"`
		Registry                       string   `yaml:"system-default-registry"`
		PauseImage                     string   `yaml:"pause-image"`
		DisableDefaultRegistryEndpoint bool     `yaml:"disable-default-registry-endpoint"`
	}
	decoder := yaml.NewDecoder(strings.NewReader(bootstrap.K3s))
	decoder.KnownFields(true)
	err = decoder.Decode(&config)
	if err != nil {
		t.Fatal(err)
	}
	if config.NodeName != "personastack-local" || config.KubeconfigMode != "0600" {
		t.Fatal("missing fixed node identity or private guest kubeconfig")
	}
	if strings.Join(config.Disable, ",") != "traefik,servicelb,local-storage" {
		t.Fatal("disable only unneeded ingress/LB and the conflicting storage owner; preserve DNS/CNI/network policy")
	}
}
