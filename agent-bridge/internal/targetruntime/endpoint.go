package targetruntime

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
		file, err := os.Open(filepath.Join(root, ".env"))
		if err != nil && !os.IsNotExist(err) {
			return "", fmt.Errorf("read selected Hermes endpoint: %w", err)
		}
		if err == nil {
			defer file.Close()
			scan := bufio.NewScanner(file)
			for scan.Scan() {
				key, value, ok := strings.Cut(strings.TrimPrefix(strings.TrimSpace(scan.Text()), "export "), "=")
				if !ok {
					continue
				}
				value = strings.Trim(strings.TrimSpace(value), "\"'")
				if strings.TrimSpace(key) == "API_SERVER_PORT" {
					port, err = strconv.Atoi(value)
					if err != nil {
						return "", fmt.Errorf("selected Hermes port invalid")
					}
				}
				if strings.TrimSpace(key) == "API_SERVER_HOST" && value != "127.0.0.1" && value != "localhost" && value != "::1" {
					return "", fmt.Errorf("runtime_conflict: selected Hermes listener is not loopback")
				}
			}
			if err = scan.Err(); err != nil {
				return "", err
			}
		}
	} else {
		return "", fmt.Errorf("runtime_unsupported")
	}
	if port < 1 || port > 65535 {
		return "", fmt.Errorf("runtime_conflict: selected profile port invalid")
	}
	return scheme + "://127.0.0.1:" + strconv.Itoa(port), nil
}
