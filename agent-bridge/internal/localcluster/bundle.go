package localcluster

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

type sealedLimaManifest struct {
	Schema   int  `json:"schema"`
	Sealed   bool `json:"sealed"`
	Artifact struct {
		Version string `json:"version"`
		URL     string `json:"url"`
		SHA256  string `json:"sha256"`
		Size    int64  `json:"size"`
	} `json:"artifact"`
	Files struct {
		Launcher string `json:"bin/limactl"`
		Agent    string `json:"share/lima/lima-guestagent.Linux-aarch64.gz"`
		License  string `json:"share/doc/lima/LICENSE"`
		Version  string `json:"share/doc/lima/VERSION"`
	} `json:"files"`
}

func (runtime *Runtime) verifyBundle(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	for _, identity := range []struct{ path, identifier string }{{runtime.options.BundleDirectory, "ai.personastack.desktop"}, {runtime.lima, "ai.personastack.desktop.lima"}} {
		requirement := `anchor apple generic and certificate leaf[subject.OU] = "5T2T8KL852" and certificate leaf = H"bbafb291a3d54ff75ea476a66b60878a81754e4d" and identifier "` + identity.identifier + `"`
		_, err := runtime.command(ctx, "verify_signature", "/usr/bin/codesign", []string{"--verify", "--strict", "--deep", "--test-requirement", requirement, identity.path}, nil, false)
		if err != nil {
			return runtimeFailure(ctx, ReasonComponentUnverified, err)
		}
	}
	output, err := runtime.command(ctx, "inspect_launcher", "/usr/bin/codesign", []string{"-dvvv", "--entitlements", ":-", runtime.lima}, nil, true)
	if err != nil {
		return runtimeFailure(ctx, ReasonComponentUnverified, err)
	}
	err = validateLauncherMetadata(output)
	if err != nil {
		return runtimeFailure(ctx, ReasonComponentUnverified, err)
	}
	return runtime.verifySealedManifest(ctx)
}

var signatureFlags = regexp.MustCompile(`flags=0x([0-9a-fA-F]+)`)

func validateLauncherMetadata(output commandOutput) error {
	flags := signatureFlags.FindSubmatch(output.Stderr)
	if len(flags) != 2 {
		return fmt.Errorf("launcher signature flags unavailable")
	}
	value, err := strconv.ParseUint(string(flags[1]), 16, 32)
	if err != nil || value&0x10000 == 0 {
		return fmt.Errorf("launcher hardened runtime missing")
	}
	return validateVirtualizationEntitlement(output.Stdout)
}

func validateVirtualizationEntitlement(content []byte) error {
	decoder := xml.NewDecoder(strings.NewReader(string(content)))
	key, virtualization := "", false
	for {
		token, decodeErr := decoder.Token()
		if decodeErr == io.EOF {
			break
		}
		if decodeErr != nil {
			return fmt.Errorf("decode launcher entitlement: %w", decodeErr)
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		switch start.Name.Local {
		case "key":
			decodeErr = decoder.DecodeElement(&key, &start)
			if decodeErr != nil {
				return fmt.Errorf("decode entitlement key: %w", decodeErr)
			}
			if key != "com.apple.security.virtualization" || virtualization {
				return fmt.Errorf("unexpected launcher entitlement")
			}
		case "true":
			if key != "com.apple.security.virtualization" {
				return fmt.Errorf("invalid launcher entitlement value")
			}
			virtualization, key = true, ""
		case "plist", "dict":
		default:
			return fmt.Errorf("unsupported launcher entitlement value")
		}
	}
	if !virtualization {
		return fmt.Errorf("launcher virtualization entitlement missing")
	}
	return nil
}

func (runtime *Runtime) verifySealedManifest(ctx context.Context) error {
	base := filepath.Join(runtime.options.BundleDirectory, "Contents", "Resources", "LocalCluster", "lima")
	manifestFile, err := openBundleFile(base, "runtime-manifest.json")
	if err != nil {
		return runtimeFailure(ctx, ReasonComponentUnverified, err)
	}
	defer manifestFile.Close()
	info, err := manifestFile.Stat()
	if err != nil || info.Size() > 8192 {
		return runtimeFailure(ctx, ReasonComponentUnverified, fmt.Errorf("signed runtime manifest exceeds its bound"))
	}
	decoder := json.NewDecoder(io.LimitReader(manifestFile, 8192))
	decoder.DisallowUnknownFields()
	var manifest sealedLimaManifest
	err = decoder.Decode(&manifest)
	if err != nil {
		return runtimeFailure(ctx, ReasonComponentUnverified, err)
	}
	var trailing json.RawMessage
	err = decoder.Decode(&trailing)
	if err != io.EOF {
		return runtimeFailure(ctx, ReasonComponentUnverified, fmt.Errorf("signed runtime manifest contains extra data"))
	}
	pin := PinnedDescriptor().Artifacts[0]
	if manifest.Schema != 1 || !manifest.Sealed || manifest.Artifact.Version != pin.Version || manifest.Artifact.URL != pin.URL || manifest.Artifact.SHA256 != pin.SHA256 || manifest.Artifact.Size != pin.Size {
		return runtimeFailure(ctx, ReasonComponentUnverified, fmt.Errorf("signed Lima source identity mismatch"))
	}
	files := []struct{ path, digest string }{{"bin/limactl", manifest.Files.Launcher}, {"share/lima/lima-guestagent.Linux-aarch64.gz", manifest.Files.Agent}, {"share/doc/lima/LICENSE", manifest.Files.License}, {"share/doc/lima/VERSION", manifest.Files.Version}}
	for _, file := range files {
		err = verifyBundleFile(ctx, base, file.path, file.digest)
		if err != nil {
			return runtimeFailure(ctx, ReasonComponentUnverified, err)
		}
	}
	return nil
}

func openBundleFile(base, relative string) (*os.File, error) {
	path := filepath.Join(base, relative)
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("open bundle filesystem: %w", err)
	}
	for _, part := range parts[:len(parts)-1] {
		next, openErr := openDirectoryAt(fd, part, false)
		unix.Close(fd)
		if openErr != nil {
			return nil, fmt.Errorf("open signed bundle directory: %w", openErr)
		}
		fd = next
	}
	defer unix.Close(fd)
	resource, err := unix.Openat(fd, parts[len(parts)-1], unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, fmt.Errorf("open bundled runtime resource: %w", err)
	}
	return os.NewFile(uintptr(resource), path), nil
}

func verifyBundleFile(ctx context.Context, base, path, digest string) error {
	expected, err := hex.DecodeString(digest)
	if err != nil || len(expected) != sha256.Size {
		return fmt.Errorf("bundled runtime hash missing")
	}
	file, err := openBundleFile(base, path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 128*1024*1024 {
		return fmt.Errorf("bundled runtime resource exceeds its file bound")
	}
	hash := sha256.New()
	_, err = io.Copy(hash, io.LimitReader(contextReader{ctx, file}, 128*1024*1024+1))
	if err != nil {
		return fmt.Errorf("hash bundled runtime resource: %w", err)
	}
	if hex.EncodeToString(hash.Sum(nil)) != digest {
		return fmt.Errorf("bundled runtime resource hash mismatch")
	}
	return nil
}
