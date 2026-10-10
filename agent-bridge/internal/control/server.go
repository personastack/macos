package control

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

func DefaultDirectory() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve native home: %w", err)
	}
	return filepath.Join(home, "Library", "Application Support", "PersonaStack", "AgentBridge"), nil
}
func EnsurePrivateDirectory(path string) error {
	err := os.MkdirAll(path, 0o700)
	if err != nil {
		return fmt.Errorf("create private control directory: %w", err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("inspect private directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o700 || !ownedFile(info) {
		return fmt.Errorf("unsafe private control directory")
	}
	return nil
}
func ownedFile(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Geteuid()
}
func LoadEnvironments(directory string) ([]Environment, error) {
	path := filepath.Join(directory, "environments.json")
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("inspect environment file: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || !ownedFile(info) {
		return nil, fmt.Errorf("unsafe environment file")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read native environments: %w", err)
	}
	if len(raw) > MaxBytes {
		return nil, fmt.Errorf("environment file exceeds limit")
	}
	environments := []Environment{}
	err = strict(raw, &environments)
	if err != nil {
		return nil, err
	}
	return environments, nil
}
func Serve(ctx context.Context, directory string, controller *Controller) error {
	err := EnsurePrivateDirectory(directory)
	if err != nil {
		return err
	}
	path := filepath.Join(directory, "control.sock")
	if len(path) > 103 {
		socketDirectory := filepath.Join("/private/tmp", "personastack-agent-bridge-"+strconv.Itoa(os.Geteuid()))
		err = EnsurePrivateDirectory(socketDirectory)
		if err != nil {
			return err
		}
		path = filepath.Join(socketDirectory, "control.sock")
	}
	info, err := os.Lstat(path)
	if err == nil {
		if info.Mode()&os.ModeSocket == 0 || !ownedFile(info) {
			return fmt.Errorf("unsafe existing control socket")
		}
		connection, dialErr := net.DialTimeout("unix", path, 100*time.Millisecond)
		if dialErr == nil {
			connection.Close()
			return fmt.Errorf("agent bridge already running")
		}
		err = os.Remove(path)
		if err != nil {
			return fmt.Errorf("remove stale private socket: %w", err)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect private socket: %w", err)
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return fmt.Errorf("listen private control: %w", err)
	}
	defer listener.Close()
	err = os.Chmod(path, 0o600)
	if err != nil {
		return fmt.Errorf("secure control socket: %w", err)
	}
	go func() { <-ctx.Done(); _ = listener.Close() }()
	for {
		connection, err := listener.AcceptUnix()
		if ctx.Err() != nil {
			return nil
		}
		if err != nil {
			return fmt.Errorf("accept control: %w", err)
		}
		uid, err := peerUID(connection)
		if err != nil || uid != os.Geteuid() {
			connection.Close()
			continue
		}
		go handleConnection(ctx, connection, controller)
	}
}
func handleConnection(ctx context.Context, connection net.Conn, controller *Controller) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(30 * time.Second))
	reader := bufio.NewReader(io.LimitReader(connection, MaxBytes+1))
	line, err := reader.ReadBytes('\n')
	if err != nil && err != io.EOF {
		return
	}
	response := controller.Dispatch(ctx, line)
	raw, err := json.Marshal(response)
	if err != nil || len(raw) > MaxBytes {
		return
	}
	_, _ = connection.Write(append(raw, '\n'))
	if response.Result != nil && response.Result.Disabled != nil && *response.Result.Disabled && controller.Shutdown != nil {
		controller.Shutdown()
	}
}
