// Package targetinventory resolves only the current user's native profile inventory.
package targetinventory

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	connectorruntime "github.com/personastack/macos/agent-bridge/internal/runtime"
)

type ResolvedTarget struct {
	Username, HomeDir                                                           string
	UID, GID                                                                    int
	GroupIDs                                                                    []int
	HermesHome, OpenClawAgentID, StateRoot, ConfigPath, ProfileName, PhysicalID string
}
type Profile struct {
	CandidateID, AccountCandidateID, Label string
	Kind                                   connectorruntime.AdapterKind
	Resolved                               ResolvedTarget
	OpenClawAgents                         []OpenClawAgent
	ConflictCode                           string
}

func CanonicalPath(path string) (string, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", fmt.Errorf("resolve native profile: %w", err)
	}
	absolute, err := filepath.Abs(resolved)
	if err != nil {
		return "", fmt.Errorf("resolve native absolute path: %w", err)
	}
	return filepath.Clean(absolute), nil
}
func SharedPhysicalTarget(a, b ResolvedTarget) bool {
	if (a.StateRoot != "" && a.StateRoot == b.StateRoot) || (a.ConfigPath != "" && a.ConfigPath == b.ConfigPath) {
		return true
	}
	for _, pair := range [][2]string{{a.StateRoot, b.StateRoot}, {a.ConfigPath, b.ConfigPath}} {
		left, err := os.Stat(pair[0])
		if err != nil {
			continue
		}
		right, err := os.Stat(pair[1])
		if err == nil && os.SameFile(left, right) {
			return true
		}
	}
	return false
}
func Profiles(kind connectorruntime.AdapterKind, seed string) ([]Profile, []error) {
	current, err := user.Current()
	if err != nil {
		return nil, []error{fmt.Errorf("current user: %w", err)}
	}
	uid, err := strconv.Atoi(current.Uid)
	if err != nil {
		return nil, []error{fmt.Errorf("current user UID: %w", err)}
	}
	gid, _ := strconv.Atoi(current.Gid)
	return DiscoverAt(current.HomeDir, current.Username, uid, gid, kind, seed)
}

