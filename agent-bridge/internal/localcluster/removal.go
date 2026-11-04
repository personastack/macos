package localcluster

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

type nativeBindingOwner struct {
	AppOrigin   string `json:"app_origin"`
	AccountID   string `json:"account_id"`
	WorkspaceID string `json:"workspace_id"`
}

func (owner nativeBindingOwner) matches(scope Scope) bool {
	return owner.AppOrigin == scope.AppOrigin && owner.AccountID == scope.AccountID && owner.WorkspaceID == scope.WorkspaceID
}

func (tree *ownedTree) directoryHandle(name string) (*os.File, error) {
	if name == "." || filepath.IsAbs(name) || filepath.Clean(name) != name || strings.HasPrefix(name, "../") {
		return nil, fmt.Errorf("invalid native directory path")
	}
	fd, err := unix.Dup(int(tree.directory.Fd()))
	if err != nil {
		return nil, fmt.Errorf("open native directory handle: %w", err)
	}
	for _, part := range strings.Split(name, string(filepath.Separator)) {
		next, openErr := openDirectoryAt(fd, part, false)
		unix.Close(fd)
		if openErr != nil {
			return nil, fmt.Errorf("open owned directory: %w", openErr)
		}
		fd = next
		err = checkOwned(fd, true)
		if err != nil {
			unix.Close(fd)
			return nil, err
		}
	}
	return os.NewFile(uintptr(fd), filepath.Join(tree.path, name)), nil
}

func (tree *ownedTree) hasDirectory(name string) (bool, error) {
	file, err := tree.directoryHandle(name)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, file.Close()
}

// RemoveData is a local destructive action. Native code must obtain explicit
// human confirmation. Cloud retirement is a separate outcome and is not a
// prerequisite for erasing this machine's exact stopped local installation.
func (runtime *Runtime) RemoveData(ctx context.Context, scope Scope, binding TargetBinding) error {
	machineAction := scope == (Scope{})
	if machineAction && binding != (TargetBinding{}) {
		return ErrInvalidScope
	}
	if !machineAction && !validScope(scope) {
		return ErrInvalidScope
	}
	err := runtime.acquire(ctx)
	if err != nil {
		return err
	}
	defer runtime.release()
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	tree, err := runtime.tree(false)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	defer tree.directory.Close()
	owner, err := runtime.owner(tree, scope)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	if !machineAction && owner.Binding != binding {
		return runtimeCustodyFailure(ctx, fmt.Errorf("local removal target changed"))
	}
	if !owner.Removed {
		err = runtime.stop(ctx, false)
		if err != nil {
			return err
		}
		owner.Enabled = false
	}
	present, err := tree.hasDirectory("l/" + InstanceName)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	if present && owner.Removed {
		err = runtime.verifyTombstoneStopped(ctx, tree)
		if err != nil {
			return err
		}
	}
	owner.Removed, owner.Enabled = true, false
	err = writeRuntimeOwner(tree, owner)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	if !present {
		return nil
	}
	parent, err := tree.directoryHandle("l")
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	defer parent.Close()
	err = verifyRemovalDevice(int(tree.directory.Fd()), int(parent.Fd()), runtime.dependencies.device)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	count := 0
	err = removeOwnedDirectory(ctx, int(parent.Fd()), InstanceName, 0, &count, runtime.dependencies.device)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	return nil
}

// On the first removal, observe current stopped state. A retained tombstone
// fences every app start after a partially completed removal. A retry still
// rejects any remaining live PID or open disk handle before continuing.
func (runtime *Runtime) verifyTombstoneStopped(ctx context.Context, tree *ownedTree) error {
	pid, err := runtime.hostAgentPID(tree)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	if pid > 0 && runtime.dependencies.alive(pid) {
		return runtimeFailure(ctx, ReasonStopFailed, fmt.Errorf("owned VM process is still present"))
	}
	diskErr := runtime.retainedDisk(tree)
	if errors.Is(diskErr, os.ErrNotExist) {
		return nil
	}
	if diskErr != nil {
		return runtimeCustodyFailure(ctx, diskErr)
	}
	return runtime.observeClosedDisk(ctx)
}

