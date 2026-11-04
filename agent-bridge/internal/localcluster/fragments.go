package localcluster

// ConfigurationFragments holds deliberately incomplete configuration. No image
// deployment, VM start, artifact download, enrollment, or consumer gate is emitted.
type ConfigurationFragments struct {
	LimaIsolation  string
	K3s            string
	Storage        string
	PrepareStorage string
}

// Fragments returns the fixed single-node policy for the qualification fixture.
// Resource budgets and runnable image references require real Mac qualification.
func Fragments() ConfigurationFragments {
	return ConfigurationFragments{
		LimaIsolation:  limaIsolation,
		K3s:            k3sConfiguration,
		Storage:        storageConfiguration,
		PrepareStorage: prepareStorage,
	}
}

const limaIsolation = `vmType: vz
arch: aarch64
mounts: []
copyToHost: []
networks:
  - vzNAT: true
ssh:
  loadDotSSHPubKeys: false
  forwardAgent: false
  forwardX11: false
  overVsock: true
containerd:
  system: false
  user: false
portForwards:
  - guestIP: "0.0.0.0"
    guestIPMustBeZero: false
    guestPortRange: [1, 65535]
    proto: any
    ignore: true
vmOpts:
  vz:
    diskImageFormat: raw
    rosetta:
      enabled: false
      binfmt: false
nestedVirtualization: false
upgradePackages: false
`

const k3sConfiguration = `node-name: personastack-local
write-kubeconfig-mode: "0600"
disable:
  - traefik
  - servicelb
  - local-storage
`

// No Deployment or helper Pod is emitted until approved image sources exist.
// Upstream manifest/RBAC provenance is pinned by PinnedDescriptor.
const storageConfiguration = `apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: personastack-local
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
    defaultVolumeType: hostPath
provisioner: rancher.io/local-path
volumeBindingMode: Immediate
reclaimPolicy: Delete
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config
  namespace: local-path-storage
data:
  config.json: |-
    {"nodePathMap":[],"sharedFileSystemPath":"/var/lib/personastack/storage"}
`

// The selected Ubuntu disk supplies ext4. Refuse another filesystem rather than
// formatting an existing disk. There is no automatic data deletion or repair.
const prepareStorage = `#!/bin/sh
set -eu
storage=/var/lib/personastack/storage
parent=/var/lib
if [ "$(findmnt -n -o FSTYPE --target "$parent")" != ext4 ]; then
  echo "local runtime requires guest-local ext4 storage" >&2
  exit 1
fi
if [ -L /var/lib/personastack ] || [ -L "$storage" ]; then
  echo "local runtime storage path must not be a symbolic link" >&2
  exit 1
fi
mkdir -p "$storage"
if [ "$(findmnt -n -o FSTYPE --target "$storage")" != ext4 ]; then
  echo "local runtime storage must remain on guest-local ext4" >&2
  exit 1
fi
`
