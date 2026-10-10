package targetruntime

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"
)

const maxProcessArguments = 1 << 20

// profileEnvironment parses Darwin KERN_PROCARGS2 without treating argv as env.
// Only the two profile fields leave this boundary. Secrets remain in local bytes.
func profileEnvironment(raw []byte) (string, string, error) {
	if len(raw) < 5 || len(raw) > maxProcessArguments {
		return "", "", fmt.Errorf("invalid process argument buffer")
	}
	argc := int(binary.LittleEndian.Uint32(raw[:4]))
	if argc < 1 || argc > 65536 {
		return "", "", fmt.Errorf("invalid process argument count")
	}
	data, err := afterProcessString(raw[4:]) // executable path
	if err != nil {
		return "", "", err
	}
	data = bytes.TrimLeft(data, "\x00") // kernel padding before argv
	for range argc {
		data, err = afterProcessString(data)
		if err != nil {
			return "", "", err
		}
	}
	data = bytes.TrimLeft(data, "\x00") // title mutation leaves empty argv/padding
	root, config := "", ""
	rootFound, configFound := false, false
	for len(data) > 0 && data[0] != 0 {
		end := bytes.IndexByte(data, 0)
		if end < 0 {
			return "", "", fmt.Errorf("unterminated process environment")
		}
		field := string(data[:end])
		data = data[end+1:]
		if strings.HasPrefix(field, "OPENCLAW_STATE_DIR=") {
			if rootFound {
				return "", "", fmt.Errorf("ambiguous process profile")
			}
			root, rootFound = strings.TrimPrefix(field, "OPENCLAW_STATE_DIR="), true
		}
		if strings.HasPrefix(field, "OPENCLAW_CONFIG_PATH=") {
			if configFound {
				return "", "", fmt.Errorf("ambiguous process profile")
			}
			config, configFound = strings.TrimPrefix(field, "OPENCLAW_CONFIG_PATH="), true
		}
	}
	return root, config, nil
}

func afterProcessString(data []byte) ([]byte, error) {
	end := bytes.IndexByte(data, 0)
	if end < 0 {
		return nil, fmt.Errorf("unterminated process argument")
	}
	return data[end+1:], nil
}
