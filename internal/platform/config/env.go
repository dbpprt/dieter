package config

import (
	"os"
	"sort"
	"strconv"
	"strings"
)

// Env is a snapshot of environment variables.
type Env map[string]string

// Environ snapshots the process environment. Composition roots call it once,
// after LoadEnvFile, and pass typed configuration down.
func Environ() Env { return EnvFrom(os.Environ()) }

// EnvFrom builds an Env from KEY=VALUE entries in os.Environ form. Later
// entries win.
func EnvFrom(entries []string) Env {
	env := make(Env, len(entries))
	for _, entry := range entries {
		if key, value, ok := strings.Cut(entry, "="); ok && key != "" {
			env[key] = value
		}
	}
	return env
}

// Value returns a variable with surrounding whitespace removed.
func (e Env) Value(key string) string { return strings.TrimSpace(e[key]) }

// Enabled reports whether a variable is exactly "1".
func (e Env) Enabled(key string) bool { return e[key] == "1" }

// NotDisabled reports whether a default-on variable is anything but "0".
func (e Env) NotDisabled(key string) bool { return e[key] != "0" }

// List returns the variables in os.Environ form, sorted by name, for child
// processes.
func (e Env) List() []string {
	entries := make([]string, 0, len(e))
	for key, value := range e {
		entries = append(entries, key+"="+value)
	}
	sort.Strings(entries)
	return entries
}

// Fields splits a comma-separated variable into trimmed non-empty values.
func (e Env) Fields(key string) []string {
	var values []string
	for _, value := range strings.Split(e[key], ",") {
		if value = strings.TrimSpace(value); value != "" {
			values = append(values, value)
		}
	}
	return values
}

// Uint returns an unsigned integer variable, or nil when it is unset or
// invalid.
func (e Env) Uint(key string) *uint64 {
	raw := e.Value(key)
	if raw == "" {
		return nil
	}
	value, err := strconv.ParseUint(raw, 10, 64)
	if err != nil {
		return nil
	}
	return &value
}

// Service handoff variables written by a daemon that re-executes itself into
// an activated release and read by the replacement process.
const (
	ServiceLockFDVar     = "DIETER_SERVICE_LOCK_FD"
	ServiceActivationVar = "DIETER_SERVICE_ACTIVATION"
)
