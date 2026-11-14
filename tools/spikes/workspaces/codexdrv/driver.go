// Package codexdrv drives real OpenAI Codex turns through `codex app-server`
// (JSON-RPC over stdio) the way Dieter does, and records what Codex reports
// it changed: completed fileChange items, the turn-level unified diff, and
// the shell commands it ran.
package codexdrv

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"dieter.spike/workspaces/core"
)

// Config configures one Codex session (one app-server process, one thread).
type Config struct {
	CodexBin    string        // default: codex on $PATH
	CodexHome   string        // required; prepare with PrepareHome
	Model       string        // default: model key of ~/.codex/config.toml
	Effort      string        // default: DefaultEffort
	Launcher    core.Launcher // Dir = working dir; Wrap = argv prefix before the codex binary
	TurnTimeout time.Duration // default 10m
}

const (
	clientName      = "dieter-spike-codexdrv"
	maxBufferedLogs = 4096
	stderrTailLines = 20
)

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type rpcMessage struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *rpcError       `json:"error,omitempty"`
}

type driver struct {
	cfg     Config
	cmd     *exec.Cmd
	pgid    int
	secrets []string

	writeMu sync.Mutex
	stdin   io.WriteCloser
	closed  bool

	nextID atomic.Int64

	mu         sync.Mutex
	pending    map[int64]chan rpcMessage
	turn       *turnState
	stderrTail []string
	exitErr    error
	exited     chan struct{}

	logMu      sync.Mutex
	logFile    *os.File
	logDiscard bool
	logBuf     [][]byte
	logDropped int
	lastLog    string

	threadID  string
	threadCwd string
	rel       *relativizer

	turnMu    sync.Mutex
	closeOnce sync.Once
}

// New starts one `codex app-server`, initializes it and starts one thread
// whose cwd is Launcher.Dir. Each Turn is a new turn on that thread.
func New(ctx context.Context, cfg Config) (core.Driver, error) {
	if cfg.Launcher.Dir == "" {
		return nil, errors.New("codexdrv: Launcher.Dir is required")
	}
	if cfg.CodexHome == "" {
		return nil, errors.New("codexdrv: CodexHome is required (see PrepareHome)")
	}
	dir, err := filepath.Abs(cfg.Launcher.Dir)
	if err != nil {
		return nil, err
	}
	cfg.Launcher.Dir = dir
	if cfg.CodexBin == "" {
		p, err := exec.LookPath("codex")
		if err != nil {
			return nil, fmt.Errorf("codexdrv: %w", err)
		}
		cfg.CodexBin = p
	}
	if cfg.Model == "" {
		m, err := DefaultModel()
		if err != nil {
			return nil, fmt.Errorf("codexdrv: no Config.Model: %w", err)
		}
		cfg.Model = m
	}
	if cfg.Effort == "" {
		cfg.Effort = DefaultEffort
	}
	if cfg.TurnTimeout <= 0 {
		cfg.TurnTimeout = 10 * time.Minute
	}
	if err := writeConfig(cfg.CodexHome, cfg.Model, cfg.Effort); err != nil {
		return nil, fmt.Errorf("codexdrv: write config.toml: %w", err)
	}

	d := &driver{
		cfg:     cfg,
		pending: map[int64]chan rpcMessage{},
		exited:  make(chan struct{}),
		secrets: homeSecrets(cfg.CodexHome),
	}
	argv := append(append([]string{}, cfg.Launcher.Wrap...), cfg.CodexBin,
		"--config", `sandbox_mode="danger-full-access"`,
		"--config", `approval_policy="never"`,
		"app-server", "--stdio")
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = cfg.Launcher.Dir
	cmd.Env = childEnv(os.Environ(), cfg)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("codexdrv: start app-server: %w", err)
	}
	d.cmd, d.pgid, d.stdin = cmd, cmd.Process.Pid, stdin

	var readers sync.WaitGroup
	readers.Add(2)
	go func() { defer readers.Done(); d.readStdout(stdout) }()
	go func() { defer readers.Done(); d.readStderr(stderr) }()
	go func() {
		readers.Wait()
		werr := cmd.Wait()
		d.mu.Lock()
		if werr == nil {
			werr = errors.New("exit status 0")
		}
		d.exitErr = fmt.Errorf("codex app-server exited (%v); stderr tail: %s", werr, strings.Join(d.stderrTail, " | "))
		d.mu.Unlock()
		close(d.exited)
	}()

	initCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	if err := d.start(initCtx); err != nil {
		d.Close()
		return nil, err
	}
	return d, nil
}

