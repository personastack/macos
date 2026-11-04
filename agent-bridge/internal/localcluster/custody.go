package localcluster

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// ownedTree never follows a symlink while walking or opening native custody.
// Its private final directory and every descendant belong to the helper UID.
type ownedTree struct {
	path      string
	directory *os.File
}

func openOwnedTree(path string, create bool) (*ownedTree, error) {
	err := validateNativePath(path)
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(path, "/tmp/") {
		path = "/private" + path
	}
	// /tmp is a platform symlink on macOS, not on the Linux source-test host.
	_, statErr := os.Stat("/private/tmp")
	if statErr != nil && strings.HasPrefix(path, "/private/tmp/") {
		path = strings.TrimPrefix(path, "/private")
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("open filesystem root: %w", err)
	}
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	for index, part := range parts {
		next, openErr := openDirectoryAt(fd, part, create)
		unix.Close(fd)
		if openErr != nil {
			return nil, fmt.Errorf("open native directory: %w", openErr)
		}
		fd = next
		if index != len(parts)-1 {
			err = checkNativeAncestor(fd)
			if err != nil {
				unix.Close(fd)
				return nil, err
			}
		}
		if index == len(parts)-1 {
			err = checkOwned(fd, true)
			if err != nil {
				unix.Close(fd)
				return nil, err
			}
		}
	}
	return &ownedTree{path: path, directory: os.NewFile(uintptr(fd), path)}, nil
}

func checkNativeAncestor(fd int) error {
	var stat unix.Stat_t
	err := unix.Fstat(fd, &stat)
	if err != nil {
		return fmt.Errorf("inspect native parent custody: %w", err)
	}
	if stat.Uid != 0 && stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("native custody parent belongs to another user")
	}
	if stat.Mode&0022 != 0 && stat.Mode&unix.S_ISVTX == 0 {
		return fmt.Errorf("native custody parent is writable by another user")
	}
	return nil
}

