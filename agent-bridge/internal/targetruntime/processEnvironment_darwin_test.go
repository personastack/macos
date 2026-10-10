//go:build darwin

package targetruntime

import (
	"os"
	"testing"
)

func TestNativeProcessEnvironmentReadsCurrentTestPID(t *testing.T) {
	t.Parallel()
	// Read-only kernel boundary check. No runtime or child process is started.
	root, config, err := nativeProfileEnvironment(os.Getpid())
	if err != nil {
		t.Fatalf("current test PID environment unavailable: %v", err)
	}
	if root != os.Getenv("OPENCLAW_STATE_DIR") || config != os.Getenv("OPENCLAW_CONFIG_PATH") {
		t.Fatal("native profile fields differ from the test process environment")
	}
}
