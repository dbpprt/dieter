package harness

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

type Model struct {
	ID            string   `json:"id" yaml:"id"`
	Name          string   `json:"name" yaml:"name"`
	ContextWindow int      `json:"contextWindow,omitempty" yaml:"contextWindow,omitempty"`
	DefaultEffort string   `json:"defaultEffort,omitempty" yaml:"defaultEffort,omitempty"`
	Efforts       []string `json:"efforts,omitempty" yaml:"efforts,omitempty"`
	RuntimeModel  *string  `json:"-" yaml:"runtimeModel,omitempty"`
	Hidden        bool     `json:"-" yaml:"-"`
}

var ErrNoActiveTurn = fault.New(fault.FailedPrecondition, "card has no active turn")

type workerRecord struct {
	PID      int    `json:"pid"`
	OwnerPID int    `json:"ownerPid"`
	Token    string `json:"token"`
}

type providerBridgeRecord struct {
	PID int `json:"pid"`
}

func newWorkerToken() string {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(value)
}

func (model Model) RuntimeID() string {
	if model.RuntimeModel != nil {
		return *model.RuntimeModel
	}
	return model.ID
}

type EffortOption struct {
	ID   string `json:"id" yaml:"id"`
	Name string `json:"name" yaml:"name"`
}

type EffortConfig struct {
	Label   string         `json:"label" yaml:"label"`
	Options []EffortOption `json:"options" yaml:"options"`
}

type ProviderOptionChoice struct {
	Value string `json:"value" yaml:"value"`
	Name  string `json:"name" yaml:"name"`
}

// ProviderOption describes a harness-specific setting without coupling the
// API or UI to one provider. Values are serialized as strings so new option
// definitions do not require protobuf changes.
type ProviderOption struct {
	ID          string                 `json:"id" yaml:"id"`
	Name        string                 `json:"name" yaml:"name"`
	Description string                 `json:"description,omitempty" yaml:"description,omitempty"`
	Type        string                 `json:"type" yaml:"type"`
	Default     string                 `json:"defaultValue,omitempty" yaml:"default,omitempty"`
	Choices     []ProviderOptionChoice `json:"choices,omitempty" yaml:"choices,omitempty"`
	Mutable     bool                   `json:"mutable,omitempty" yaml:"mutable,omitempty"`
	Models      []string               `json:"models,omitempty" yaml:"models,omitempty"`
}

type Capability struct {
	ID    string `json:"id" yaml:"id"`
	Level string `json:"level" yaml:"level"`
}

type Request struct {
	Harness                    string            `json:"harness"`
	Adapter                    string            `json:"adapter"`
	Model                      string            `json:"model,omitempty"`
	ConfiguredModel            string            `json:"-"`
	ContextWindow              int               `json:"contextWindow,omitempty"`
	Effort                     string            `json:"effort,omitempty"`
	Options                    map[string]string `json:"options,omitempty"`
	Prompt                     string            `json:"prompt"`
	Attachments                []Attachment      `json:"attachments,omitempty"`
	Instructions               string            `json:"instructions,omitempty"`
	SessionID                  string            `json:"sessionId"`
	ResponseMessageID          string            `json:"responseMessageId"`
	Session                    json.RawMessage   `json:"session,omitempty"`
	ProjectPath                string            `json:"projectPath"`
	RuntimeRoot                string            `json:"runtimeRoot"`
	WebSearch                  bool              `json:"webSearch,omitempty"`
	Continue                   bool              `json:"continue,omitempty"`
	ContentPresentationEnabled bool              `json:"contentPresentationEnabled,omitempty"`
	BackgroundProcessesEnabled bool              `json:"backgroundProcessesEnabled,omitempty"`
	BackgroundProcess          ProcessHandler    `json:"-"`
	// PresentCommand and ProcessCommand are the Dieter CLI equivalents of the
	// presentation and background-process tools for this conversation, named
	// in their instructions for harnesses that load host tools on demand.
	PresentCommand string `json:"presentCommand,omitempty"`
	ProcessCommand string `json:"processCommand,omitempty"`
	// SteerEnabled keeps the worker's stdin open for steer frames: Steer
	// delivers agent channel messages into the running turn, and the worker
	// answers each with a steer-result Output.
	SteerEnabled bool             `json:"steerEnabled,omitempty"`
	Steer        <-chan SteerCall `json:"-"`
	// ChannelHookCommand is the shell command a harness runs as its pre-write
	// hook (agent channels file claims); empty disables the hook.
	ChannelHookCommand string `json:"channelHookCommand,omitempty"`
	// Environment is added to the worker after the allowlist, so commands the
	// agent runs inherit it. Values never enter the stdin request.
	Environment map[string]string `json:"-"`
	// RuntimeDigest pins only this active turn to an immutable installed
	// harness runtime. Completed conversations deliberately do not retain it:
	// their next turn resolves the then-current runtime and resumes the opaque
	// provider session with the newer adapter implementation.
	RuntimeDigest string `json:"-"`
}

