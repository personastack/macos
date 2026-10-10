package targetruntime

import (
	"context"
	"os/exec"
	"strconv"
	"strings"

	"github.com/personastack/macos/agent-bridge/internal/targetinventory"
)

type commandOutput func(context.Context, string, ...string) ([]byte, error)

// A CLI --port override can leave the configured port unused while the same
// profile still runs elsewhere. Only the absent configured-port path scans.
func verifyNoOtherOpenClawListener(ctx context.Context, root, config string, uid int, run commandOutput, environment func(int) (string, string, error)) error {
	raw, err := run(ctx, "/usr/sbin/lsof", "-nP", "-u", strconv.Itoa(uid), "-a", "-iTCP", "-sTCP:LISTEN", "-Fp")
	if err != nil {
		if exit, ok := err.(*exec.ExitError); ok && exit.ExitCode() == 1 {
			return nil
		}
		return ErrProfileScopeUnverified
	}
	pids, err := listenerProcessIDs(raw)
	if err != nil {
		return err
	}
	for _, pid := range pids {
		if err := verifyDifferentOpenClawListener(ctx, pid, root, config, uid, run, environment); err != nil {
			return err
		}
	}
	return nil
}

func verifyDifferentOpenClawListener(ctx context.Context, pid int, root, config string, uid int, run commandOutput, environment func(int) (string, string, error)) error {
	raw, err := run(ctx, "/bin/ps", "-p", strconv.Itoa(pid), "-o", "uid=,command=")
	if err != nil {
		return ErrProfileScopeUnverified
	}
	fields := strings.Fields(string(raw))
	if len(fields) < 2 || fields[0] != strconv.Itoa(uid) {
		return ErrProfileScopeUnverified
	}
	if ProcessEvidence(string(raw), "openclaw", root, config).RuntimeKind != "openclaw" {
		return nil
	}
	actualRoot, actualConfig, err := environment(pid)
	if err != nil || actualRoot == "" || actualConfig == "" {
		return ErrProfileScopeUnverified
	}
	actualRoot, err = targetinventory.CanonicalPath(actualRoot)
	if err != nil {
		return ErrProfileScopeUnverified
	}
	actualConfig, err = targetinventory.CanonicalPath(actualConfig)
	if err != nil {
		return ErrProfileScopeUnverified
	}
	if targetinventory.SharedPhysicalTarget(targetinventory.ResolvedTarget{StateRoot: root, ConfigPath: config}, targetinventory.ResolvedTarget{StateRoot: actualRoot, ConfigPath: actualConfig}) {
		return ErrProfileScopeUnverified
	}
	return nil
}

func listenerProcessIDs(raw []byte) ([]int, error) {
	if len(raw) > 64*1024 {
		return nil, ErrProfileScopeUnverified
	}
	if len(raw) == 0 {
		return []int{}, nil
	}
	pids, seen := []int{}, map[int]bool{}
	needsDescriptor := false
	for _, field := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if len(field) < 2 || !numericFieldAtLeast(field[1:], 0) {
			return nil, ErrProfileScopeUnverified
		}
		switch field[0] {
		case 'p':
			pid, _ := strconv.Atoi(field[1:])
			if pid <= 0 || needsDescriptor {
				return nil, ErrProfileScopeUnverified
			}
			needsDescriptor = true
			if !seen[pid] {
				pids = append(pids, pid)
				seen[pid] = true
			}
		case 'f':
			if len(pids) == 0 {
				return nil, ErrProfileScopeUnverified
			}
			needsDescriptor = false
		default:
			return nil, ErrProfileScopeUnverified
		}
	}
	if len(pids) > 128 || needsDescriptor {
		return nil, ErrProfileScopeUnverified
	}
	return pids, nil
}

// Bound native process evidence in memory. Never log or retain raw argv/env.
func nativeCommandOutput(ctx context.Context, binary string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, binary, args...)
	output := &boundedProcessOutput{}
	cmd.Stdout = output
	err := cmd.Run()
	return output.raw, err
}

type boundedProcessOutput struct{ raw []byte }

func (output *boundedProcessOutput) Write(raw []byte) (int, error) {
	if len(output.raw)+len(raw) > 64*1024 {
		return 0, ErrProfileScopeUnverified
	}
	output.raw = append(output.raw, raw...)
	return len(raw), nil
}
