//go:build !darwin

package targetruntime

import "fmt"

func nativeProfileEnvironment(_ int) (string, string, error) {
	return "", "", fmt.Errorf("native process environment requires macOS")
}