// NewSetupAfterRemoval is a separate explicitly confirmed blank setup. The
// native caller validates the current authenticated human, even when ownership
// changes after all VM data was erased. No key is generated and no VM starts.
func (runtime *Runtime) NewSetupAfterRemoval(ctx context.Context, scope Scope, expected TargetBinding) error {
	if !validScope(scope) {
		return ErrInvalidScope
	}
	err := runtime.acquire(ctx)
	if err != nil {
		return err
	}
	defer runtime.release()
	tree, err := runtime.tree(false)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	defer tree.directory.Close()
	owner, err := readRuntimeOwner(tree)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	if !owner.Removed || owner.Enabled {
		return runtimeCustodyFailure(ctx, fmt.Errorf("explicit local removal must finish before blank setup"))
	}
	if expected != (TargetBinding{}) && owner.Binding != expected {
		return runtimeCustodyFailure(ctx, fmt.Errorf("removed target changed"))
	}
	present, err := tree.hasDirectory("l/" + InstanceName)
	if err != nil || present {
		return runtimeCustodyFailure(ctx, fmt.Errorf("removed VM files remain"))
	}
	if owner.Binding != (TargetBinding{}) {
		owner.PreviousRemovedBinding = owner.Binding
		owner.PreviousBindingOwner = nativeBindingOwner{owner.AppOrigin, owner.AccountID, owner.WorkspaceID}
	}
	owner.AppOrigin, owner.AccountID, owner.WorkspaceID = scope.AppOrigin, scope.AccountID, scope.WorkspaceID
	owner.Binding = TargetBinding{}
	owner.Removed, owner.Enabled, owner.Bootstrapped = false, false, false
	owner.GuestSHA256, owner.K3sSHA256 = "", ""
	return writeRuntimeOwner(tree, owner)
}

// Removal is anchored to already-open private directory descriptors. Symlinks
// and hard links are unlinked as entries; their outside targets are never read
// or traversed. There is no generic path or user-provided deletion target.
func removeOwnedDirectory(ctx context.Context, parent int, name string, depth int, count *int, device func(int) (uint64, error)) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if depth > 16 {
		return fmt.Errorf("owned VM directory exceeds removal depth bound")
	}
	fd, err := openDirectoryAt(parent, name, false)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("open stopped VM directory: %w", err)
	}
	file := os.NewFile(uintptr(fd), name)
	defer file.Close()
	err = checkOwned(fd, true)
	if err != nil {
		return err
	}
	err = verifyRemovalDevice(parent, fd, device)
	if err != nil {
		return err
	}
	for {
		names, readErr := file.Readdirnames(64)
		err = removeOwnedEntries(ctx, fd, names, depth, count, device)
		if err != nil {
			return err
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return fmt.Errorf("read stopped VM directory: %w", readErr)
		}
	}
	err = unix.Unlinkat(parent, name, unix.AT_REMOVEDIR)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stopped VM directory: %w", err)
	}
	return nil
}

func removeOwnedEntries(ctx context.Context, parent int, names []string, depth int, count *int, device func(int) (uint64, error)) error {
	for _, child := range names {
		*count = *count + 1
		if *count > 10000 {
			return fmt.Errorf("owned VM removal exceeds its entry bound")
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		err := removeOwnedEntry(ctx, parent, child, depth, count, device)
		if err != nil {
			return err
		}
	}
	return nil
}

func removeOwnedEntry(ctx context.Context, parent int, name string, depth int, count *int, device func(int) (uint64, error)) error {
	var stat unix.Stat_t
	err := unix.Fstatat(parent, name, &stat, unix.AT_SYMLINK_NOFOLLOW)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect owned VM entry: %w", err)
	}
	if stat.Mode&unix.S_IFMT == unix.S_IFDIR {
		return removeOwnedDirectory(ctx, parent, name, depth+1, count, device)
	}
	err = unix.Unlinkat(parent, name, 0)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove owned VM entry: %w", err)
	}
	return nil
}

func removalDevice(fd int) (uint64, error) {
	var stat unix.Stat_t
	err := unix.Fstat(fd, &stat)
	return uint64(stat.Dev), err
}

func verifyRemovalDevice(parent, current int, device func(int) (uint64, error)) error {
	parentDevice, err := device(parent)
	if err != nil {
		return fmt.Errorf("inspect removal parent device: %w", err)
	}
	currentDevice, err := device(current)
	if err != nil {
		return fmt.Errorf("inspect removal directory device: %w", err)
	}
	if parentDevice != currentDevice {
		return fmt.Errorf("local VM removal must not cross a filesystem mount")
	}
	return nil
}
