package accounts

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/harness/agentexec"
	"github.com/dbpprt/dieter/internal/platform/fault"
)

// manualURL is the URL `claude auth login` prints for the manual (paste
// code) flow: "If the browser didn't open, visit: https://…".
var manualURL = regexp.MustCompile(`visit: (https://\S+)`)

// redactOAuth hides OAuth parameters in tool output before it reaches a
// message.
var redactOAuth = regexp.MustCompile(`(code|state|code_challenge)=[^&\s]+`)

const (
	claudeURLWait  = 30 * time.Second
	claudeHookWait = 3 * time.Second
)

// claudeLogin drives `claude auth login --claudeai` over plain pipes (proposal
// S1, P0.1, P0.7): its $BROWSER hook reports the localhost-redirect URL, its
// stdout the manual URL, and the pasted code goes to its stdin verbatim.
type claudeLogin struct {
	backend   *execBackend
	request   ClaudeLoginRequest
	command   *exec.Cmd
	stdin     io.WriteCloser
	output    *watchedOutput
	exited    chan struct{}
	updates   chan LoginUpdate
	cancel    context.CancelFunc
	mu        sync.Mutex
	challenge Challenge
	submitted bool
}

func (b *execBackend) ClaudeLogin(ctx context.Context, request ClaudeLoginRequest) (LoginDriver, error) {
	claude, err := b.claudePath(ctx)
	if err != nil {
		return nil, err
	}
	hook := filepath.Join(request.SessionDir, "browser-hook.sh")
	urlFile := filepath.Join(request.SessionDir, "browser-url")
	script := "#!/bin/sh\nprintf '%s\\n' \"$1\" > " + shellQuote(urlFile+".tmp") + " && mv -f " + shellQuote(urlFile+".tmp") + " " + shellQuote(urlFile) + "\n"
	if err := os.WriteFile(hook, []byte(script), 0o700); err != nil {
		return nil, err
	}
	args := []string{"auth", "login", "--claudeai"}
	if request.Email != "" {
		args = append(args, "--email", request.Email)
	}
	command := exec.Command(claude, args...)
	agentexec.PrepareCommand(command, false)
	command.Dir = request.SessionDir
	command.Env = append(b.claudeEnv(request.ConfigDir), "BROWSER="+hook)
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	output := newWatchedOutput(manualURL)
	command.Stdout, command.Stderr = output, output
	if err := command.Start(); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	login := &claudeLogin{
		backend: b, request: request, command: command, stdin: stdin, output: output,
		exited: make(chan struct{}), updates: make(chan LoginUpdate, 8), cancel: cancel,
	}
	go func() {
		_ = command.Wait()
		close(login.exited)
	}()
	go login.run(ctx, urlFile)
	return login, nil
}

func (l *claudeLogin) Updates() <-chan LoginUpdate { return l.updates }

func (l *claudeLogin) Cancel() { l.cancel() }

// send delivers an update unless the login was canceled.
func (l *claudeLogin) send(ctx context.Context, update LoginUpdate) {
	select {
	case l.updates <- update:
	case <-ctx.Done():
	}
}

func (l *claudeLogin) run(ctx context.Context, urlFile string) {
	defer close(l.updates)
	defer agentexec.Terminate(l.command, l.exited, 2*time.Second)
	wait := time.NewTimer(claudeURLWait)
	defer wait.Stop()
	var manual string
	select {
	case manual = <-l.output.found:
	case <-l.exited:
		l.send(ctx, LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: "Claude Code stopped before showing a sign-in link: " + l.output.lastLine()})
		return
	case <-wait.C:
		l.send(ctx, LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: "Claude Code did not show a sign-in link"})
		return
	case <-ctx.Done():
		return
	}
	// The hook runs as Claude Code opens the browser, just before it prints
	// the manual URL; give it a moment.
	var local string
	for deadline := time.Now().Add(claudeHookWait); local == "" && time.Now().Before(deadline); {
		if raw, err := os.ReadFile(urlFile); err == nil {
			local = strings.TrimSpace(string(raw))
			break
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(50 * time.Millisecond):
		}
	}
	challenge := Challenge{OpenURL: manual, LocalURL: local, CallbackPort: redirectPort(local, 0), Expects: ExpectsCode}
	l.mu.Lock()
	l.challenge = challenge
	l.mu.Unlock()
	l.send(ctx, LoginUpdate{Phase: PhaseWaiting, Challenge: challenge})
	select {
	case <-l.exited:
	case <-ctx.Done():
		return
	}
	if l.command.ProcessState == nil || !l.command.ProcessState.Success() {
		l.send(ctx, LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: "Claude Code could not sign in: " + l.output.lastLine()})
		return
	}
	statusCtx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	status, err := l.backend.CheckClaude(statusCtx, l.request.ConfigDir)
	switch {
	case err != nil:
		l.send(ctx, LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: err.Error()})
	case !status.Subscription():
		l.send(ctx, LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: "Claude Code finished without a claude.ai sign-in"})
	default:
		l.send(ctx, LoginUpdate{Phase: PhaseSucceeded, Identity: status.Identity})
	}
}

// Submit writes a pasted code (code#state) to Claude Code's prompt, or replays
// the browser's localhost redirect to its listener.
func (l *claudeLogin) Submit(ctx context.Context, code, callbackURL string) error {
	l.mu.Lock()
	challenge, submitted := l.challenge, l.submitted
	l.mu.Unlock()
	if challenge.OpenURL == "" {
		return fault.New(fault.FailedPrecondition, "the sign-in is not ready yet")
	}
	if callbackURL != "" {
		if challenge.CallbackPort == 0 {
			return fault.New(fault.FailedPrecondition, "this sign-in has no local callback; paste the code instead")
		}
		address, err := parseCallback(callbackURL, challenge.CallbackPort, "/callback")
		if err != nil {
			return err
		}
		return replayCallback(ctx, address, challenge.CallbackPort)
	}
	if submitted {
		return fault.New(fault.FailedPrecondition, "a code was already submitted; start a new sign-in to try again")
	}
	if _, err := io.WriteString(l.stdin, code+"\n"); err != nil {
		return fault.Errorf(fault.FailedPrecondition, "Claude Code is no longer waiting for a code")
	}
	l.mu.Lock()
	l.submitted = true
	l.mu.Unlock()
	return nil
}

// watchedOutput collects a process's combined output (bounded) and reports
// the first match of a pattern.
type watchedOutput struct {
	mu      sync.Mutex
	pattern *regexp.Regexp
	buffer  []byte
	found   chan string
	matched bool
}

func newWatchedOutput(pattern *regexp.Regexp) *watchedOutput {
	return &watchedOutput{pattern: pattern, found: make(chan string, 1)}
}

func (w *watchedOutput) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buffer = append(w.buffer, p...)
	if len(w.buffer) > 64<<10 {
		w.buffer = append([]byte(nil), w.buffer[len(w.buffer)-(32<<10):]...)
	}
	if !w.matched {
		if match := w.pattern.FindSubmatch(w.buffer); match != nil {
			w.matched = true
			w.found <- string(match[1])
		}
	}
	return len(p), nil
}

// lastLine is the last non-empty output line with OAuth parameters redacted.
func (w *watchedOutput) lastLine() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	lines := strings.Split(strings.TrimSpace(string(w.buffer)), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if line := strings.TrimSpace(lines[i]); line != "" {
			return singleLine(redactOAuth.ReplaceAllString(line, "$1=…"), 300)
		}
	}
	return "no output"
}

func shellQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", `'"'"'`) + "'" }
