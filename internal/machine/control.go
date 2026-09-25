package machine

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Operation string

const (
	OperationRestart  Operation = "restart"
	OperationShutdown Operation = "shutdown"
	OperationUpdate   Operation = "update"
)

var ErrOperationUnsupported = errors.New("machine operation is not supported on this host")

type OperationCapability struct {
	Operation         Operation
	Supported         bool
	Authorized        bool
	UnavailableReason string
	// A failed probe says nothing about installation state. Retry it on the
	// next request instead of disabling the operation for the cache lifetime.
	retryable bool
}

var operationCapabilityCache struct {
	sync.Mutex
	values map[string]cachedOperationCapabilities
}

type cachedOperationCapabilities struct {
	values []OperationCapability
	at     time.Time
}

func OperationCapabilities(ctx context.Context) []OperationCapability {
	return OperationCapabilitiesAtRoot(ctx, defaultRoot())
}

func OperationCapabilitiesAtRoot(ctx context.Context, root string) []OperationCapability {
	return cachedOperationCapabilitiesAtRoot(ctx, root, operationCapabilities)
}

func cachedOperationCapabilitiesAtRoot(ctx context.Context, root string, collect func(context.Context, string) []OperationCapability) []OperationCapability {
	operationCapabilityCache.Lock()
	defer operationCapabilityCache.Unlock()
	if operationCapabilityCache.values == nil {
		operationCapabilityCache.values = map[string]cachedOperationCapabilities{}
	}
	if cached := operationCapabilityCache.values[root]; !cached.at.IsZero() && time.Since(cached.at) < 30*time.Second {
		return append([]OperationCapability(nil), cached.values...)
	}
	values := collect(ctx, root)
	if ctx.Err() != nil {
		return values
	}
	for _, value := range values {
		if value.retryable {
			return values
		}
	}
	operationCapabilityCache.values[root] = cachedOperationCapabilities{values: append([]OperationCapability(nil), values...), at: time.Now()}
	return values
}

func Capability(ctx context.Context, operation Operation) OperationCapability {
	for _, value := range OperationCapabilities(ctx) {
		if value.Operation == operation {
			return value
		}
	}
	return OperationCapability{Operation: operation, UnavailableReason: ErrOperationUnsupported.Error()}
}

func SupportsOperations() bool {
	for _, value := range OperationCapabilities(context.Background()) {
		if value.Supported && value.Authorized {
			return true
		}
	}
	return false
}

func ExecuteOperation(ctx context.Context, operation Operation) error {
	return ExecuteOperationAtRoot(ctx, defaultRoot(), operation)
}

func ExecuteOperationAtRoot(ctx context.Context, root string, operation Operation) error {
	if operation != OperationRestart && operation != OperationShutdown && operation != OperationUpdate {
		return errors.New("invalid machine operation")
	}
	return executeOperation(ctx, root, operation)
}

func defaultRoot() string {
	if value := strings.TrimSpace(os.Getenv("DIETER_HOME")); value != "" {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".dieter"
	}
	return filepath.Join(home, ".dieter")
}

