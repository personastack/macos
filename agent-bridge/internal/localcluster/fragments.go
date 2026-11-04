package localcluster

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