func openDirectoryAt(parent int, name string, create bool) (int, error) {
	fd, err := unix.Openat(parent, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err == unix.ENOENT && create {
		err = unix.Mkdirat(parent, name, 0700)
		if err != nil && err != unix.EEXIST {
			return -1, err
		}
		fd, err = unix.Openat(parent, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	}
	return fd, err
}

func checkOwned(fd int, directory bool) error {
	var stat unix.Stat_t
	err := unix.Fstat(fd, &stat)
	if err != nil {
		return fmt.Errorf("inspect native custody: %w", err)
	}
	if stat.Uid != uint32(os.Getuid()) || stat.Mode&0022 != 0 {
		return fmt.Errorf("native custody ownership or permissions changed")
	}
	if directory {
		if stat.Mode&0077 != 0 {
			return fmt.Errorf("native custody directory must be private")
		}
		return nil
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFREG || stat.Nlink != 1 {
		return fmt.Errorf("native custody file must be regular with one link")
	}
	return nil
}

func (tree *ownedTree) open(name string, flags int) (*os.File, error) {
	if flags&os.O_TRUNC != 0 {
		return nil, fmt.Errorf("native files must be inspected before truncation")
	}
	if name == "." || filepath.IsAbs(name) || filepath.Clean(name) != name || strings.HasPrefix(name, "../") {
		return nil, fmt.Errorf("invalid native relative path")
	}
	parts := strings.Split(name, string(filepath.Separator))
	fd, err := unix.Dup(int(tree.directory.Fd()))
	if err != nil {
		return nil, fmt.Errorf("open native directory handle: %w", err)
	}
	for _, part := range parts[:len(parts)-1] {
		next, openErr := openDirectoryAt(fd, part, flags&os.O_CREATE != 0)
		unix.Close(fd)
		if openErr != nil {
			return nil, fmt.Errorf("open native child directory: %w", openErr)
		}
		fd = next
		err = checkOwned(fd, true)
		if err != nil {
			unix.Close(fd)
			return nil, err
		}
	}
	defer unix.Close(fd)
	fileFD, err := unix.Openat(fd, parts[len(parts)-1], flags|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0600)
	if err != nil {
		return nil, fmt.Errorf("open native file: %w", err)
	}
	err = checkOwned(fileFD, false)
	if err != nil {
		unix.Close(fileFD)
		return nil, err
	}
	return os.NewFile(uintptr(fileFD), filepath.Join(tree.path, name)), nil
}

func (tree *ownedTree) write(name string, content []byte) error {
	file, err := tree.open(name, os.O_CREATE|os.O_RDWR)
	if err != nil {
		return err
	}
	defer file.Close()
	err = file.Truncate(0)
	if err != nil {
		return fmt.Errorf("truncate owned metadata: %w", err)
	}
	_, err = file.Write(content)
	if err != nil {
		return fmt.Errorf("write owned metadata: %w", err)
	}
	return nil
}

type runtimeOwner struct {
	Version                int                `json:"version"`
	AppOrigin              string             `json:"app_origin"`
	AccountID              string             `json:"account_id"`
	WorkspaceID            string             `json:"workspace_id"`
	Enabled                bool               `json:"enabled"`
	Bootstrapped           bool               `json:"bootstrapped"`
	GuestSHA256            string             `json:"guest_sha256,omitempty"`
	K3sSHA256              string             `json:"k3s_sha256,omitempty"`
	Binding                TargetBinding      `json:"binding"`
	Removed                bool               `json:"removed"`
	PreviousRemovedBinding TargetBinding      `json:"previous_removed_binding"`
	PreviousBindingOwner   nativeBindingOwner `json:"previous_binding_owner"`
}

func (owner *runtimeOwner) pinBootstrapInputs() {
	pins := PinnedDescriptor().Artifacts
	owner.GuestSHA256, owner.K3sSHA256 = pins[1].SHA256, pins[2].SHA256
}

func (owner runtimeOwner) compatibleInputs() bool {
	pins := PinnedDescriptor().Artifacts
	return owner.GuestSHA256 == pins[1].SHA256 && owner.K3sSHA256 == pins[2].SHA256
}

func (owner runtimeOwner) matches(scope Scope) bool {
	return owner.AppOrigin == scope.AppOrigin && owner.AccountID == scope.AccountID && owner.WorkspaceID == scope.WorkspaceID
}

func readRuntimeOwner(tree *ownedTree) (runtimeOwner, error) {
	file, err := tree.open("owner.json", os.O_RDONLY)
	if err != nil {
		return runtimeOwner{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return runtimeOwner{}, fmt.Errorf("inspect native owner record: %w", err)
	}
	if info.Size() > 16384 {
		return runtimeOwner{}, fmt.Errorf("native owner record exceeds its bound")
	}
	decoder := json.NewDecoder(io.LimitReader(file, 16384))
	decoder.DisallowUnknownFields()
	var owner runtimeOwner
	err = decoder.Decode(&owner)
	if err != nil {
		return runtimeOwner{}, fmt.Errorf("decode native owner: %w", err)
	}
	if owner.Version != 1 || owner.AppOrigin == "" || owner.AccountID == "" || owner.WorkspaceID == "" {
		return runtimeOwner{}, fmt.Errorf("invalid native owner")
	}
	if owner.Binding != (TargetBinding{}) && !validTargetBinding(owner.Binding) {
		return runtimeOwner{}, fmt.Errorf("invalid native target binding")
	}
	if owner.PreviousRemovedBinding != (TargetBinding{}) && !validTargetBinding(owner.PreviousRemovedBinding) {
		return runtimeOwner{}, fmt.Errorf("invalid previous removed binding")
	}
	if owner.PreviousRemovedBinding != (TargetBinding{}) && (owner.PreviousBindingOwner.AppOrigin == "" || owner.PreviousBindingOwner.AccountID == "" || owner.PreviousBindingOwner.WorkspaceID == "") {
		return runtimeOwner{}, fmt.Errorf("previous removed binding owner missing")
	}
	if owner.Binding != (TargetBinding{}) && owner.PreviousRemovedBinding != (TargetBinding{}) {
		return runtimeOwner{}, fmt.Errorf("native target custody has conflicting identities")
	}
	if owner.Removed && owner.Enabled {
		return runtimeOwner{}, fmt.Errorf("removed runtime cannot remain enabled")
	}
	var trailing json.RawMessage
	err = decoder.Decode(&trailing)
	if err != io.EOF {
		return runtimeOwner{}, fmt.Errorf("unexpected native owner content")
	}
	return owner, nil
}

func writeRuntimeOwner(tree *ownedTree, owner runtimeOwner) error {
	content, err := json.Marshal(owner)
	if err != nil {
		return fmt.Errorf("encode native owner: %w", err)
	}
	return tree.write("owner.json", content)
}
