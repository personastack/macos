package targetruntime

import (
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"

	"github.com/personastack/macos/agent-bridge/internal/hermessetup"
)

type HermesHostRecord struct {
	Role      string   `json:"role"`
	Home      string   `json:"home"`
	PID       int      `json:"pid"`
	StartTime int64    `json:"startTime"`
	Protocol  int      `json:"protocolVersion"`
	Profiles  []string `json:"profiles"`
}

// Read only the producer-owned current-user host rendezvous. Missing data is
// never substituted with profile PID files or a helper-maintained registry.
func readHermesHostRecord(root string) (HermesHostRecord, bool, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return HermesHostRecord{}, false, ErrHermesHostConflict
	}
	directory, err := hermessetup.GatewayLockDirectory(hermessetup.ResolvePaths(home, root), home, os.Getenv("XDG_STATE_HOME"), os.Getenv("HERMES_GATEWAY_LOCK_DIR"))
	if err != nil {
		return HermesHostRecord{}, false, ErrHermesHostConflict
	}
	path := filepath.Join(directory, "host-gateway.json")
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return HermesHostRecord{}, false, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() > 64*1024 || info.Mode().Perm()&0077 != 0 {
		return HermesHostRecord{}, false, ErrHermesHostConflict
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Geteuid() {
		return HermesHostRecord{}, false, ErrHermesHostConflict
	}
	parent, err := os.Lstat(directory)
	if err != nil || !parent.IsDir() || parent.Mode()&os.ModeSymlink != 0 || parent.Mode().Perm()&0077 != 0 {
		return HermesHostRecord{}, false, ErrHermesHostConflict
	}
	parentOwner, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || int(parentOwner.Uid) != os.Geteuid() {
		return HermesHostRecord{}, false, ErrHermesHostConflict
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return HermesHostRecord{}, false, ErrHermesHostConflict
	}
	var record HermesHostRecord
	err = json.Unmarshal(raw, &record)
	if err != nil || record.Role != "gateway" || record.Protocol != 1 || record.PID <= 0 || record.StartTime <= 0 || record.Home == "" || len(record.Profiles) > 128 {
		return HermesHostRecord{}, false, ErrHermesHostConflict
	}
	// A missing PID proves this record stale. All live/recycled/inaccessible PIDs
	// remain unavailable until their native control socket proves the incarnation.
	err = syscall.Kill(record.PID, 0)
	if err == syscall.ESRCH {
		return HermesHostRecord{}, false, nil
	}
	if err != nil {
		return HermesHostRecord{}, false, ErrHermesHostConflict
	}
	return record, true, nil
}
