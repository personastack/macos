package openclawsetup

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// nativeLaunch is ephemeral command input, not another profile authority.
type nativeLaunch struct{ binary, node, path string }

func launchDirectories(home string, environment []string) []string {
	directories := []string{filepath.Join(home, ".local", "bin"), filepath.Join(home, ".npm-global", "bin"), filepath.Join(home, ".openclaw", "bin"), filepath.Join(home, ".openclaw", "tools", "node", "bin"), filepath.Join(home, ".openclaw", "tools", "cli-node", "tools", "node", "bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"}
	for _, entry := range environment {
		if strings.HasPrefix(entry, "PATH=") {
			directories = append(directories, filepath.SplitList(strings.TrimPrefix(entry, "PATH="))...)
		}
	}
	return uniqueAbsoluteDirectories(directories)
}

func uniqueAbsoluteDirectories(input []string) []string {
	result := []string{}
	seen := map[string]bool{}
	for _, directory := range input {
		if !filepath.IsAbs(directory) {
			continue
		}
		directory = filepath.Clean(directory)
		if !seen[directory] {
			seen[directory] = true
			result = append(result, directory)
		}
	}
	return result
}

func resolveNativeLaunch(ctx context.Context, home string, environment []string, executable func(string) bool, entrypoint func(string) (bool, error), nodeVersion func(context.Context, string) (string, error)) (nativeLaunch, error) {
	if err := ctx.Err(); err != nil {
		return nativeLaunch{}, err
	}
	directories := launchDirectories(home, environment)
	binary := ""
	for _, directory := range directories {
		candidate := filepath.Join(directory, "openclaw")
		if executable(candidate) {
			binary = candidate
			break
		}
	}
	if binary == "" {
		return nativeLaunch{}, fmt.Errorf("OpenClaw executable missing")
	}
	needsNode, err := entrypoint(binary)
	if err != nil {
		return nativeLaunch{}, err
	}
	if !needsNode {
		return nativeLaunch{binary: binary, path: strings.Join(directories, string(os.PathListSeparator))}, nil
	}
	// Prefer the interpreter installed beside the selected CLI over another prefix.
	nodeDirectories := uniqueAbsoluteDirectories(append([]string{filepath.Join(filepath.Dir(filepath.Dir(binary)), "tools", "node", "bin"), filepath.Dir(binary)}, directories...))
	foundNode := false
	for _, directory := range nodeDirectories {
		if err := ctx.Err(); err != nil {
			return nativeLaunch{}, err
		}
		node := filepath.Join(directory, "node")
		if !executable(node) {
			continue
		}
		foundNode = true
		version, err := nodeVersion(ctx, node)
		if ctx.Err() != nil {
			return nativeLaunch{}, ctx.Err()
		}
		if err != nil || !supportedNodeVersion(version) {
			continue
		}
		path := strings.Join(uniqueAbsoluteDirectories(append([]string{filepath.Dir(node), filepath.Dir(binary)}, directories...)), string(os.PathListSeparator))
		return nativeLaunch{binary: binary, node: node, path: path}, nil
	}
	if foundNode {
		return nativeLaunch{}, fmt.Errorf("Node 24.16+ (24.x) or 26.1+ required")
	}
	return nativeLaunch{}, fmt.Errorf("Node executable missing")
}

func nativeExecutable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

func nativeEntrypointNeedsNode(path string) (bool, error) {
	file, err := os.Open(path)
	if err != nil {
		return false, fmt.Errorf("read OpenClaw entrypoint: %w", err)
	}
	defer file.Close()
	line, err := bufio.NewReader(io.LimitReader(file, 256)).ReadString('\n')
	if err != nil && err != io.EOF {
		return false, fmt.Errorf("read OpenClaw entrypoint: %w", err)
	}
	switch strings.TrimSpace(line) {
	case "#!/usr/bin/env node":
		return true, nil
	// Pinned install.sh/install-cli.sh wrappers exec their captured absolute Node.
	case "#!/usr/bin/env bash", "#!/bin/bash":
		return false, nil
	default:
		return false, fmt.Errorf("unsupported OpenClaw entrypoint")
	}
}

func nativeNodeVersion(ctx context.Context, node string) (string, error) {
	command := exec.CommandContext(ctx, node, "--version")
	command.WaitDelay = 250 * time.Millisecond
	// The interpreter probe receives no shell initialization or profile secrets.
	command.Env = []string{"PATH=" + filepath.Dir(node) + ":/usr/bin:/bin"}
	output, err := command.Output()
	if err != nil {
		return "", err
	}
	if len(output) > 128 {
		return "", fmt.Errorf("Node version exceeds limit")
	}
	return strings.TrimSpace(string(output)), nil
}

func supportedNodeVersion(version string) bool {
	parts := strings.Split(strings.TrimPrefix(strings.TrimSpace(version), "v"), ".")
	if len(parts) != 3 {
		return false
	}
	numbers := [3]int{}
	for i, part := range parts {
		value, err := strconv.Atoi(part)
		if err != nil || value < 0 {
			return false
		}
		numbers[i] = value
	}
	return numbers[0] == 24 && numbers[1] >= 16 || numbers[0] == 26 && numbers[1] >= 1 || numbers[0] > 26
}
