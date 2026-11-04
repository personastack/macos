# Managed local cluster qualification inputs

This package owns the pinned upstream feasibility candidate and isolated configuration fragments. The helper does not call this package yet. There is no installer, VM launcher, enrollment, readiness projection, or user-facing setup.

`PinnedDescriptor` records Lima 2.2.1 for Darwin ARM64, Ubuntu 24.04 release-20260926 for Linux ARM64, K3s 1.37.1+k3s1, its ARM64 airgap archive, and the upstream local-path-provisioner 0.0.37 manifest. The Ubuntu disk contains kernel package `linux-image-6.8.0-142-generic` version `6.8.0-142.142`. Kernel identity follows that disk's digest. There is no moving guest-image fallback.

Artifact hashes and lengths were checked against upstream release metadata and checksum files on 2026-11-04. The provisioner manifest hash was calculated from the exact tagged raw file. Its pin is provenance only. Do not apply that unmodified upstream manifest. `VerifyArtifact` verifies exact byte length and SHA-256 without executing or extracting input.

`Fragments` supplies VZ NAT isolation, K3s configuration, and shared-filesystem storage configuration. Lima isolation intentionally omits images and resource budgets. It disables host-directory mounts, service port forwards, SSH-agent forwarding, host kubeconfig copying, Rosetta, and Lima's second containerd. Lima's private guest-control channel is separate from service forwarding. The macOS 14 app baseline exceeds Lima VZ's macOS 13.5 minimum. The phase-1 isolated VZ smoke started this exact upstream launcher and pinned guest successfully on 2026-11-04. The launcher is ad hoc signed. PersonaStack Developer ID/hardened-runtime distribution remains unqualified.

The K3s fragment disables Traefik, ServiceLB, and packaged local-storage. It preserves normal DNS, CNI, kube-proxy, network policy, and node leases. The storage fragment declares one default `Filesystem`-capable hostPath class. Shared-filesystem mode uses an empty `nodePathMap` and guest-local ext4. `Immediate` binding introduces no custom consumer gate. PVC capacity is not an enforced quota. Single-node use is mandatory. The preparation script checks ext4 and never formats or deletes a disk.

Missing qualification prerequisites:

- The upstream provisioner workflow publishes its image to Docker Hub. Its default helper image also comes from Docker Hub. PersonaStack forbids these runtime image sources. No approved non-Docker-Hub provisioner or helper digest has been established. No runnable provisioner Deployment or helper Pod is generated.
- The upstream K3s airgap archive contains upstream system-image identities. Verifying its archive does not qualify those identities under PersonaStack registry policy. Its system images need an approved owner and exact immutable references before runtime installation.
- The existing API image selector, cluster-agent, provider workers, harnesses, optional browser, BuildKit, and Ship native helper need approved native ARM64 closure. This package does not select or override their images.
- Actual signed Lima VZ launcher identity, entitlements, notarization/loading behavior, private Lima home/socket paths, and artifact extraction policy need native qualification.
- Real Mac RWX mounts, retained PVC data, streams, network policy, VM restart, permission behavior, minimum resources, and download/disk headroom have not been measured. Source tests prove configuration policy and integrity handling only.

Upstream sources:

- [Lima release checksums](https://github.com/lima-vm/lima/releases/download/v2.2.1/SHA256SUMS)
- [Pinned Lima default configuration](https://github.com/lima-vm/lima/blob/v2.2.1/templates/default.yaml)
- [Lima VZ NAT](https://lima-vm.io/docs/config/network/vznat/)
- [Ubuntu disk checksums](https://cloud-images.ubuntu.com/releases/noble/release-20260926/SHA256SUMS)
- [Ubuntu guest package manifest](https://cloud-images.ubuntu.com/releases/noble/release-20260926/ubuntu-24.04-server-cloudimg-arm64.manifest)
- [K3s ARM64 release checksums](https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/sha256sum-arm64.txt)
- [Provisioner shared-filesystem contract](https://github.com/rancher/local-path-provisioner/blob/v0.0.37/README.md#configuration)
- [Provisioner image publication workflow](https://github.com/rancher/local-path-provisioner/blob/v0.0.37/.github/workflows/build.yml)

This is internal source groundwork. Public customer behavior is unchanged. Public guide generation and runtime availability claims are deferred until the feasibility gate passes.

The smoke fixture found Lima normalizes an omitted `guestIPMustBeZero` to true for the wildcard rule. The source fragment explicitly sets false to deny service forwarding for both wildcard-bound and loopback-bound guest services. Its private SSH control listener is not a forwarded application service.
