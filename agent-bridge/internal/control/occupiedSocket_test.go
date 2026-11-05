package control

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestControlServerPreservesOccupiedSocket(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"listener", "file", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			// Use a short, isolated path so Serve cannot select its global fallback.
			directory, err := os.MkdirTemp("/tmp", "ps-socket-")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.RemoveAll(directory) })
			path := filepath.Join(directory, "control.sock")
			if len(path) > 103 {
				t.Fatal("fixture would select the shared socket path")
			}
			wantError := "unsafe existing control socket"
			switch kind {
			case "listener":
				// This passive kernel socket has no server or handler goroutine.
				listener, listenErr := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
				if listenErr != nil {
					t.Fatal(listenErr)
				}
				t.Cleanup(func() { _ = listener.Close() })
				wantError = "agent bridge already running"
			case "file":
				err = os.WriteFile(path, []byte("occupied"), 0o600)
			case "symlink":
				err = os.Symlink("preserve-target", path)
			}
			if err != nil {
				t.Fatal(err)
			}
			before, err := os.Lstat(path)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			err = Serve(ctx, directory, nil)
			if err == nil || !strings.Contains(err.Error(), wantError) {
				t.Fatalf("occupied namespace was not rejected: %v", err)
			}
			after, err := os.Lstat(path)
			if err != nil || !os.SameFile(before, after) || before.Mode() != after.Mode() {
				t.Fatalf("occupied namespace changed: %v", err)
			}
			if kind == "file" {
				content, readErr := os.ReadFile(path)
				if readErr != nil || string(content) != "occupied" {
					t.Fatalf("occupied file changed: %q, %v", content, readErr)
				}
			}
			if kind == "symlink" {
				target, readErr := os.Readlink(path)
				if readErr != nil || target != "preserve-target" {
					t.Fatalf("occupied symlink changed: %q, %v", target, readErr)
				}
			}
		})
	}
}