func (d *driver) start(ctx context.Context) error {
	if _, err := d.request(ctx, "initialize", map[string]any{
		"clientInfo":   map[string]any{"name": clientName, "title": nil, "version": "1"},
		"capabilities": map[string]any{"experimentalApi": true},
	}); err != nil {
		return err
	}
	if err := d.send(map[string]any{"method": "initialized"}); err != nil {
		return err
	}
	raw, err := d.request(ctx, "thread/start", map[string]any{
		"model":          d.cfg.Model,
		"cwd":            d.cfg.Launcher.Dir,
		"approvalPolicy": "never",
		"sandbox":        "danger-full-access",
		// Dieter's codexConfig (fast mode off) plus its web_search default.
		"config": map[string]any{
			"service_tier": "default",
			"features":     map[string]any{"fast_mode": true},
			"web_search":   "disabled",
		},
		"dynamicTools":          []any{},
		"experimentalRawEvents": true,
	})
	if err != nil {
		return err
	}
	var res struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
		Cwd            string          `json:"cwd"`
		ApprovalPolicy json.RawMessage `json:"approvalPolicy"`
		Sandbox        struct {
			Type string `json:"type"`
		} `json:"sandbox"`
	}
	if err := json.Unmarshal(raw, &res); err != nil || res.Thread.ID == "" {
		return errors.New("codexdrv: thread/start returned no thread id")
	}
	if string(res.ApprovalPolicy) != `"never"` || res.Sandbox.Type != "dangerFullAccess" {
		return fmt.Errorf("codexdrv: thread/start did not disable approvals and the platform sandbox (approval=%s sandbox=%s)", res.ApprovalPolicy, res.Sandbox.Type)
	}
	d.threadID, d.threadCwd = res.Thread.ID, res.Cwd
	d.rel = newRelativizer(d.cfg.Launcher.Dir, res.Cwd)
	return nil
}

func (d *driver) Name() string { return "codex" }

// Turn runs one turn. Turn-level failures (failed/interrupted status,
// timeout) are reported in TurnResult.Error with a nil error; a dead or
// unreachable app-server also returns a non-nil error.
func (d *driver) Turn(ctx context.Context, in core.TurnInput) (core.TurnResult, error) {
	res := core.TurnResult{Reported: core.ChangeSet{}, Detail: map[string]any{}}
	if !d.turnMu.TryLock() {
		err := errors.New("codexdrv: a turn is already active")
		res.Error = err.Error()
		return res, err
	}
	defer d.turnMu.Unlock()
	started := time.Now()
	prompt := in.Prompt
	if prompt == "" {
		prompt = core.RenderPrompt(in.Steps)
	}
	if err := d.openLog(in.LogPath); err != nil {
		res.Error = err.Error()
		return res, err
	}
	defer d.closeLog()

	t := newTurnState(d.threadID)
	d.mu.Lock()
	d.turn = t
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		d.turn = nil
		d.mu.Unlock()
	}()

	tctx, cancel := context.WithTimeout(ctx, d.cfg.TurnTimeout)
	defer cancel()
	var runErr error
	raw, err := d.request(tctx, "turn/start", map[string]any{
		"threadId":       d.threadID,
		"input":          []any{map[string]any{"type": "text", "text": prompt, "text_elements": []any{}}},
		"approvalPolicy": "never",
		"sandboxPolicy":  map[string]any{"type": "externalSandbox", "networkAccess": "enabled"},
		"model":          d.cfg.Model,
		"effort":         d.cfg.Effort,
	})
	if err != nil {
		runErr = err
		res.Error = err.Error()
	} else {
		var tr struct {
			Turn struct {
				ID string `json:"id"`
			} `json:"turn"`
		}
		_ = json.Unmarshal(raw, &tr)
		t.setTurnID(tr.Turn.ID)
		select {
		case <-t.done:
		case <-d.exited:
			runErr = d.exitError()
			res.Error = runErr.Error()
		case <-tctx.Done():
			if ctx.Err() != nil {
				res.Error = "turn canceled: " + ctx.Err().Error()
			} else {
				res.Error = fmt.Sprintf("turn timed out after %s", d.cfg.TurnTimeout)
			}
			d.interrupt(t)
		}
	}
	t.fill(&res, d.rel)
	res.Duration = time.Since(started)
	return res, runErr
}

