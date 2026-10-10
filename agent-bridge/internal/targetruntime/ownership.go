package targetruntime

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// EndpointEvidence keeps attribution independent of native health responses.
type EndpointEvidence struct {
	Listening                          bool
	UID                                int
	RuntimeKind, StateRoot, ConfigPath string
}

const ProfileScopeUnverifiedMessage = "Gateway profile scope cannot be verified. Stop it manually, then Repair."

var ErrProfileScopeUnverified = errors.New("runtime_conflict: " + ProfileScopeUnverifiedMessage)

func MatchEndpoint(e EndpointEvidence, uid int, kind, root, config string) (bool, error) {
	if !e.Listening {
		return false, nil
	}
	if kind == "openclaw" && e.UID == uid && e.RuntimeKind == kind && (e.StateRoot == "" || e.ConfigPath == "") {
		return false, ErrProfileScopeUnverified
	}
	if e.UID != uid || e.RuntimeKind != kind || e.StateRoot != root || e.ConfigPath != config {
		return false, fmt.Errorf("runtime_conflict: listener ownership does not match selected profile")
	}
	return true, nil
}
func VerifyEndpoint(ctx context.Context, endpoint, root, config, kind string) (bool, error) {
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Port() == "" {
		return false, fmt.Errorf("runtime_conflict: selected loopback endpoint required")
	}
	// lsof identifies the listener first. A health response never authorizes attachment.
	command := exec.CommandContext(ctx, "/usr/sbin/lsof", "-nP", "-iTCP:"+parsed.Port(), "-sTCP:LISTEN", "-t")
	raw, err := command.Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == 1 {
			return false, nil
		}
		return false, fmt.Errorf("runtime_conflict: cannot attribute gateway listener")
	}
	pids := strings.Fields(string(raw))
	if len(pids) != 1 {
		return false, fmt.Errorf("runtime_conflict: gateway listener owner is ambiguous")
	}
	process := exec.CommandContext(ctx, "/bin/ps", "eww", "-p", pids[0], "-o", "uid=,command=")
	raw, err = process.Output()
	if err != nil {
		return false, fmt.Errorf("runtime_conflict: cannot inspect gateway owner")
	}
	text := string(raw)
	fields := strings.Fields(text)
	if len(fields) < 2 {
		return false, fmt.Errorf("runtime_conflict: gateway process evidence missing")
	}
	uid, err := strconv.Atoi(fields[0])
	if err != nil {
		return false, fmt.Errorf("runtime_conflict: gateway UID unavailable")
	}
	if uid != os.Geteuid() {
		return false, fmt.Errorf("runtime_conflict: listener ownership does not match selected profile")
	}
	e := ProcessEvidence(text, kind, root, config)
	e.UID = uid
	if isOpenClawGatewayTitle(fields, kind) {
		pid, parseErr := strconv.Atoi(pids[0])
		if parseErr != nil || pid <= 0 {
			return false, fmt.Errorf("runtime_conflict: gateway PID unavailable")
		}
		// macOS ps loses environment attribution after Node changes process.title.
		// Read the same listener's original kernel environment after checking UID.
		e.StateRoot, e.ConfigPath, err = nativeProfileEnvironment(pid)
		if err != nil {
			return false, fmt.Errorf("runtime_conflict: cannot inspect gateway profile")
		}
	}
	return MatchEndpoint(e, os.Geteuid(), kind, root, config)
}

// ProcessEvidence requires exact environment fields. Prefix paths never match.
// Ambiguous whitespace in process output is refused instead of guessed.
func ProcessEvidence(text, kind, root, config string) EndpointEvidence {
	e := EndpointEvidence{Listening: true}
	fields := strings.Fields(text)
	runtimeFound, gatewayFound, rootFound, configFound := false, false, false, false
	if isOpenClawGatewayTitle(fields, kind) {
		runtimeFound, gatewayFound = true, true
	}
	for _, field := range fields {
		if field == kind || strings.HasSuffix(field, "/"+kind) {
			runtimeFound = true
		}
		if field == "gateway" {
			gatewayFound = true
		}
		if field == "HERMES_HOME="+root && kind == "hermes" {
			rootFound = true
			configFound = true
		}
		if field == "OPENCLAW_STATE_DIR="+root && kind == "openclaw" {
			rootFound = true
		}
		if field == "OPENCLAW_CONFIG_PATH="+config && kind == "openclaw" {
			configFound = true
		}
	}
	if runtimeFound && gatewayFound {
		e.RuntimeKind = kind
	}
	if rootFound {
		e.StateRoot = root
	}
	if configFound {
		e.ConfigPath = config
	}
	return e
}

func isOpenClawGatewayTitle(fields []string, kind string) bool {
	return kind == "openclaw" && len(fields) >= 2 && fields[1] == "openclaw-gateway"
}
