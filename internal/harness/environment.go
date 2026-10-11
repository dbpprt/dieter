package harness

import (
	"os"
	"strings"
)

// Environment is the host environment harness workers and model discovery
// inherit. The daemon passes its parsed configuration; a zero value inherits
// the current process environment with no overrides.
type Environment struct {
	// Variables is the environment in os.Environ form. Nil inherits the
	// process environment at each launch.
	Variables []string
	// RuntimeDir replaces the embedded runtime with a staged directory
	// (DIETER_HARNESS_RUNTIME_DIR).
	RuntimeDir string
	// PassThrough names additional variables forwarded to harness workers
	// (DIETER_HARNESS_ENV).
	PassThrough []string
}

func (e Environment) environ() []string {
	if e.Variables != nil {
		return append([]string(nil), e.Variables...)
	}
	return os.Environ()
}

// Value returns one variable of the environment, or "" when it is unset.
func (e Environment) Value(key string) string {
	prefix := key + "="
	value := ""
	for _, item := range e.environ() {
		if strings.HasPrefix(item, prefix) {
			value = strings.TrimPrefix(item, prefix)
		}
	}
	return value
}
