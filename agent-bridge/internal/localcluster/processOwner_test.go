package localcluster

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProcessOwnerRejectsConcurrentOwnerAndAllowsRetryAfterClose(t *testing.T) {
	t.Parallel()
	directory := filepath.Join(privateRuntimeTestDirectory(t), "control")
	owner, err := AcquireProcessOwner(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Close()
	other, err := AcquireProcessOwner(directory)
	if err == nil {
		other.Close()
		t.Fatal("concurrent process owner accepted")
	}
	err = owner.Close()
	if err != nil {
		t.Fatal(err)
	}
	other, err = AcquireProcessOwner(directory)
	if err != nil {
		t.Fatal(err)
	}
	other.Close()
}

func TestProcessOwnerRejectsSymlinksHardlinksAndNonprivateMode(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"symlink", "hardlink", "mode"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			root := privateRuntimeTestDirectory(t)
			directory := filepath.Join(root, "control")
			err := os.Mkdir(directory, 0700)
			if err != nil {
				t.Fatal(err)
			}
			outside := filepath.Join(root, "outside")
			err = os.WriteFile(outside, []byte("preserve"), 0600)
			if err != nil {
				t.Fatal(err)
			}
			lock := filepath.Join(directory, "local-runtime-owner.lock")
			switch kind {
			case "symlink":
				err = os.Symlink(outside, lock)
			case "hardlink":
				err = os.Link(outside, lock)
			case "mode":
				err = os.WriteFile(lock, nil, 0644)
			}
			if err != nil {
				t.Fatal(err)
			}
			owner, err := AcquireProcessOwner(directory)
			if err == nil {
				owner.Close()
				t.Fatal("unsafe lock accepted")
			}
			data, err := os.ReadFile(outside)
			if err != nil || string(data) != "preserve" {
				t.Fatal("outside data changed")
			}
		})
	}
}