// SteerCall asks a running worker to add Text to its active turn.
type SteerCall struct {
	ID   string
	Text string
}

// Steer-result reasons.
const (
	SteerNoRunningTurn = "no-running-turn"
	SteerUnsupported   = "unsupported"
	SteerError         = "error"
)

type Attachment struct {
	MediaType string `json:"mediaType"`
	Filename  string `json:"filename,omitempty"`
	URL       string `json:"url"`
}

type Output struct {
	Type         string          `json:"type"`
	Chunk        json.RawMessage `json:"chunk,omitempty"`
	State        json.RawMessage `json:"state,omitempty"`
	Capability   json.RawMessage `json:"capability,omitempty"`
	Presentation json.RawMessage `json:"presentation,omitempty"`
	Message      string          `json:"error,omitempty"`
	ProcessCall  *ProcessCall    `json:"processCall,omitempty"`
	// ID, Accepted and Reason answer a SteerCall (type steer-result).
	ID       string `json:"id,omitempty"`
	Accepted bool   `json:"accepted,omitempty"`
	Reason   string `json:"reason,omitempty"`
}

type Runner interface {
	Run(context.Context, Request, func(Output) error) error
}

type Canceller interface {
	Cancel(sessionID, runtimeRoot string) error
}

// Cleaner removes a provider bridge after its owning turn has reached a
// terminal state. Clean restart suspension deliberately skips this operation:
// the persisted continuation reconnects to that bridge in the next process.
type Cleaner interface {
	Cleanup(sessionID, runtimeRoot string) error
}

// Suspender parks a live turn without destroying its provider bridge. The
// worker emits a continuation state before exiting so another Dieter process
// can attach without replaying the prompt.
type Suspender interface {
	Suspend(sessionID, runtimeRoot string) error
}

// runtimeAssets is the harness runtime source. Node test files match the
// glob but are never staged or digested; see runtimeSourceFile.
//
//go:embed runtime/package.json runtime/package-lock.json runtime/*.mjs
var runtimeAssets embed.FS

type SubprocessRunner struct {
	root string
	env  Environment
	mu   sync.Mutex
	dirs map[string]string
}

// NewSubprocessRunner runs harness workers from runtimes installed under the
// DIETER_HOME root, with env as their host environment.
func NewSubprocessRunner(root string, env Environment) *SubprocessRunner {
	return &SubprocessRunner{root: filepath.Join(root, "runtime", "harness"), env: env, dirs: map[string]string{}}
}

const RuntimeProtocolVersion = "1"

// RuntimeReference identifies an immutable installed harness runtime. Digest
// affinity belongs to one active turn, never to the durable conversation.
type RuntimeReference struct {
	Digest          string
	ProtocolVersion string
	Directory       string
}

// RuntimeProvider is implemented by runners that can prepare the current
// runtime or reopen an older immutable runtime for restart continuation.
type RuntimeProvider interface {
	PrepareRuntime(context.Context, string) (RuntimeReference, error)
}

func stageRuntimeAssets(dir string) error {
	entries, err := runtimeAssets.ReadDir("runtime")
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || !runtimeSourceFile(entry.Name()) {
			continue
		}
		data, readErr := runtimeAssets.ReadFile("runtime/" + entry.Name())
		if readErr != nil {
			return readErr
		}
		if writeErr := os.WriteFile(filepath.Join(dir, entry.Name()), data, 0o600); writeErr != nil {
			return writeErr
		}
	}
	return nil
}

