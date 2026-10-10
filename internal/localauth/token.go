// Package localauth guards the raw loopback daemon API. Binding to loopback
// keeps other hosts out, but not other local users, containers sharing the host
// network, or a request-forgery bug in another local service. Every raw request
// must present a random token that only the daemon user can read.
package localauth

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Header carries the token. It is separate from authorization so forwarded
// remote bearers and operator subjects keep their own meaning.
const Header = "x-dieter-local-token"

const tokenBytes = 32

func Path(root string) string { return filepath.Join(root, "runtime", "local-api-token") }

// Rotate replaces the token. The daemon rotates once per start, before it
// listens, so a token copied from an earlier run stops working.
func Rotate(root string) (string, error) {
	raw := make([]byte, tokenBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	if err := write(Path(root), token); err != nil {
		return "", fmt.Errorf("write local API token: %w", err)
	}
	return token, nil
}

// Ensure returns the current token and creates one when none exists or the
// file is readable by anyone but its owner.
func Ensure(root string) (string, error) {
	if token, err := Read(root); err == nil {
		return token, nil
	} else if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, errExposed) && !errors.Is(err, errMalformed) {
		return "", err
	}
	return Rotate(root)
}

var (
	errExposed   = errors.New("local API token is readable by other users")
	errMalformed = errors.New("local API token is malformed")
)

func Read(root string) (string, error) {
	path := Path(root)
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return "", errExposed
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(string(raw))
	if decoded, decodeErr := base64.RawURLEncoding.DecodeString(token); decodeErr != nil || len(decoded) != tokenBytes {
		return "", errMalformed
	}
	return token, nil
}

// Valid compares in constant time and never accepts an empty expectation, so a
// daemon that could not load its token rejects every raw request.
func Valid(expected, presented string) bool {
	return expected != "" && subtle.ConstantTimeCompare([]byte(expected), []byte(presented)) == 1
}

// Credentials attach a token known to the caller, such as the daemon's own
// direct and relay forwarders.
type Credentials struct{ Token string }

func (c Credentials) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	if c.Token == "" {
		return nil, errors.New("local API token is unavailable")
	}
	return map[string]string{Header: c.Token}, nil
}

func (Credentials) RequireTransportSecurity() bool { return false }

// FileCredentials read the token on every call, so a long-lived client keeps
// working after the daemon restarts and rotates it.
type FileCredentials struct{ Root string }

func (c FileCredentials) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	token, err := Read(c.Root)
	if err != nil {
		return nil, fmt.Errorf("read local Dieter daemon token: %w", err)
	}
	return map[string]string{Header: token}, nil
}

func (FileCredentials) RequireTransportSecurity() bool { return false }

func write(path, token string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".local-api-token-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.WriteString(token + "\n"); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