// RunDaemonUpdateWorker is the detached half of the Homebrew update. Keeping
// it in the already-running Dieter executable lets the worker finish even when
// Homebrew replaces that executable before restarting the daemon service.
func RunDaemonUpdateWorker(args []string, output io.Writer) error {
	set := flag.NewFlagSet("daemon update worker", flag.ContinueOnError)
	set.SetOutput(output)
	brew := set.String("brew", "", "absolute Homebrew executable")
	root := set.String("root", "", "absolute DIETER_HOME directory")
	if err := set.Parse(args); err != nil {
		return err
	}
	if set.NArg() != 0 || !filepath.IsAbs(*brew) || filepath.Base(*brew) != "brew" {
		return errors.New("update worker requires an absolute --brew executable")
	}
	steps := []struct {
		name    string
		timeout time.Duration
		args    []string
		noAuto  bool
	}{
		{name: "refresh Homebrew metadata", timeout: 5 * time.Minute, args: []string{"update"}},
		{name: "upgrade Dieter", timeout: 10 * time.Minute, args: []string{"upgrade", "dbpprt/tap/dieter"}, noAuto: true},
		{name: "restart Dieter service", timeout: 2 * time.Minute, args: []string{"services", "restart", "dbpprt/tap/dieter"}, noAuto: true},
	}
	for _, step := range steps {
		if _, err := fmt.Fprintf(output, "%s: %s\n", time.Now().UTC().Format(time.RFC3339), step.name); err != nil {
			return err
		}
		stepCtx, cancel := context.WithTimeout(context.Background(), step.timeout)
		command := exec.CommandContext(stepCtx, *brew, step.args...)
		command.Stdin = nil
		command.Stdout = output
		command.Stderr = output
		command.Env = homebrewUpdateEnvironment(step.noAuto)
		err := command.Run()
		timedOut := errors.Is(stepCtx.Err(), context.DeadlineExceeded)
		cancel()
		if timedOut {
			return fmt.Errorf("%s timed out after %s", step.name, step.timeout)
		}
		if err != nil {
			return fmt.Errorf("%s: %w", step.name, err)
		}
		if step.name == "upgrade Dieter" && *root != "" {
			if err := prepareHomebrewHarnessRuntime(*root, *brew, output); err != nil {
				return err
			}
		}
	}
	_, err := fmt.Fprintf(output, "%s: update command completed\n", time.Now().UTC().Format(time.RFC3339))
	return err
}

func prepareHomebrewHarnessRuntime(root, brew string, output io.Writer) error {
	if !filepath.IsAbs(root) || filepath.Clean(root) != root {
		return errors.New("update worker requires an absolute --root directory")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	rawPrefix, err := exec.CommandContext(ctx, brew, "--prefix").Output()
	cancel()
	if err != nil {
		return fmt.Errorf("resolve Homebrew prefix: %w", err)
	}
	serviceRoot := filepath.Join(strings.TrimSpace(string(rawPrefix)), "var", "dieter", "service")
	candidate := filepath.Join(serviceRoot, "pending", "dieter")
	if info, statErr := os.Stat(candidate); statErr != nil || !info.Mode().IsRegular() {
		candidate = filepath.Join(serviceRoot, "bin", "dieter")
	}
	if info, err := os.Stat(candidate); err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return errors.New("staged Dieter candidate is unavailable")
	}
	if _, err := fmt.Fprintf(output, "%s: prepare candidate harness runtime\n", time.Now().UTC().Format(time.RFC3339)); err != nil {
		return err
	}
	return prepareCandidateHarnessRuntime(root, candidate, output)
}

var prepareCandidateHarnessRuntime = func(root, candidate string, output io.Writer) error {
	prepareCtx, prepareCancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer prepareCancel()
	command := exec.CommandContext(prepareCtx, candidate, "__harness-prepare", "--root", root)
	command.Stdin = nil
	command.Stdout = output
	command.Stderr = output
	command.Env = homebrewUpdateEnvironment(true)
	if err := command.Run(); err != nil {
		if errors.Is(prepareCtx.Err(), context.DeadlineExceeded) {
			return errors.New("prepare candidate harness runtime timed out after 10m")
		}
		return fmt.Errorf("prepare candidate harness runtime: %w", err)
	}
	return nil
}

func homebrewUpdateEnvironment(noAuto bool) []string {
	blocked := map[string]bool{
		"HOMEBREW_ASK": true, "HOMEBREW_NO_ASK": true, "HOMEBREW_NO_AUTO_UPDATE": true,
		"HOMEBREW_NO_ENV_HINTS": true, "NONINTERACTIVE": true,
	}
	environment := make([]string, 0, len(os.Environ())+4)
	for _, value := range os.Environ() {
		name, _, _ := strings.Cut(value, "=")
		if !blocked[name] {
			environment = append(environment, value)
		}
	}
	environment = append(environment, "HOMEBREW_NO_ASK=1", "HOMEBREW_NO_ENV_HINTS=1", "NONINTERACTIVE=1")
	if noAuto {
		environment = append(environment, "HOMEBREW_NO_AUTO_UPDATE=1")
	}
	return environment
}
