//go:build linux

package control

import (
	"fmt"
	"golang.org/x/sys/unix"
	"net"
)

// Linux exists only for deterministic containerized tests, not distribution.
func peerUID(connection *net.UnixConn) (int, error) {
	raw, err := connection.SyscallConn()
	if err != nil {
		return 0, err
	}
	uid := 0
	var peerErr error
	err = raw.Control(func(fd uintptr) {
		credential, e := unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
		peerErr = e
		if e == nil {
			uid = int(credential.Uid)
		}
	})
	if err != nil || peerErr != nil {
		return 0, fmt.Errorf("authenticate private socket peer")
	}
	return uid, nil
}