func embeddedRuntimeDigest() string {
	digest, err := runtimeSourceDigest(embeddedRuntimeSourceFiles(), func(name string) ([]byte, error) {
		return runtimeAssets.ReadFile("runtime/" + name)
	})
	if err != nil {
		panic("embedded harness runtime is incomplete: " + err.Error())
	}
	return digest
}

func (r *SubprocessRunner) ensure(ctx context.Context) (string, error) {
	reference, err := r.PrepareRuntime(ctx, "")
	if err != nil {
		return "", err
	}
	return reference.Directory, nil
}

// home is the DIETER_HOME directory the runner's runtimes live under.
func (r *SubprocessRunner) home() string { return filepath.Dir(filepath.Dir(r.root)) }

// PrepareRuntime installs the embedded runtime when digest is empty, or
// validates and reopens an already-published historical runtime when digest is
// supplied by a suspended active turn. Historical assets are never rewritten.
// Release builds install the prebuilt archive their binary pins (and the
// managed Bun it carries); source builds install with npm.
func (r *SubprocessRunner) PrepareRuntime(ctx context.Context, digest string) (RuntimeReference, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if override := strings.TrimSpace(r.env.RuntimeDir); override != "" {
		absolute, err := filepath.Abs(override)
		if err != nil {
			return RuntimeReference{}, err
		}
		if _, err := os.Stat(filepath.Join(absolute, "runner.mjs")); err != nil {
			return RuntimeReference{}, fmt.Errorf("DIETER_HARNESS_RUNTIME_DIR: %w", err)
		}
		const overrideDigest = "override"
		r.dirs[overrideDigest] = absolute
		return RuntimeReference{Digest: overrideDigest, ProtocolVersion: RuntimeProtocolVersion, Directory: absolute}, nil
	}
	version, err := exec.CommandContext(ctx, "node", "--version").Output()
	if err != nil {
		return RuntimeReference{}, errors.New("AI SDK harnesses require Node.js 22 or newer on PATH")
	}
	if !supportedNodeVersion(string(version)) {
		return RuntimeReference{}, fmt.Errorf("AI SDK harnesses require Node.js 22.19 or newer; found %s", strings.TrimSpace(string(version)))
	}
	currentDigest := embeddedRuntimeDigest()
	if digest == "" {
		digest = currentDigest
	}
	if dir := r.dirs[digest]; dir != "" {
		if err := validateRuntimeDirectory(dir, digest); err == nil {
			return RuntimeReference{Digest: digest, ProtocolVersion: RuntimeProtocolVersion, Directory: dir}, nil
		}
		delete(r.dirs, digest)
	}
	dir := filepath.Join(r.root, digest)
	if digest != currentDigest {
		if err := validateRuntimeDirectory(dir, digest); err != nil {
			return RuntimeReference{}, fmt.Errorf("validate pinned AI SDK harness runtime %s: %w", digest, err)
		}
		r.dirs[digest] = dir
		return RuntimeReference{Digest: digest, ProtocolVersion: RuntimeProtocolVersion, Directory: dir}, nil
	}
	populate := npmInstallRuntime
	if archive := r.env.runtimeArchive(); archive.pinned() {
		populate = func(ctx context.Context, stage string) error {
			return installRuntimeArchive(ctx, archive, stage, r.home())
		}
	}
	if err := installRuntimeAtomically(ctx, r.root, dir, digest, populate); err != nil {
		return RuntimeReference{}, err
	}
	r.dirs[digest] = dir
	return RuntimeReference{Digest: digest, ProtocolVersion: RuntimeProtocolVersion, Directory: dir}, nil
}

// RuntimeDirectory stages the pinned harness runtime for auxiliary read-only
// provider integrations such as quota discovery. Callers must still launch
// only checked-in runtime assets and keep provider credentials local.
func (r *SubprocessRunner) RuntimeDirectory(ctx context.Context) (string, error) {
	return r.ensure(ctx)
}

