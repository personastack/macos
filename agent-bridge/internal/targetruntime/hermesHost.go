package targetruntime

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const HermesHostConflictMessage = "Hermes shared gateway cannot be attached safely. Enable its loopback API server, then Repair."

var ErrHermesHostConflict = errors.New("runtime_conflict: " + HermesHostConflictMessage)

type HermesHostIdentity struct {
	Protocol       int      `json:"protocol"`
	Kind           string   `json:"kind"`
	PID            int      `json:"pid"`
	StartTime      int64    `json:"start_time"`
	Home           string   `json:"hermes_home"`
	Profile        string   `json:"profile"`
	ServedProfiles []string `json:"served_profiles"`
}
type hermesIdentify func(context.Context, string) (HermesHostIdentity, bool, error)

func VerifyHermesHost(ctx context.Context, endpoint, root string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return verifyHermesHost(ctx, endpoint, root, os.Geteuid(), nativeCommandOutput, identifyHermesHost, readHermesHostRecord)
}

// The native socket identifies the shared host. The actual loopback listener
// and OS owner must independently match that exact host PID and home.
func verifyHermesHost(ctx context.Context, endpoint, root string, uid int, run commandOutput, identify hermesIdentify, readRecord func(string) (HermesHostRecord, bool, error)) (bool, error) {
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Port() == "" {
		return false, ErrHermesHostConflict
	}
	record, recordAlive, err := readRecord(root)
	if err != nil {
		return false, ErrHermesHostConflict
	}
	if recordAlive && record.Home != root {
		return false, ErrHermesHostConflict
	}
	identity, alive, err := identify(ctx, root)
	if err != nil {
		return false, ErrHermesHostConflict
	}
	raw, err := run(ctx, "/usr/sbin/lsof", "-nP", "-iTCP:"+parsed.Port(), "-sTCP:LISTEN", "-Fpn")
	if err != nil || len(raw) == 0 {
		var exit *exec.ExitError
		if err != nil && (!errors.As(err, &exit) || exit.ExitCode() != 1) {
			return false, ErrHermesHostConflict
		}
		if alive || recordAlive {
			return false, ErrHermesHostConflict
		}
		return false, verifyNoHermesHost(ctx, uid, run)
	}
	if !alive || !recordAlive || record.PID != identity.PID || record.StartTime != identity.StartTime || record.Home != identity.Home {
		return false, ErrHermesHostConflict
	}
	pid, err := ListenerPID(raw, parsed.Port())
	if err != nil {
		return false, ErrHermesHostConflict
	}
	profile := "default"
	parts := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	if len(parts) != 2 || parts[0] != "p" || parts[1] == "" {
		return false, ErrHermesHostConflict
	}
	profile = parts[1]
	if identity.Protocol != 1 || identity.Kind != "hermes-gateway" || identity.PID <= 0 || identity.StartTime <= 0 || identity.Home != root || identity.Profile != "default" || strconv.Itoa(identity.PID) != pid {
		return false, ErrHermesHostConflict
	}
	served := profile == "default" // a single-profile default host need not stamp a roster
	for _, value := range identity.ServedProfiles {
		if value == profile {
			served = true
		}
	}
	if !served || len(identity.ServedProfiles) > 128 {
		return false, ErrHermesHostConflict
	}
	raw, err = run(ctx, "/bin/ps", "eww", "-p", pid, "-o", "uid=,command=")
	if err != nil || len(raw) > 64*1024 {
		return false, ErrHermesHostConflict
	}
	fields := strings.Fields(string(raw))
	if len(fields) < 2 || fields[0] != strconv.Itoa(uid) {
		return false, ErrHermesHostConflict
	}
	evidence := ProcessEvidence(string(raw), "hermes", root, filepath.Join(root, "config.yaml"))
	if evidence.RuntimeKind != "hermes" {
		return false, ErrHermesHostConflict
	}
	return true, nil
}

// No selected listener is not proof that no shared gateway already owns the
// host. Refuse a bounded current-user Hermes gateway scan before startup.
func verifyNoHermesHost(ctx context.Context, uid int, run commandOutput) error {
	raw, err := run(ctx, "/bin/ps", "-u", strconv.Itoa(uid), "-o", "uid=,pid=,command=")
	if err != nil || len(raw) > 64*1024 {
		return ErrHermesHostConflict
	}
	rows := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(rows) > 1024 {
		return ErrHermesHostConflict
	}
	for _, row := range rows {
		fields := strings.Fields(row)
		if len(fields) < 3 || fields[0] != strconv.Itoa(uid) {
			return ErrHermesHostConflict
		}
		if ProcessEvidence(strings.Join(append([]string{fields[0]}, fields[2:]...), " "), "hermes", "", "").RuntimeKind == "hermes" {
			return ErrHermesHostConflict
		}
	}
	return nil
}

func identifyHermesHost(ctx context.Context, root string) (HermesHostIdentity, bool, error) {
	path := filepath.Join(root, "gateway.sock")
	if len(path) > 100 {
		sum := sha256.Sum256([]byte(root))
		path = filepath.Join(os.TempDir(), "hermes-gw-"+hex.EncodeToString(sum[:])[:16]+".sock")
	}
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return HermesHostIdentity{}, false, nil
	}
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return HermesHostIdentity{}, false, ErrHermesHostConflict
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Geteuid() {
		return HermesHostIdentity{}, false, ErrHermesHostConflict
	}
	connection, err := (&net.Dialer{}).DialContext(ctx, "unix", path)
	if err != nil {
		return HermesHostIdentity{}, false, ErrHermesHostConflict
	}
	defer connection.Close()
	deadline := time.Now().Add(2 * time.Second)
	if parent, ok := ctx.Deadline(); ok && parent.Before(deadline) {
		deadline = parent
	}
	err = connection.SetDeadline(deadline)
	if err != nil {
		return HermesHostIdentity{}, false, ErrHermesHostConflict
	}
	_, err = connection.Write([]byte("{\"verb\":\"identify\",\"id\":1,\"protocol\":1}\n"))
	if err != nil {
		return HermesHostIdentity{}, false, ErrHermesHostConflict
	}
	scan := bufio.NewScanner(connection)
	scan.Buffer(make([]byte, 4096), 64*1024)
	if !scan.Scan() {
		return HermesHostIdentity{}, false, ErrHermesHostConflict
	}
	var response struct {
		OK       bool               `json:"ok"`
		ID       int                `json:"id"`
		Protocol int                `json:"protocol"`
		Result   HermesHostIdentity `json:"result"`
	}
	err = json.Unmarshal(scan.Bytes(), &response)
	if err != nil || !response.OK || response.ID != 1 || response.Protocol != 1 {
		return HermesHostIdentity{}, false, ErrHermesHostConflict
	}
	return response.Result, true, nil
}

func HermesProfileURL(endpoint, profile string) (string, error) {
	if profile == "" {
		profile = "default"
	}
	if !validHermesProfile(profile) {
		return "", fmt.Errorf("runtime_conflict: unsupported Hermes profile name")
	}
	return strings.TrimRight(endpoint, "/") + "/p/" + url.PathEscape(profile), nil
}

func validHermesProfile(profile string) bool {
	if len(profile) == 0 || len(profile) > 64 {
		return false
	}
	for i, value := range profile {
		if value >= 'a' && value <= 'z' || value >= '0' && value <= '9' || i > 0 && (value == '_' || value == '-') {
			continue
		}
		return false
	}
	return true
}
