package targetinventory

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// OpenClawAgent is private helper inventory. CandidateID is safe for native UI;
// ID stays inside the helper and is never a PersonaStack profile target.
type OpenClawAgent struct{ CandidateID, Label, ID string }
type openClawAgentEntry struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type openClawNamedAgentEntry struct {
	Name string `json:"name"`
}
type openClawAgentConfiguration struct {
	Agents struct {
		List    json.RawMessage `json:"list"`
		Entries json.RawMessage `json:"entries"`
	} `json:"agents"`
}

func rosterEntries(document openClawAgentConfiguration) ([]openClawAgentEntry, error) {
	listed, keyed := len(document.Agents.List) > 0, len(document.Agents.Entries) > 0
	if listed && keyed {
		return nil, fmt.Errorf("ambiguous OpenClaw agent configuration")
	}
	if !listed && !keyed {
		// Pinned upstream agent-roster.ts listAgentIds supports this legacy pre-roster default only.
		return []openClawAgentEntry{{ID: "main"}}, nil
	}
	entries := []openClawAgentEntry{}
	if listed {
		if string(document.Agents.List) == "null" {
			return nil, fmt.Errorf("invalid OpenClaw agent list")
		}
		err := json.Unmarshal(document.Agents.List, &entries)
		if err != nil {
			return nil, fmt.Errorf("decode OpenClaw agent list: %w", err)
		}
		return entries, nil
	}
	if string(document.Agents.Entries) == "null" {
		return nil, fmt.Errorf("invalid OpenClaw agent entries")
	}
	var keyedEntries map[string]*openClawNamedAgentEntry
	err := json.Unmarshal(document.Agents.Entries, &keyedEntries)
	if err != nil {
		return nil, fmt.Errorf("decode OpenClaw agent entries: %w", err)
	}
	for id, entry := range keyedEntries {
		if entry == nil {
			return nil, fmt.Errorf("invalid OpenClaw agent entry")
		}
		entries = append(entries, openClawAgentEntry{ID: id, Name: entry.Name})
	}
	return entries, nil
}

func openClawAgents(path, physical, seed string) ([]OpenClawAgent, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read selected OpenClaw agents: %w", err)
	}
	if len(raw) > 256*1024 {
		return nil, fmt.Errorf("OpenClaw config exceeds native limit")
	}
	var document openClawAgentConfiguration
	err = json.Unmarshal(raw, &document)
	if err != nil {
		return nil, fmt.Errorf("decode selected OpenClaw agents: %w", err)
	}
	entries, err := rosterEntries(document)
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, fmt.Errorf("OpenClaw roster declares no agents")
	}
	if len(entries) > 128 {
		return nil, fmt.Errorf("OpenClaw agent roster exceeds native limit")
	}
	fingerprint := sha256.Sum256(raw)
	result := []OpenClawAgent{}
	seen := map[string]bool{}
	for _, entry := range entries {
		id := strings.ToLower(strings.TrimSpace(entry.ID))
		if !validOpenClawAgentID(id) || seen[id] {
			return nil, fmt.Errorf("invalid or duplicate OpenClaw agent")
		}
		seen[id] = true
		label := strings.TrimSpace(entry.Name)
		if label == "" || label == id {
			label = id
		} else {
			label = label + " (" + id + ")"
		}
		if len(label) > 256 {
			return nil, fmt.Errorf("OpenClaw agent label exceeds native limit")
		}
		result = append(result, OpenClawAgent{CandidateID: opaqueID(seed, "agent", physical, hex.EncodeToString(fingerprint[:]), id), Label: label, ID: id})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result, nil
}
func validOpenClawAgentID(id string) bool {
	if len(id) == 0 || len(id) > 128 {
		return false
	}
	for _, ch := range id {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-') {
			return false
		}
	}
	return true
}

// SelectOpenClawAgent accepts a native opaque choice, never a caller-supplied ID.
func SelectOpenClawAgent(profile Profile, candidate string) (Profile, error) {
	if profile.Kind.String() != "openclaw" {
		if candidate != "" {
			return Profile{}, fmt.Errorf("agent choice does not belong to Hermes")
		}
		return profile, nil
	}
	for _, agent := range profile.OpenClawAgents {
		if agent.CandidateID == candidate {
			profile.Resolved.OpenClawAgentID = agent.ID
			return profile, nil
		}
	}
	if candidate == "" && len(profile.OpenClawAgents) == 1 {
		profile.Resolved.OpenClawAgentID = profile.OpenClawAgents[0].ID
		return profile, nil
	}
	return Profile{}, fmt.Errorf("selected OpenClaw agent required or changed")
}
func selectStoredOpenClawAgent(profile Profile, id string) (ResolvedTarget, error) {
	if id == "" {
		return ResolvedTarget{}, fmt.Errorf("native OpenClaw agent selection required")
	}
	for _, agent := range profile.OpenClawAgents {
		if agent.ID == id {
			resolved := profile.Resolved
			resolved.OpenClawAgentID = id
			return resolved, nil
		}
	}
	return ResolvedTarget{}, fmt.Errorf("selected OpenClaw agent no longer available")
}
