//go:build darwin

package targetruntime

import "golang.org/x/sys/unix"

func nativeProfileEnvironment(pid int) (string, string, error) {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", "", err
	}
	return profileEnvironment(raw)
}