// DiscoverAt provides a fixture seam without process environment mutation.
func DiscoverAt(home, username string, uid, gid int, kind connectorruntime.AdapterKind, seed string) ([]Profile, []error) {
	if seed == "" {
		return nil, []error{fmt.Errorf("installation inventory seed required")}
	}
	paths := [][2]string{}
	warnings := []error{}
	switch kind {
	case connectorruntime.AdapterKindHermes:
		base := filepath.Join(home, ".hermes")
		paths = append(paths, [2]string{"default", base})
		entries, err := os.ReadDir(filepath.Join(base, "profiles"))
		if err != nil && !os.IsNotExist(err) {
			warnings = append(warnings, fmt.Errorf("list Hermes profiles: %w", err))
		}
		for _, entry := range entries {
			if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
				paths = append(paths, [2]string{entry.Name(), filepath.Join(base, "profiles", entry.Name())})
			}
		}
	case connectorruntime.AdapterKindOpenClaw:
		paths = append(paths, [2]string{"default", filepath.Join(home, ".openclaw")})
		entries, err := os.ReadDir(home)
		if err != nil {
			return nil, []error{fmt.Errorf("list current user profiles: %w", err)}
		}
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), ".openclaw-") && (entry.IsDir() || entry.Type()&os.ModeSymlink != 0) {
				paths = append(paths, [2]string{strings.TrimPrefix(entry.Name(), ".openclaw-"), filepath.Join(home, entry.Name())})
			}
		}
	default:
		return nil, []error{fmt.Errorf("runtime_unsupported")}
	}
	profiles := []Profile{}
	for _, pair := range paths {
		root, err := CanonicalPath(pair[1])
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			warnings = append(warnings, err)
			continue
		}
		info, err := os.Stat(root)
		if err != nil || !info.IsDir() {
			warnings = append(warnings, fmt.Errorf("native profile root unavailable"))
			continue
		}
		configName := "config.yaml"
		if kind == connectorruntime.AdapterKindOpenClaw {
			configName = "openclaw.json"
		}
		configPath, err := CanonicalPath(filepath.Join(pair[1], configName))
		if err != nil {
			warnings = append(warnings, fmt.Errorf("native profile config unavailable: %w", err))
			continue
		}
		physical := opaqueID(seed, strconv.Itoa(uid), kind.String(), root, configPath)
		resolved := ResolvedTarget{Username: username, HomeDir: home, UID: uid, GID: gid, StateRoot: root, ConfigPath: filepath.Join(pair[1], configName), ProfileName: pair[0], PhysicalID: physical}
		if kind == connectorruntime.AdapterKindHermes {
			resolved.HermesHome = root
		}
		label := pair[0]
		if label == "default" {
			label = "Default"
		}
		profile := Profile{CandidateID: physical, AccountCandidateID: opaqueID(seed, "account", strconv.Itoa(uid)), Label: label, Kind: kind, Resolved: resolved}
		if kind == connectorruntime.AdapterKindOpenClaw {
			profile.OpenClawAgents, err = openClawAgents(configPath, physical, seed)
			if err != nil {
				warnings = append(warnings, err)
				profile.ConflictCode = "native_config_unsupported"
			}
		}
		profiles = append(profiles, profile)
	}
	sort.Slice(profiles, func(i, j int) bool { return profiles[i].Label < profiles[j].Label })
	return profiles, warnings
}
func Discover(kind connectorruntime.AdapterKind, seeds ...string) (externalagentprotocol.TargetInventoryPayload, []error) {
	seed := ""
	if len(seeds) > 0 {
		seed = seeds[0]
	}
	profiles, warnings := Profiles(kind, seed)
	result := externalagentprotocol.TargetInventoryPayload{Accounts: []externalagentprotocol.RuntimeAccountCandidate{}, DiscoveryStatus: externalagentprotocol.DiscoveryStatusComplete}
	if len(profiles) > 0 {
		account := externalagentprotocol.RuntimeAccountCandidate{CandidateID: profiles[0].AccountCandidateID, Label: profiles[0].Resolved.Username, Profiles: []externalagentprotocol.RuntimeProfileCandidate{}}
		for _, p := range profiles {
			account.Profiles = append(account.Profiles, externalagentprotocol.RuntimeProfileCandidate{CandidateID: p.CandidateID, Label: p.Label, RuntimeKind: protocolRuntimeKind(kind)})
		}
		result.Accounts = append(result.Accounts, account)
	}
	if len(warnings) > 0 {
		result.DiscoveryStatus = externalagentprotocol.DiscoveryStatusDegraded
	}
	return result, warnings
}
func Resolve(kind connectorruntime.AdapterKind, target *externalagentprotocol.RuntimeTarget, seeds ...string) (ResolvedTarget, error) {
	if target == nil || target.RuntimeKind != protocolRuntimeKind(kind) {
		return ResolvedTarget{}, fmt.Errorf("runtime target required")
	}
	seed := ""
	if len(seeds) > 0 {
		seed = seeds[0]
	}
	profiles, _ := Profiles(kind, seed)
	selected := ""
	if len(seeds) > 1 {
		selected = seeds[1]
	}
	return ResolveProfiles(kind, target, profiles, selected)
}

// ResolveProfiles shares native profile authority with injected in-process fixtures.
func ResolveProfiles(kind connectorruntime.AdapterKind, target *externalagentprotocol.RuntimeTarget, profiles []Profile, selected string) (ResolvedTarget, error) {
	if target == nil || target.RuntimeKind != protocolRuntimeKind(kind) {
		return ResolvedTarget{}, fmt.Errorf("runtime target required")
	}
	for _, p := range profiles {
		if p.Kind == kind && p.CandidateID == target.ProfileCandidateID && p.AccountCandidateID == target.AccountCandidateID {
			if kind == connectorruntime.AdapterKindOpenClaw {
				return selectStoredOpenClawAgent(p, selected)
			}
			return p.Resolved, nil
		}
	}
	return ResolvedTarget{}, fmt.Errorf("selected runtime profile no longer available")
}

func opaqueID(seed string, parts ...string) string {
	mac := hmac.New(sha256.New, []byte(seed))
	_, _ = mac.Write([]byte(strings.Join(parts, "\x00")))
	return "rt_" + hex.EncodeToString(mac.Sum(nil)[:16])
}
func protocolRuntimeKind(kind connectorruntime.AdapterKind) externalagentprotocol.RuntimeKind {
	if kind == connectorruntime.AdapterKindOpenClaw {
		return externalagentprotocol.RuntimeKindOpenClaw
	}
	return externalagentprotocol.RuntimeKindHermes
}
