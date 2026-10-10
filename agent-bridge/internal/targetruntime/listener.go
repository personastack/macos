package targetruntime

import (
	"net"
	"strconv"
	"strings"
)

// ListenerPID consumes lsof -nP -Fpn selected TCP LISTEN records. Config and
// launch arguments cannot prove the effective host when a native CLI overrides it.
func ListenerPID(raw []byte, port string) (string, error) {
	if len(raw) == 0 || len(raw) > 64*1024 {
		return "", ErrProfileScopeUnverified
	}
	pid, names, needsName := "", 0, false
	for _, field := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if len(field) < 2 {
			return "", ErrProfileScopeUnverified
		}
		switch field[0] {
		case 'p':
			value := field[1:]
			if !numericFieldAtLeast(value, 1) || needsName || (pid != "" && pid != value) {
				return "", ErrProfileScopeUnverified
			}
			pid = value
		case 'f':
			// lsof always emits the descriptor field, including with -Fpn.
			if !numericFieldAtLeast(field[1:], 0) || pid == "" || needsName {
				return "", ErrProfileScopeUnverified
			}
			needsName = true
		case 'n':
			if !needsName || !loopbackListenerAddress(field[1:], port) {
				return "", ErrProfileScopeUnverified
			}
			names++
			needsName = false
		default:
			return "", ErrProfileScopeUnverified
		}
	}
	if pid == "" || names == 0 || needsName {
		return "", ErrProfileScopeUnverified
	}
	return pid, nil
}

func loopbackListenerAddress(value, port string) bool {
	host, gotPort, err := net.SplitHostPort(value)
	address := net.ParseIP(host)
	return err == nil && gotPort == port && address != nil && address.IsLoopback()
}

func numericFieldAtLeast(value string, minimum int) bool {
	number, err := strconv.Atoi(value)
	return err == nil && number >= minimum
}