func (r *SubprocessRunner) Run(ctx context.Context, request Request, emit func(Output) error) error {
	reference, err := r.PrepareRuntime(ctx, request.RuntimeDigest)
	if err != nil {
		return err
	}
	dir := reference.Directory
	var runtimePaths []string
	if request.Adapter == "omp-acp" {
		bunBin, bunErr := ensureManagedBun(ctx, r.home(), r.env.runtimeArchive())
		if bunErr != nil {
			return fmt.Errorf("prepare OMP runtime: %w", bunErr)
		}
		runtimePaths = append(runtimePaths, bunBin)
	}
	workerToken := newWorkerToken()
	command := exec.CommandContext(ctx, "node", filepath.Join(dir, "runner.mjs"), "--board-worker-token="+workerToken)
	prepareHarnessCommand(command)
	// A suspended turn may need a few seconds to flush its provider continuation
	// state after SIGINT. Keep this below the service manager's shutdown budget,
	// but do not kill the worker before that state reaches Board.
	// runner.mjs gives a misbehaving adapter eight seconds to unwind its stream
	// and stop locally owned provider processes. Keep exec's hard-kill guard
	// just beyond that window and below Service.CancelCard's timeout.
	command.WaitDelay = 9 * time.Second
	command.Dir = dir
	if request.Adapter == "omp-acp" {
		command.Env = r.env.ompHarnessEnvironment(runtimePaths...)
	} else {
		command.Env = r.env.harnessEnvironment()
	}
	for name, value := range request.Environment {
		command.Env = append(command.Env, name+"="+value)
	}
	stdin, err := command.StdinPipe()
	if err != nil {
		return err
	}
	defer stdin.Close()
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		return err
	}
	waited := false
	defer func() {
		if waited {
			return
		}
		// Every successfully started child must be waited on, including decode,
		// emit, and setup failures. Signal the worker first so its SDK session
		// can close the provider bridge, then retain SIGKILL as a final guard.
		_ = interruptHarnessProcess(command.Process.Pid)
		done := make(chan struct{})
		go func() {
			_ = command.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(9 * time.Second):
			_ = killHarnessProcess(command.Process.Pid)
			<-done
		}
	}()
	workerFile := filepath.Join(request.RuntimeRoot, ".dieter-worker-"+request.SessionID+".pid")
	if err := os.MkdirAll(request.RuntimeRoot, 0o700); err != nil {
		_ = command.Process.Kill()
		return err
	}
	record, _ := json.Marshal(workerRecord{PID: command.Process.Pid, OwnerPID: os.Getpid(), Token: workerToken})
	if err := os.WriteFile(workerFile, append(record, '\n'), 0o600); err != nil {
		_ = command.Process.Kill()
		return err
	}
	defer os.Remove(workerFile)
	encoded, _ := json.Marshal(request)
	if _, err := stdin.Write(append(encoded, '\n')); err != nil {
		_ = stdin.Close()
		_ = command.Process.Kill()
		waitErr := command.Wait()
		waited = true
		message := strings.TrimSpace(stderr.String())
		if message == "" && waitErr != nil {
			message = waitErr.Error()
		}
		if message == "" {
			message = err.Error()
		}
		return fmt.Errorf("start harness worker: %s", message)
	}
	// Host replies and steer frames share the worker's stdin; one line per write.
	host := &lockedWriter{writer: stdin}
	if !request.BackgroundProcessesEnabled && !request.SteerEnabled {
		_ = stdin.Close()
	}
	steering := make(chan struct{})
	defer close(steering)
	if request.SteerEnabled && request.Steer != nil {
		go func() {
			for {
				select {
				case call, ok := <-request.Steer:
					if !ok {
						return
					}
					line, _ := json.Marshal(struct {
						Type string `json:"type"`
						ID   string `json:"id"`
						Text string `json:"text"`
					}{"steer", call.ID, call.Text})
					_, _ = host.Write(append(line, '\n'))
				case <-steering:
					return
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 8<<20)
	var workerError string
	var streamError string
	var stdoutDiagnostics strings.Builder
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var output Output
		if err := json.Unmarshal(line, &output); err != nil {
			// Harness bootstrap commands may write package-manager progress to
			// their inherited stdout before the bridge starts. NDJSON frames
			// always begin with an object; preserve other lines as diagnostics.
			if line[0] != '{' {
				stdoutDiagnostics.Write(line)
				stdoutDiagnostics.WriteByte('\n')
				continue
			}
			_ = command.Process.Kill()
			return fmt.Errorf("decode harness worker output: %w", err)
		}
		if output.Type == "error" {
			workerError = output.Message
		}
		if output.Type == "background-process" {
			if err := replyProcessCall(ctx, host, request.BackgroundProcess, output.ProcessCall); err != nil {
				return err
			}
			continue
		}
		if output.Type == "chunk" {
			var chunk struct {
				Type      string `json:"type"`
				ErrorText string `json:"errorText"`
			}
			if json.Unmarshal(output.Chunk, &chunk) == nil && chunk.Type == "error" {
				streamError = strings.TrimSpace(chunk.ErrorText)
				// The AI SDK emits a generic UI error while the actionable ACP
				// diagnostic is written to stderr. Hold the generic chunk until the
				// process exits so the caller can persist the complete failure once.
				continue
			}
		}
		if err := emit(output); err != nil {
			_ = command.Process.Kill()
			return err
		}
	}
	scanErr := scanner.Err()
	waitErr := command.Wait()
	waited = true
	if scanErr != nil {
		return scanErr
	}
	diagnostic := workerDiagnostics(stderr.String() + "\n" + stdoutDiagnostics.String())
	for _, failure := range []string{workerError, streamError} {
		if failure == "" {
			continue
		}
		if diagnostic != "" {
			// Clients summarize a failure by its first line and keep the rest as
			// the log, so the harness's own error must stand alone on that line.
			return fmt.Errorf("%s\n\n%s", failure, diagnostic)
		}
		return errors.New(failure)
	}
	if waitErr != nil {
		message := diagnostic
		if message == "" {
			message = waitErr.Error()
		}
		return fmt.Errorf("harness worker: %s", message)
	}
	return nil
}

// benignWorkerDiagnostics are expected on every run of the unsandboxed local
// provider and never explain a failure: the harness warns that it forwards
// credentials because the host has no request-transformation sandbox.
var benignWorkerDiagnostics = []string{
	"The sandbox implementation does not support configuring request transformations",
}

func workerDiagnostics(output string) string {
	lines := strings.Split(output, "\n")
	kept := lines[:0]
	for _, line := range lines {
		if slices.ContainsFunc(benignWorkerDiagnostics, func(notice string) bool { return strings.Contains(line, notice) }) {
			continue
		}
		kept = append(kept, line)
	}
	return strings.TrimSpace(strings.Join(kept, "\n"))
}

func (r *SubprocessRunner) Cancel(sessionID, runtimeRoot string) error {
	if strings.ContainsAny(sessionID, `/\\`) {
		return errors.New("invalid harness session ID")
	}
	path := filepath.Join(runtimeRoot, ".dieter-worker-"+sessionID+".pid")
	stopped := false
	raw, err := os.ReadFile(path)
	switch {
	case err == nil:
		var record workerRecord
		if json.Unmarshal(raw, &record) != nil {
			// Pre-token worker files cannot be verified safely after PID reuse.
			_ = os.Remove(path)
		} else if record.PID <= 0 || record.Token == "" {
			return errors.New("active harness worker has an invalid PID")
		} else if !workerProcessMatches(record.PID, record.Token) {
			_ = os.Remove(path)
		} else {
			stopped = true
			if err := interruptHarnessProcess(record.PID); err != nil && !errors.Is(err, os.ErrProcessDone) {
				return err
			}
			deadline := time.Now().Add(9 * time.Second)
			for workerProcessMatches(record.PID, record.Token) && time.Now().Before(deadline) {
				time.Sleep(50 * time.Millisecond)
			}
			if workerProcessMatches(record.PID, record.Token) {
				if err := killHarnessProcess(record.PID); err != nil && !errors.Is(err, os.ErrProcessDone) {
					return err
				}
			}
			_ = os.Remove(path)
		}
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return err
	}
	cleaned, cleanupErr := r.cleanupProviderBridge(sessionID, runtimeRoot)
	if cleanupErr != nil {
		return cleanupErr
	}
	if !stopped && !cleaned {
		return ErrNoActiveTurn
	}
	return nil
}

func (r *SubprocessRunner) Cleanup(sessionID, runtimeRoot string) error {
	if strings.ContainsAny(sessionID, `/\\`) {
		return errors.New("invalid harness session ID")
	}
	_, err := r.cleanupProviderBridge(sessionID, runtimeRoot)
	return err
}

func (r *SubprocessRunner) cleanupProviderBridge(sessionID, runtimeRoot string) (bool, error) {
	stateDirs, err := ProviderBridgeStateDirs(sessionID, runtimeRoot)
	if err != nil {
		return false, err
	}
	cleaned := false
	var cleanupErrors []error
	for _, stateDir := range stateDirs {
		found, cleanupErr := cleanupProviderBridgeStateDir(stateDir)
		cleaned = cleaned || found
		if cleanupErr != nil {
			cleanupErrors = append(cleanupErrors, fmt.Errorf("clean provider bridge %s: %w", stateDir, cleanupErr))
		}
	}
	return cleaned, errors.Join(cleanupErrors...)
}

// ProviderBridgeStateDirs returns every supported bridge-state location for a
// Dieter conversation. Current adapters share the sandbox-home harness state;
// older adapters used the ACP-specific home or per-project runtime root.
func ProviderBridgeStateDirs(sessionID, runtimeRoot string) ([]string, error) {
	if strings.ContainsAny(sessionID, `/\\`) {
		return nil, errors.New("invalid harness session ID")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve provider bridge home: %w", err)
	}
	digest := sha256.Sum256([]byte(sessionID))
	key := hex.EncodeToString(digest[:])
	return []string{
		filepath.Join(runtimeRoot, ".agent-runs", sessionID, "bridge"),
		filepath.Join(home, ".ai-sdk", "harness-acp", "omp", key, "bridge"),
		filepath.Join(home, ".ai-sdk", "harness-acp", "dsh", key, "bridge"),
		filepath.Join(home, ".ai-sdk-harness", ".agent-runs", sessionID, "bridge"),
	}, nil
}

func cleanupProviderBridgeStateDir(stateDir string) (bool, error) {
	path := filepath.Join(stateDir, "bridge-meta.json")
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var record providerBridgeRecord
	if json.Unmarshal(raw, &record) != nil || record.PID <= 0 {
		// An unverifiable record must never authorize signaling a PID.
		_ = os.Remove(path)
		return false, nil
	}
	if !providerBridgeProcessMatches(record.PID, stateDir) {
		_ = os.Remove(path)
		return false, nil
	}
	if err := terminateProviderBridgeProcess(record.PID); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return false, err
	}
	deadline := time.Now().Add(2 * time.Second)
	for providerBridgeProcessMatches(record.PID, stateDir) && time.Now().Before(deadline) {
		time.Sleep(25 * time.Millisecond)
	}
	if providerBridgeProcessMatches(record.PID, stateDir) {
		if err := killHarnessProcess(record.PID); err != nil && !errors.Is(err, os.ErrProcessDone) {
			return false, err
		}
	}
	_ = os.Remove(path)
	return true, nil
}