// interrupt asks Codex to stop the turn and waits briefly for turn/completed.
func (d *driver) interrupt(t *turnState) {
	ictx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if id := t.getTurnID(); id != "" {
		_, _ = d.request(ictx, "turn/interrupt", map[string]any{"threadId": d.threadID, "turnId": id})
	}
	select {
	case <-t.done:
	case <-d.exited:
	case <-ictx.Done():
	}
}

// Close ends the app-server: stdin EOF, then SIGTERM and SIGKILL to the
// whole process group, and sweeps any stragglers left in the group.
func (d *driver) Close() error {
	d.closeOnce.Do(func() {
		d.writeMu.Lock()
		d.closed = true
		_ = d.stdin.Close()
		d.writeMu.Unlock()
		if !waitClosed(d.exited, 3*time.Second) {
			_ = syscall.Kill(-d.pgid, syscall.SIGTERM)
			if !waitClosed(d.exited, 3*time.Second) {
				_ = syscall.Kill(-d.pgid, syscall.SIGKILL)
				waitClosed(d.exited, 3*time.Second)
			}
		}
		if syscall.Kill(-d.pgid, 0) == nil {
			_ = syscall.Kill(-d.pgid, syscall.SIGTERM)
			deadline := time.Now().Add(time.Second)
			for time.Now().Before(deadline) && syscall.Kill(-d.pgid, 0) == nil {
				time.Sleep(50 * time.Millisecond)
			}
			_ = syscall.Kill(-d.pgid, syscall.SIGKILL)
		}
		d.flushLog()
	})
	return nil
}

func waitClosed(ch <-chan struct{}, d time.Duration) bool {
	select {
	case <-ch:
		return true
	case <-time.After(d):
		return false
	}
}

func (d *driver) exitError() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.exitErr != nil {
		return errors.New(d.redact(d.exitErr.Error()))
	}
	return errors.New("codex app-server exited")
}

// --- JSON-RPC plumbing ---

func (d *driver) request(ctx context.Context, method string, params any) (json.RawMessage, error) {
	id := d.nextID.Add(1)
	ch := make(chan rpcMessage, 1)
	d.mu.Lock()
	d.pending[id] = ch
	d.mu.Unlock()
	forget := func() {
		d.mu.Lock()
		delete(d.pending, id)
		d.mu.Unlock()
	}
	msg := map[string]any{"id": id, "method": method}
	if params != nil {
		msg["params"] = params
	}
	if err := d.send(msg); err != nil {
		forget()
		return nil, err
	}
	select {
	case m := <-ch:
		if m.Error != nil {
			return nil, fmt.Errorf("codex %s failed: %s (code %d)", method, d.redact(m.Error.Message), m.Error.Code)
		}
		return m.Result, nil
	case <-ctx.Done():
		forget()
		return nil, fmt.Errorf("codex %s: %w", method, ctx.Err())
	case <-d.exited:
		forget()
		return nil, fmt.Errorf("codex %s: %w", method, d.exitError())
	}
}

