// Package claudedrv runs real Claude Code turns through the Claude Agent SDK
// (TypeScript) and records which paths Claude reports it changed: native file
// tool results (Write, Edit, MultiEdit, NotebookEdit) and the Bash tool's
// changed-file diff (bashEditDiff) as seen by a PostToolUse hook.
package claudedrv

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"dieter.spike/workspaces/core"
)

//go:embed driver.mjs
var driverScript []byte

// ScriptName is the file New writes into Config.NodeDir.
const ScriptName = "claudedrv.mjs"

// Config configures one Claude session.
type Config struct {
	Node            string        // node binary; default "node"
	NodeDir         string        // directory whose node_modules holds @anthropic-ai/claude-agent-sdk; the driver script is written here
	ConfigDir       string        // CLAUDE_CONFIG_DIR for this session (fresh per session)
	Model           string        // default "claude-sonnet-5-5"
	CredentialsFile string        // credentials JSON; "" = keychain on darwin, $HOME/.claude/.credentials.json elsewhere
	Launcher        core.Launcher // Dir = cwd; Wrap = argv prefix before `node driver`; Env = extra environment
	TurnTimeout     time.Duration // default 10m
	MaxTurns        int           // SDK maxTurns per turn; 0 = SDK default
}

type driver struct {
	cfg    Config
	script string
	roots  []string

	mu        sync.Mutex
	sessionID string
	closed    bool
}

// New prepares a session. No process runs until the first Turn.
func New(ctx context.Context, cfg Config) (core.Driver, error) {
	if cfg.Node == "" {
		cfg.Node = "node"
	}
	if cfg.Model == "" {
		cfg.Model = "claude-sonnet-5-5"
	}
	if cfg.TurnTimeout <= 0 {
		cfg.TurnTimeout = 10 * time.Minute
	}
	if cfg.NodeDir == "" || cfg.ConfigDir == "" || cfg.Launcher.Dir == "" {
		return nil, errors.New("claudedrv: NodeDir, ConfigDir and Launcher.Dir are required")
	}
	if fi, err := os.Stat(cfg.Launcher.Dir); err != nil || !fi.IsDir() {
		return nil, fmt.Errorf("claudedrv: launcher dir: %v", err)
	}
	if err := os.MkdirAll(cfg.ConfigDir, 0o700); err != nil {
		return nil, err
	}
	script := filepath.Join(cfg.NodeDir, ScriptName)
	if err := writeAtomic(script, driverScript); err != nil {
		return nil, err
	}
	return &driver{cfg: cfg, script: script, roots: rootsOf(cfg.Launcher.Dir)}, nil
}

func (d *driver) Name() string { return "claude" }

func (d *driver) Close() error {
	d.mu.Lock()
	d.closed = true
	d.mu.Unlock()
	return nil
}

type request struct {
	Prompt   string  `json:"prompt"`
	Cwd      string  `json:"cwd"`
	Model    string  `json:"model"`
	Resume   *string `json:"resume"`
	MaxTurns int     `json:"maxTurns,omitempty"`
}

// Turn runs one SDK query in the session, resuming the previous one.
func (d *driver) Turn(ctx context.Context, in core.TurnInput) (core.TurnResult, error) {
	start := time.Now()
	res := core.TurnResult{Reported: core.ChangeSet{}, Detail: map[string]any{}}
	fail := func(err error) (core.TurnResult, error) {
		res.Error = err.Error()
		res.Duration = time.Since(start)
		return res, err
	}

	d.mu.Lock()
	closed, resume := d.closed, d.sessionID
	d.mu.Unlock()
	if closed {
		return fail(errors.New("claudedrv: driver closed"))
	}
	prompt := in.Prompt
	if prompt == "" {
		prompt = core.RenderPrompt(in.Steps)
	}

	token, exp, refreshed, err := freshToken(ctx, d.cfg.CredentialsFile)
	if err != nil {
		return fail(err)
	}
	res.Detail["tokenRefreshedViaCLI"] = refreshed
	if !exp.IsZero() {
		res.Detail["tokenMinutesLeft"] = int(time.Until(exp).Minutes())
	}

	req := request{Prompt: prompt, Cwd: d.cfg.Launcher.Dir, Model: d.cfg.Model, MaxTurns: d.cfg.MaxTurns}
	if resume != "" {
		req.Resume = &resume
	}
	reqJSON, err := json.Marshal(req)
	if err != nil {
		return fail(err)
	}

	log := newEventLog(in.LogPath, token)
	defer log.Close()
	log.Write(map[string]any{"type": "dieter_turn_start", "time": start.UTC().Format(time.RFC3339Nano), "cwd": req.Cwd, "model": req.Model, "resume": req.Resume})

	acc := newAccumulator(d.roots)
	stdout := &lineWriter{fn: func(line []byte) {
		log.WriteRaw(line)
		acc.handle(line)
	}}
	stderr := &tailBuffer{max: 16 << 10}

	tctx, cancel := context.WithTimeout(ctx, d.cfg.TurnTimeout)
	defer cancel()
	argv := append(append([]string{}, d.cfg.Launcher.Wrap...), d.cfg.Node, d.script)
	cmd := exec.CommandContext(tctx, argv[0], argv[1:]...)
	cmd.Dir = d.cfg.Launcher.Dir
	cmd.Env = d.childEnv(token)
	cmd.Stdin = bytes.NewReader(reqJSON)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
	cmd.WaitDelay = 10 * time.Second

	runErr := cmd.Start()
	if runErr == nil {
		pgid := cmd.Process.Pid
		runErr = cmd.Wait()
		_ = syscall.Kill(-pgid, syscall.SIGKILL) // reap a CLI left behind by the driver
	}
	stdout.Flush()
	if s := stderr.String(); s != "" {
		log.Write(map[string]any{"type": "dieter_stderr", "tail": redact(s, token)})
	}
	acc.finish(&res)
	res.Duration = time.Since(start)
	log.Write(map[string]any{"type": "dieter_turn_end", "durationMs": res.Duration.Milliseconds(), "reported": res.Reported, "error": runErrString(runErr)})

	if acc.sessionID != "" {
		d.mu.Lock()
		d.sessionID = acc.sessionID
		d.mu.Unlock()
	}

	switch {
	case errors.Is(tctx.Err(), context.DeadlineExceeded):
		return fail(fmt.Errorf("claudedrv: turn timed out after %s", d.cfg.TurnTimeout))
	case ctx.Err() != nil:
		return fail(ctx.Err())
	case acc.driverError != "":
		return fail(fmt.Errorf("claudedrv: driver: %s", tail(redact(acc.driverError, token), 600)))
	case runErr != nil:
		return fail(fmt.Errorf("claudedrv: %v: %s", runErr, tail(redact(stderr.String(), token), 600)))
	case !acc.sawResult:
		return fail(fmt.Errorf("claudedrv: no result message: %s", tail(redact(stderr.String(), token), 600)))
	case acc.resultIsError:
		return fail(fmt.Errorf("claudedrv: result %s: %s", acc.resultSubtype, tail(redact(acc.resultText, token), 600)))
	}
	return res, nil
}

// childEnv is the scrubbed parent environment plus the session's
// configuration directory and the access token, then Launcher.Env.
func (d *driver) childEnv(token string) []string {
	env := scrubEnv(os.Environ())
	env = append(env,
		"CLAUDE_CONFIG_DIR="+d.cfg.ConfigDir,
		"CLAUDE_CODE_OAUTH_TOKEN="+token,
		"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1",
	)
	return append(env, d.cfg.Launcher.Env...)
}

func runErrString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func writeAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".claudedrv-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), path)
}
