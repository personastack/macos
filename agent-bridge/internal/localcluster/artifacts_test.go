package localcluster

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type artifactTransport func(*http.Request) (*http.Response, error)

func (transport artifactTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return transport(request)
}

func TestArtifactDownloadVerifiesBeforeReuse(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	chmodErr := os.Chmod(root, 0700)
	if chmodErr != nil {
		t.Fatal(chmodErr)
	}
	tree, err := openOwnedTree(root, true)
	if err != nil {
		t.Fatal(err)
	}
	defer tree.directory.Close()
	content := "pinned bytes"
	digest := sha256.Sum256([]byte(content))
	pin := Artifact{Component: K3s, Version: "v1", URL: "https://github.com/owner/project/releases/download/v1/input", SHA256: hex.EncodeToString(digest[:]), Size: int64(len(content))}
	calls := 0
	client := &http.Client{Transport: artifactTransport(func(request *http.Request) (*http.Response, error) {
		calls++
		if request.URL.String() != pin.URL || request.Header.Get("Authorization") != "" {
			t.Error("download escaped pinned URL or acquired credentials")
		}
		return &http.Response{StatusCode: 200, ContentLength: pin.Size, Body: io.NopCloser(strings.NewReader(content))}, nil
	})}
	err = acquireArtifact(context.Background(), tree, client, pin)
	if err != nil {
		t.Fatal(err)
	}
	err = acquireArtifact(context.Background(), tree, client, pin)
	if err != nil || calls != 1 {
		t.Fatalf("verified input not reused: calls=%d err=%v", calls, err)
	}
	err = tree.write("artifacts/k3s", []byte("corruption"))
	if err != nil {
		t.Fatal(err)
	}
	err = acquireArtifact(context.Background(), tree, client, pin)
	if err != nil || calls != 2 {
		t.Fatalf("corrupt cached input not repaired: calls=%d err=%v", calls, err)
	}
	content = "invalid bytes"
	err = tree.write("artifacts/k3s", []byte("corruption"))
	if err != nil {
		t.Fatal(err)
	}
	err = acquireArtifact(context.Background(), tree, client, pin)
	var failure *Failure
	if !errors.As(err, &failure) || failure.Reason != ReasonIntegrityFailed {
		t.Fatalf("unverified network bytes accepted: %v", err)
	}
}

func TestArtifactRedirectPolicy(t *testing.T) {
	t.Parallel()
	client := artifactClient()
	for _, input := range []string{"http://github.com/input", "https://github.com.attacker.invalid/input", "https://user:pass@github.com/input", "https://127.0.0.1/input", "https://cloud-images.ubuntu.com/input#fragment"} {
		location, err := url.Parse(input)
		if err != nil {
			t.Fatal(err)
		}
		if client.CheckRedirect(&http.Request{URL: location}, nil) == nil {
			t.Fatalf("unsafe redirect accepted: %s", input)
		}
	}
	location, _ := url.Parse("https://release-assets.githubusercontent.com/verified?signature=bounded")
	if client.CheckRedirect(&http.Request{URL: location}, nil) != nil {
		t.Fatal("official signed release redirect rejected")
	}
	if client.CheckRedirect(&http.Request{URL: location}, make([]*http.Request, 4)) == nil {
		t.Fatal("unbounded redirects accepted")
	}
}

func TestNativeCustodyRejectsLinksAndNonPrivateDirectories(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	chmodErr := os.Chmod(root, 0700)
	if chmodErr != nil {
		t.Fatal(chmodErr)
	}
	tree, err := openOwnedTree(root, true)
	if err != nil {
		t.Fatal(err)
	}
	defer tree.directory.Close()
	outside := filepath.Join(t.TempDir(), "outside")
	err = os.WriteFile(outside, []byte("must survive"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	err = os.Symlink(outside, filepath.Join(root, "linked"))
	if err != nil {
		t.Fatal(err)
	}
	if tree.write("linked", []byte("overwrite")) == nil {
		t.Fatal("native write followed a symbolic link")
	}
	err = os.Link(outside, filepath.Join(root, "hardlinked"))
	if err != nil {
		t.Fatal(err)
	}
	if tree.write("hardlinked", []byte("overwrite")) == nil {
		t.Fatal("native write truncated a hard link")
	}
	content, err := os.ReadFile(outside)
	if err != nil || string(content) != "must survive" {
		t.Fatal("rejected custody changed outside data")
	}
	err = os.Symlink(filepath.Dir(outside), filepath.Join(root, "directory-link"))
	if err != nil {
		t.Fatal(err)
	}
	if tree.write("directory-link/outside", []byte("overwrite")) == nil {
		t.Fatal("native traversal followed a directory link")
	}
	if tree.write("../outside", nil) == nil {
		t.Fatal("native custody escaped root")
	}
	err = os.Chmod(root, 0755)
	if err != nil {
		t.Fatal(err)
	}
	other, err := openOwnedTree(root, false)
	if other != nil {
		other.directory.Close()
	}
	if err == nil {
		t.Fatal("non-private runtime root accepted")
	}
}

func TestSignedLimaMetadataRejectsUnsafeEntitlements(t *testing.T) {
	t.Parallel()
	valid := `<plist><dict><key>com.apple.security.virtualization</key><true/></dict></plist>`
	tests := []struct{ name, flags, plist string }{
		{"adhoc", "flags=0x2(adhoc)", valid},
		{"missingRuntime", "unknown", valid},
		{"missingVirtualization", "flags=0x10000(runtime)", `<plist><dict/></plist>`},
		{"falseVirtualization", "flags=0x10000(runtime)", `<plist><dict><key>com.apple.security.virtualization</key><false/></dict></plist>`},
		{"additionalEntitlement", "flags=0x10000(runtime)", `<plist><dict><key>com.apple.security.virtualization</key><true/><key>com.apple.security.get-task-allow</key><true/></dict></plist>`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if validateLauncherMetadata(commandOutput{Stdout: []byte(test.plist), Stderr: []byte(test.flags)}) == nil {
				t.Fatal("unsafe signed launcher metadata accepted")
			}
		})
	}
}