func (d *driver) send(msg any) error {
	b, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	d.writeMu.Lock()
	defer d.writeMu.Unlock()
	if d.closed {
		return errors.New("codexdrv: driver closed")
	}
	d.log("send", b)
	if _, err := d.stdin.Write(append(b, '\n')); err != nil {
		return fmt.Errorf("codexdrv: write to app-server: %w", err)
	}
	return nil
}

func (d *driver) readStdout(r io.Reader) {
	br := bufio.NewReaderSize(r, 1<<20)
	for {
		line, err := br.ReadBytes('\n')
		if line = bytes.TrimSpace(line); len(line) > 0 {
			d.log("recv", line)
			d.dispatch(line)
		}
		if err != nil {
			return
		}
	}
}

func (d *driver) readStderr(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 4<<20)
	for sc.Scan() {
		line := d.redact(sc.Text())
		d.logText("stderr", line)
		d.mu.Lock()
		d.stderrTail = append(d.stderrTail, line)
		if len(d.stderrTail) > stderrTailLines {
			d.stderrTail = d.stderrTail[len(d.stderrTail)-stderrTailLines:]
		}
		d.mu.Unlock()
	}
	_, _ = io.Copy(io.Discard, r)
}

func (d *driver) dispatch(line []byte) {
	var m rpcMessage
	if json.Unmarshal(line, &m) != nil {
		return
	}
	hasID := len(m.ID) > 0 && string(m.ID) != "null"
	switch {
	case m.Method != "" && hasID:
		go d.answer(m)
	case m.Method != "":
		d.mu.Lock()
		t := d.turn
		d.mu.Unlock()
		if t != nil {
			t.handle(m.Method, m.Params, d.redact)
		}
	case hasID:
		var id int64
		if json.Unmarshal(m.ID, &id) != nil {
			return
		}
		d.mu.Lock()
		ch := d.pending[id]
		delete(d.pending, id)
		d.mu.Unlock()
		if ch != nil {
			ch <- m
		}
	}
}

// answer replies to a server-initiated request (approvals and friends).
func (d *driver) answer(m rpcMessage) {
	result, rerr := respondTo(m.Method, m.Params)
	d.mu.Lock()
	if t := d.turn; t != nil {
		t.mu.Lock()
		t.serverRequests = append(t.serverRequests, m.Method)
		t.mu.Unlock()
	}
	d.mu.Unlock()
	reply := map[string]any{"id": m.ID}
	if rerr != nil {
		reply["error"] = rerr
	} else {
		reply["result"] = result
	}
	_ = d.send(reply)
}

// respondTo auto-accepts every approval-style request. It never supplies
// credentials: token refresh and attestation requests are refused.
func respondTo(method string, params json.RawMessage) (any, *rpcError) {
	switch method {
	case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
		return map[string]any{"decision": "accept"}, nil
	case "applyPatchApproval", "execCommandApproval":
		return map[string]any{"decision": "approved"}, nil
	case "item/permissions/requestApproval":
		var p struct {
			Permissions struct {
				Network    json.RawMessage `json:"network"`
				FileSystem json.RawMessage `json:"fileSystem"`
			} `json:"permissions"`
		}
		_ = json.Unmarshal(params, &p)
		granted := map[string]any{}
		if len(p.Permissions.Network) > 0 && string(p.Permissions.Network) != "null" {
			granted["network"] = p.Permissions.Network
		}
		if len(p.Permissions.FileSystem) > 0 && string(p.Permissions.FileSystem) != "null" {
			granted["fileSystem"] = p.Permissions.FileSystem
		}
		return map[string]any{"permissions": granted, "scope": "session"}, nil
	case "item/tool/requestUserInput":
		return map[string]any{"answers": map[string]any{}}, nil
	case "mcpServer/elicitation/request":
		return map[string]any{"action": "decline", "content": nil, "_meta": nil}, nil
	case "currentTime/read":
		return map[string]any{"currentTimeAt": time.Now().Unix()}, nil
	case "account/chatgptAuthTokens/refresh":
		return nil, &rpcError{Code: -32603, Message: "the spike driver never supplies tokens"}
	default:
		return nil, &rpcError{Code: -32601, Message: "unsupported by the spike driver: " + method}
	}
}

