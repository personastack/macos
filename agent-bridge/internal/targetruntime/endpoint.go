package targetruntime

import (
	"encoding/json"
	"fmt"
	"github.com/personastack/macos/agent-bridge/internal/hermessetup"
	"os"
	"strconv"
)

// ProfileEndpoint reads only the selected profile's native listener configuration.
// Ownership must still be proved independently before attaching to the port.
func ProfileEndpoint(kind, root, configPath string) (string, error) {
	port := 8642
	scheme := "http"
	if kind == "openclaw" {
		scheme = "ws"
		port = 18789
		raw, err := os.ReadFile(configPath)
		if err != nil {
			return "", fmt.Errorf("read selected OpenClaw endpoint: %w", err)
		}
		var config struct {
			Gateway struct {
				Port *int `json:"port"`
			} `json:"gateway"`
		}
		if err = json.Unmarshal(raw, &config); err != nil {
			return "", fmt.Errorf("malformed selected OpenClaw config: %w", err)
		}
		if config.Gateway.Port != nil {
			port = *config.Gateway.Port
		}
	} else if kind == "hermes" {
		return hermessetup.APIEndpoint(hermessetup.ResolvePaths("", root))
	} else {
		return "", fmt.Errorf("runtime_unsupported")
	}
	if port < 1 || port > 65535 {
		return "", fmt.Errorf("runtime_conflict: selected profile port invalid")
	}
	return scheme + "://127.0.0.1:" + strconv.Itoa(port), nil
}
