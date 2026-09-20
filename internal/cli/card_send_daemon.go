package cli

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

func newCLICardCommandID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", fmt.Errorf("create card command ID: %w", err)
	}
	return "cmd_" + hex.EncodeToString(value[:]), nil
}