// childEnv drops Dieter turn context and inherited Codex/OpenAI settings,
// then points CODEX_HOME at the spike home. Launcher.Env comes last.
func childEnv(base []string, cfg Config) []string {
	out := make([]string, 0, len(base)+len(cfg.Launcher.Env)+1)
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(k, "DIETER_") || strings.HasPrefix(k, "CODEX_") || k == "OPENAI_API_KEY" {
			continue
		}
		out = append(out, kv)
	}
	out = append(out, "CODEX_HOME="+cfg.CodexHome)
	return append(out, cfg.Launcher.Env...)
}

// --- raw message log ---

var jwtPattern = regexp.MustCompile(`eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`)

// redact removes the home's token strings and anything JWT-shaped.
func (d *driver) redact(s string) string {
	for _, sec := range d.secrets {
		s = strings.ReplaceAll(s, sec, "[REDACTED]")
	}
	return jwtPattern.ReplaceAllString(s, "[REDACTED-JWT]")
}

type logEntry struct {
	TS   string          `json:"ts"`
	Dir  string          `json:"dir"`
	Msg  json.RawMessage `json:"msg,omitempty"`
	Text string          `json:"text,omitempty"`
}

func (d *driver) log(dir string, payload []byte) {
	red := d.redact(string(payload))
	e := logEntry{TS: time.Now().UTC().Format(time.RFC3339Nano), Dir: dir}
	if json.Valid([]byte(red)) {
		e.Msg = json.RawMessage(red)
	} else {
		e.Text = red
	}
	d.appendLog(e)
}

func (d *driver) logText(dir, text string) {
	d.appendLog(logEntry{TS: time.Now().UTC().Format(time.RFC3339Nano), Dir: dir, Text: text})
}

func (d *driver) appendLog(e logEntry) {
	b, err := json.Marshal(e)
	if err != nil {
		return
	}
	b = append(b, '\n')
	d.logMu.Lock()
	defer d.logMu.Unlock()
	switch {
	case d.logFile != nil:
		_, _ = d.logFile.Write(b)
	case d.logDiscard:
	case len(d.logBuf) < maxBufferedLogs:
		d.logBuf = append(d.logBuf, b)
	default:
		d.logDropped++
	}
}

// openLog starts appending to path, first flushing messages buffered since
// the previous turn (or since startup).
func (d *driver) openLog(path string) error {
	d.logMu.Lock()
	defer d.logMu.Unlock()
	if path == "" {
		d.logDiscard, d.logBuf = true, nil
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	d.writeBuffered(f)
	d.logFile, d.lastLog = f, path
	return nil
}

func (d *driver) writeBuffered(f *os.File) {
	for _, b := range d.logBuf {
		_, _ = f.Write(b)
	}
	if d.logDropped > 0 {
		b, _ := json.Marshal(logEntry{TS: time.Now().UTC().Format(time.RFC3339Nano), Dir: "note", Text: fmt.Sprintf("%d buffered messages dropped", d.logDropped)})
		_, _ = f.Write(append(b, '\n'))
	}
	d.logBuf, d.logDropped = nil, 0
}

func (d *driver) closeLog() {
	d.logMu.Lock()
	defer d.logMu.Unlock()
	if d.logFile != nil {
		_ = d.logFile.Close()
	}
	d.logFile, d.logDiscard = nil, false
}

// flushLog appends anything buffered after the last turn to its log.
func (d *driver) flushLog() {
	d.logMu.Lock()
	defer d.logMu.Unlock()
	if d.lastLog == "" || len(d.logBuf) == 0 {
		return
	}
	f, err := os.OpenFile(d.lastLog, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	d.writeBuffered(f)
	_ = f.Close()
}
