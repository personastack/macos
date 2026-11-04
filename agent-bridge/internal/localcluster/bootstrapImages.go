package localcluster

// BootstrapImage identifies one image inside the checksum-pinned ARM64 K3s
// airgap archive. Cache references are containerd identities, not a registry service.
type BootstrapImage struct {
	Repository          string
	Tag                 string
	IndexDigest         string
	ARM64ManifestDigest string
	ARM64ConfigDigest   string
}

const bootstrapRegistry = "localhost:5000"

// CacheReference selects exactly the verified archive index without network pull.
func (image BootstrapImage) CacheReference() string {
	return bootstrapRegistry + "/" + image.Repository + "@" + image.IndexDigest
}

// ArchiveReference names the identity present in the verified upstream archive.
func (image BootstrapImage) ArchiveReference() string {
	return "docker.io/" + image.Repository + ":" + image.Tag
}

// CacheTag is the alias used by K3s' built-in manifests. Normal K3s airgap import
// adds it alongside CacheReference using system-default-registry.
func (image BootstrapImage) CacheTag() string {
	return bootstrapRegistry + "/" + image.Repository + ":" + image.Tag
}

// BootstrapImages returns independent copies of the finite archive inventory.
// These pins are covered only by the approved K3s-bootstrap architecture exception.
func BootstrapImages() [8]BootstrapImage {
	return [8]BootstrapImage{
		{Repository: "rancher/klipper-helm", Tag: "v0.13.3-build20260727", IndexDigest: "sha256:5425a2b4613d2458dbdff99218e8d487ebb59c20e7a941f061c0777070f0aac1", ARM64ManifestDigest: "sha256:c399ebe632420878b6b701a84e7481a26c3da2652594f9a86fef8b491f0c2dae", ARM64ConfigDigest: "sha256:913df6f04eb6d37b91f873894b0d7275f7603705b107fa9d08a1b58eb6e815cb"},
		{Repository: "rancher/klipper-lb", Tag: "v0.4.17", IndexDigest: "sha256:910944bb0bd94f060a82a56ca1ea1c577d3e49b3473a093a47a985f32e92d94a", ARM64ManifestDigest: "sha256:32905de585323a03fd44141626d021ac27d586dcd60899c7595b3986a858ba3e", ARM64ConfigDigest: "sha256:1084dac5ea9871ffa6d01fe67150e175df9c28579073cd40d2186c08b37aba50"},
		{Repository: "rancher/local-path-provisioner", Tag: "v0.0.37", IndexDigest: "sha256:e757967a5ec338f6a9b371c5a9688bedaa8c3578ea3dd4db329ea0084be0a86f", ARM64ManifestDigest: "sha256:6a6bade778f51df4e3f9710db6b62ff6eb366cac897e7eccc3528ebd6d22e86c", ARM64ConfigDigest: "sha256:004fd242b0093da1fa224b46ebd210bc3932b9ef79bff6f26f8489e61209ae26"},
		{Repository: "rancher/mirrored-coredns-coredns", Tag: "1.14.7", IndexDigest: "sha256:7efd3c635b03efd68c4e8398fc45f0d993d0e9ab016f72c1cefb0fd6d01aa286", ARM64ManifestDigest: "sha256:9a631b1e34491f93a35334bc02d8ae190f16224be41689c7f42cc1711a95fe3a", ARM64ConfigDigest: "sha256:5d3b3e589fcf57f626c7967bff5171924cf9c55068911247a1f7bd2458e726c3"},
		{Repository: "rancher/mirrored-library-busybox", Tag: "1.37.0", IndexDigest: "sha256:101b4afd76732482eff9b95cae5f94bcf295e521fbec4e01b69c5421f3f3f3e5", ARM64ManifestDigest: "sha256:fa8dc70514f29471fe118446e3f84040b19791531ec197836a4f43baf13d744b", ARM64ConfigDigest: "sha256:82c58a5c5b738fd9ffc8fe6bcc0a9467360abfab015b7ae70384563e895b68ff"},
		{Repository: "rancher/mirrored-library-traefik", Tag: "3.7.13", IndexDigest: "sha256:f86a2cab1b5c649070c49f883c743dd32d8485a56e3368c5f93b9e91f1e91259", ARM64ManifestDigest: "sha256:444bb54c1f7ebe5fac94d1c40f02b48c08dc005a92fc65ca29c1c75991d16baa", ARM64ConfigDigest: "sha256:8931bb3e2602443324bd3bac4192af9652d6251482d17adda804113e109e588f"},
		{Repository: "rancher/mirrored-metrics-server", Tag: "v0.9.0", IndexDigest: "sha256:d9862115e7c7881280d3d75ca26bda8ffc0fc213315979575bf23ce9826205c0", ARM64ManifestDigest: "sha256:d0341e07a1cf2b751e684cba68e2a0c62d3c5d2d23501fd67dc384d517ec65de", ARM64ConfigDigest: "sha256:37ceda8805d2e3bca331bcdd659d9cf8d3b4075a68b288054c88e62232d52883"},
		{Repository: "rancher/mirrored-pause", Tag: "3.10.2", IndexDigest: "sha256:f548e0e8e3dc1896ca956272154dde3314e8cc4fde0a57577ee9fa1c63f5baf4", ARM64ManifestDigest: "sha256:a433214620b407678934ebd69690a9ed6066247231eacfba181fab20dbc3dbf1", ARM64ConfigDigest: "sha256:3884a337192318652b28de0de1aeb07f446a14f220feb5066f03e93f23ea3b60"},
	}
}

func bootstrapImage(repository string) BootstrapImage {
	for _, image := range BootstrapImages() {
		if image.Repository == repository {
			return image
		}
	}
	panic("unknown source-owned bootstrap image: " + repository)
}