func (r *SubprocessRunner) Suspend(sessionID, runtimeRoot string) error {
	if strings.ContainsAny(sessionID, `/\\`) {
		return errors.New("invalid harness session ID")
	}
	path := filepath.Join(runtimeRoot, ".dieter-worker-"+sessionID+".pid")
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ErrNoActiveTurn
	}
	if err != nil {
		return err
	}
	var record workerRecord
	if json.Unmarshal(raw, &record) != nil || record.PID <= 0 || record.Token == "" {
		return errors.New("active harness worker has an invalid record")
	}
	if !workerProcessMatches(record.PID, record.Token) {
		_ = os.Remove(path)
		return ErrNoActiveTurn
	}
	if err := suspendHarnessProcess(record.PID); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	deadline := time.Now().Add(4 * time.Second)
	for workerProcessMatches(record.PID, record.Token) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if workerProcessMatches(record.PID, record.Token) {
		return errors.New("timed out waiting for the harness worker to suspend")
	}
	return nil
}

func (e Environment) harnessEnvironment(runtimePaths ...string) []string {
	allowed := map[string]bool{
		"PATH": true, "HOME": true, "USER": true, "LOGNAME": true, "TMPDIR": true, "SHELL": true, "LANG": true, "TERM": true,
		"DIETER_HARNESS_ENV": true,
		"OPENAI_API_KEY":     true, "CODEX_API_KEY": true, "OPENAI_BASE_URL": true, "CODEX_HOME": true,
		"AI_GATEWAY_API_KEY": true, "AI_GATEWAY_BASE_URL": true, "VERCEL_OIDC_TOKEN": true,
		"ANTHROPIC_API_KEY": true, "ANTHROPIC_AUTH_TOKEN": true, "ANTHROPIC_BASE_URL": true, "CLAUDE_CODE_OAUTH_TOKEN": true, "CLAUDE_CONFIG_DIR": true,
		"PI_AGENT_DIR": true, "PI_CODING_AGENT_DIR": true, "OMP_PROFILE": true,
		"DSH_HOME": true, "DEEPSEEK_API_KEY": true, "DEEPSEEK_BASE_URL": true, "DEEPSEEK_SEARCH_BASE_URL": true,
		"DSH_PERMISSION_MODE": true, "DSH_TOOLS_MODE": true, "DSH_TELEMETRY_MODE": true, "DSH_TELEMETRY_DISABLED": true, "DSH_TELEMETRY_OTLP_URL": true,
		"NODE_EXTRA_CA_CERTS": true, "NODE_USE_ENV_PROXY": true, "HTTP_PROXY": true, "HTTPS_PROXY": true, "NO_PROXY": true,
	}
	for _, name := range e.PassThrough {
		if name = strings.TrimSpace(name); name != "" && !strings.Contains(name, "=") {
			allowed[name] = true
		}
	}
	result := make([]string, 0, len(allowed))
	home := e.Value("HOME")
	for _, item := range e.environ() {
		name, _, _ := strings.Cut(item, "=")
		if allowed[name] {
			if name == "PATH" {
				item = "PATH=" + harnessPath(strings.TrimPrefix(item, "PATH="), home, runtimePaths...)
			}
			result = append(result, item)
		}
	}
	return result
}

