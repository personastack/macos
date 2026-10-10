//go:build darwin

package control

import (
	"fmt"
	"golang.org/x/sys/unix"
	"net"
)

func peerUID(connection *net.UnixConn) (int, error) {
	raw, err := connection.SyscallConn()
	if err != nil {
		return 0, fmt.Errorf("get private socket: %w", err)
	}
	uid := 0
	var peerErr error
	err = raw.Control(func(fd uintptr) {
		credential, e := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		peerErr = e
		if e == nil {
			uid = int(credential.Uid)
		}
	})
	if err != nil {
		return 0, fmt.Errorf("inspect socket peer: %w", err)
	}
	if peerErr != nil {
		return 0, fmt.Errorf("authenticate socket peer: %w", peerErr)
	}
	return uid, nil
}
