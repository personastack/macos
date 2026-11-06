package localcluster

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// AcquireProcessOwner excludes another helper or headless removal process.
// Keep this file in the persistent AgentBridge directory, outside VM payloads.
// The lock file is never unlinked, so a live owner cannot lose its locked inode.
func AcquireProcessOwner(directory string) (*os.File, error) {
	tree, err := openOwnedTree(directory, true)
	if err != nil {
		return nil, fmt.Errorf("open runtime process custody: %w", err)
	}
	defer tree.directory.Close()
	file, err := tree.open("local-runtime-owner.lock", os.O_CREATE|os.O_RDWR)
	if err != nil {
		return nil, fmt.Errorf("open runtime process owner: %w", err)
	}
	info, err := file.Stat()
	if err != nil || info.Mode().Perm() != 0600 {
		file.Close()
		return nil, fmt.Errorf("runtime process owner must be private mode 0600")
	}
	err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
	if err != nil {
		file.Close()
		return nil, fmt.Errorf("runtime process owner busy or unavailable: %w", err)
	}
	return file, nil
}