func supportedNodeVersion(raw string) bool {
	parts := strings.Split(strings.TrimPrefix(strings.TrimSpace(raw), "v"), ".")
	if len(parts) < 2 {
		return false
	}
	major, majorErr := strconv.Atoi(parts[0])
	minor, minorErr := strconv.Atoi(parts[1])
	if majorErr != nil || minorErr != nil {
		return false
	}
	return major > 22 || major == 22 && minor >= 19
}

func harnessPath(current, home string, runtimePaths ...string) string {
	paths := filepath.SplitList(current)
	seen := make(map[string]bool, len(paths)+2+len(runtimePaths))
	for _, path := range paths {
		seen[path] = true
	}
	for _, path := range []string{filepath.Join(home, ".bun", "bin"), filepath.Join(home, ".local", "bin")} {
		if home == "" || seen[path] {
			continue
		}
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			paths = append([]string{path}, paths...)
			seen[path] = true
		}
	}
	for index := len(runtimePaths) - 1; index >= 0; index-- {
		path := strings.TrimSpace(runtimePaths[index])
		if path == "" || seen[path] {
			continue
		}
		paths = append([]string{path}, paths...)
		seen[path] = true
	}
	return strings.Join(paths, string(os.PathListSeparator))
}

// runtimeSourceFile reports whether an embedded runtime file belongs to the
// installed runtime. Node tests ship in the same directory but are excluded.
func runtimeSourceFile(name string) bool { return !strings.HasSuffix(name, ".test.mjs") }

// lockedWriter serializes whole-line writes of concurrent stdin writers.
type lockedWriter struct {
	mu     sync.Mutex
	writer io.Writer
}

func (w *lockedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.writer.Write(p)
}
