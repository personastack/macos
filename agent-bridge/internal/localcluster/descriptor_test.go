package localcluster

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestPinnedDescriptor(t *testing.T) {
	t.Parallel()
	descriptor := PinnedDescriptor()
	if descriptor.MinimumMacOS != "14.0" || descriptor.GuestKernel == "" {
		t.Fatal("missing host baseline or disk-owned kernel identity")
	}
	wantComponents := [5]Component{Lima, Guest, K3s, SystemImages, ProvisionerManifest}
	for index, artifact := range descriptor.Artifacts {
		if artifact.Component != wantComponents[index] {
			t.Fatalf("artifact %d: got %q, want %q", index, artifact.Component, wantComponents[index])
		}
		err := artifact.validate()
		if err != nil {
			t.Fatal(err)
		}
		if artifact.ProvenanceURL == "" {
			t.Fatalf("missing %s provenance", artifact.Component)
		}
		if artifact.Component == ProvisionerManifest {
			if artifact.Architecture != "" || artifact.OS != "" {
				t.Fatal("upstream source manifest is not an executable platform artifact")
			}
			continue
		}
		wantOS := "linux"
		if artifact.Component == Lima {
			wantOS = "darwin"
		}
		if artifact.Architecture != "arm64" || artifact.OS != wantOS {
			t.Fatalf("unexpected %s platform: %s/%s", artifact.Component, artifact.OS, artifact.Architecture)
		}
	}
	if descriptor.Artifacts[2].Version != descriptor.Artifacts[3].Version {
		t.Fatal("K3s binary and system image archive must use the same release")
	}
	descriptor.Artifacts[0].SHA256 = "changed"
	if PinnedDescriptor().Artifacts[0].SHA256 == "changed" {
		t.Fatal("caller mutated the source descriptor")
	}
}

func TestArtifactVerification(t *testing.T) {
	t.Parallel()
	content := "verified upstream bytes"
	digest := sha256.Sum256([]byte(content))
	pin := Artifact{Component: K3s, Version: "test", URL: "https://github.com/example/releases/download/test/input", SHA256: hex.EncodeToString(digest[:]), Size: int64(len(content))}
	tests := []struct {
		name      string
		input     string
		wantError string
	}{
		{"valid", content, ""},
		{"truncated", content[:len(content)-1], "size mismatch"},
		{"oversized", content + strings.Repeat("x", 100), "size mismatch"},
		{"corrupted", "Verified upstream bytes", "digest mismatch"},
		{"empty", "", "size mismatch"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			input := strings.NewReader(test.input)
			err := verifyArtifact(pin, input)
			if test.wantError == "" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("got %v, want %q", err, test.wantError)
			}
			consumed := len(test.input) - input.Len()
			if int64(consumed) > pin.Size+1 {
				t.Fatal("verification exceeded its byte bound")
			}
		})
	}
	readErr := errors.New("interrupted")
	err := verifyArtifact(pin, failingReader{readErr})
	if !errors.Is(err, readErr) {
		t.Fatalf("read failure lost its cause: %v", err)
	}
	err = VerifyArtifact(Component("unknown"), strings.NewReader(content))
	if err == nil || !strings.Contains(err.Error(), "unsupported") {
		t.Fatalf("unknown component accepted: %v", err)
	}
}

type failingReader struct{ err error }

func (reader failingReader) Read([]byte) (int, error) { return 0, reader.err }

var _ io.Reader = failingReader{}

func TestArtifactRejectsUnpinnedInputs(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		mutate func(*Artifact)
	}{
		{"http", func(pin *Artifact) { pin.URL = "http://github.com/download" }},
		{"credentials", func(pin *Artifact) { pin.URL = "https://user:pass@github.com/download" }},
		{"origin", func(pin *Artifact) { pin.URL = "https://github.com.attacker.invalid/download" }},
		{"query", func(pin *Artifact) { pin.URL += "?token=secret" }},
		{"fragment", func(pin *Artifact) { pin.URL += "#fragment" }},
		{"moving", func(pin *Artifact) { pin.URL = "https://github.com/example/releases/latest/input" }},
		{"digest", func(pin *Artifact) { pin.SHA256 = "not-a-digest" }},
		{"shortDigest", func(pin *Artifact) { pin.SHA256 = "ab" }},
		{"uppercaseDigest", func(pin *Artifact) { pin.SHA256 = strings.ToUpper(pin.SHA256) }},
		{"size", func(pin *Artifact) { pin.Size = 0 }},
		{"version", func(pin *Artifact) { pin.Version = "" }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			pin := PinnedDescriptor().Artifacts[0]
			test.mutate(&pin)
			err := verifyArtifact(pin, strings.NewReader(""))
			if err == nil || !strings.Contains(err.Error(), "validate") {
				t.Fatalf("invalid source pin accepted: %v", err)
			}
		})
	}
}
