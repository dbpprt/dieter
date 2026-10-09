package claudedesign

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// CommandFactory prepares the runtime's claude-design-host.mjs helper for one
// operation: status, sign-in, consent or revoke.
type CommandFactory func(ctx context.Context, operation string) (*exec.Cmd, error)

const (
	maxHelperOutput = 64 << 10
	maxEventLine    = 16 << 10
	maxEvents       = 32
	statusTimeout   = 45 * time.Second
	grantTimeout    = 2 * time.Minute
)

type processHost struct{ command CommandFactory }

// NewProcessHost runs Claude Design operations through the pinned runtime.
func NewProcessHost(command CommandFactory) Host { return processHost{command: command} }

func (h processHost) Status(ctx context.Context) (Status, error) {
	ctx, cancel := context.WithTimeout(ctx, statusTimeout)
	defer cancel()
	var value Status
	if _, err := h.runJSON(ctx, "status", &value); err != nil {
		return Status{}, err
	}
	return value, nil
}

func (h processHost) SetGrant(ctx context.Context, granted bool) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, grantTimeout)
	defer cancel()
	operation := "revoke"
	if granted {
		operation = "consent"
	}
	var outcome struct {
		OK      bool   `json:"ok"`
		Message string `json:"message"`
	}
	parsed, err := h.runJSON(ctx, operation, &outcome)
	if parsed && !outcome.OK {
		message := strings.TrimSpace(outcome.Message)
		if message == "" {
			message = "Claude Code did not confirm the Claude Design access change."
		}
		return "", FailedPrecondition{Message: message}
	}
	if err != nil {
		return "", err
	}
	return outcome.Message, nil
}

// runJSON runs one helper operation and decodes its single JSON result. parsed
// reports whether a result was decoded even when the helper exited non-zero.
func (h processHost) runJSON(ctx context.Context, operation string, value any) (bool, error) {
	command, err := h.command(ctx, operation)
	if err != nil {
		return false, err
	}
	output := &cappedBuffer{limit: maxHelperOutput}
	diagnostics := &tailBuffer{limit: 2048}
	command.Stdout, command.Stderr = output, diagnostics
	runErr := command.Run()
	if output.exceeded {
		return false, fmt.Errorf("Claude Design %s output exceeded %d KiB", operation, maxHelperOutput>>10)
	}
	if line := lastLine(output.Bytes()); len(line) > 0 && json.Unmarshal(line, value) == nil {
		return true, runErr
	}
	if ctx.Err() != nil {
		return false, fmt.Errorf("Claude Design %s timed out", operation)
	}
	if runErr != nil {
		return false, fmt.Errorf("Claude Design %s failed: %s", operation, diagnostics.summary(runErr))
	}
	return false, fmt.Errorf("Claude Design %s returned no result", operation)
}

func (h processHost) SignIn(ctx context.Context, codes <-chan string, event func(Event) error) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	command, err := h.command(ctx, "sign-in")
	if err != nil {
		return err
	}
	stdin, err := command.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	diagnostics := &tailBuffer{limit: 2048}
	command.Stderr = diagnostics
	if err := command.Start(); err != nil {
		return err
	}
	finished := make(chan struct{})
	var writer sync.WaitGroup
	writer.Add(1)
	go func() {
		defer writer.Done()
		// Closing stdin aborts Claude Code's sign-in, so keep it open until
		// the stream ends or the sign-in is canceled.
		defer stdin.Close()
		for {
			select {
			case code := <-codes:
				line, _ := json.Marshal(map[string]string{"code": code})
				if _, err := stdin.Write(append(line, '\n')); err != nil {
					return
				}
			case <-ctx.Done():
				return
			case <-finished:
				return
			}
		}
	}()
	var eventErr error
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 4096), maxEventLine)
	for count := 0; scanner.Scan(); count++ {
		if count >= maxEvents {
			eventErr = errors.New("Claude Design sign-in produced too many events")
			cancel()
			break
		}
		next, ok := parseEvent(scanner.Bytes())
		if !ok {
			continue
		}
		if err := event(next); err != nil {
			eventErr = err
			cancel()
			break
		}
	}
	if err := scanner.Err(); err != nil && eventErr == nil {
		eventErr = err
		cancel()
	}
	close(finished)
	_, _ = io.Copy(io.Discard, stdout)
	writer.Wait()
	waitErr := command.Wait()
	if eventErr != nil {
		return eventErr
	}
	if waitErr != nil && ctx.Err() == nil {
		var exit *exec.ExitError
		// The helper exits 1 after reporting a failed sign-in as a done event.
		if errors.As(waitErr, &exit) && exit.ExitCode() == 1 {
			return nil
		}
		return fmt.Errorf("%s", diagnostics.summary(waitErr))
	}
	return nil
}

func parseEvent(line []byte) (Event, bool) {
	var raw struct {
		Event       string `json:"event"`
		URL         string `json:"url"`
		ManualURL   string `json:"manual_url"`
		ManualFirst bool   `json:"manual_first"`
		OK          bool   `json:"ok"`
		Message     string `json:"message"`
	}
	if json.Unmarshal(bytes.TrimSpace(line), &raw) != nil {
		return Event{}, false
	}
	switch raw.Event {
	case "preparing":
		return Event{Kind: "preparing", Message: "Installing Claude Code on this machine…"}, true
	case "pages":
		authorize, manual := secureURL(raw.URL), secureURL(raw.ManualURL)
		if authorize == "" && manual == "" {
			return Event{}, false
		}
		return Event{Kind: "pages", URL: authorize, ManualURL: manual, ManualFirst: raw.ManualFirst}, true
	case "done":
		message := strings.TrimSpace(raw.Message)
		if raw.OK && message == "" {
			message = "Signed in to Claude Design."
		}
		return Event{Kind: "done", OK: raw.OK, Message: message}, true
	default:
		return Event{}, false
	}
}

// secureURL accepts only an absolute HTTPS authorization page.
func secureURL(value string) string {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || len(value) > 8192 {
		return ""
	}
	return parsed.String()
}

func lastLine(output []byte) []byte {
	lines := bytes.Split(bytes.TrimSpace(output), []byte("\n"))
	return bytes.TrimSpace(lines[len(lines)-1])
}

type cappedBuffer struct {
	bytes.Buffer
	limit    int
	exceeded bool
}

func (b *cappedBuffer) Write(value []byte) (int, error) {
	if b.Len()+len(value) > b.limit {
		b.exceeded = true
		return len(value), nil
	}
	return b.Buffer.Write(value)
}

type tailBuffer struct {
	mu    sync.Mutex
	limit int
	value []byte
}

func (b *tailBuffer) Write(value []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.value = append(b.value, value...)
	if len(b.value) > b.limit {
		b.value = b.value[len(b.value)-b.limit:]
	}
	return len(value), nil
}

func (b *tailBuffer) summary(err error) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	lines := strings.Split(strings.TrimSpace(string(b.value)), "\n")
	if last := strings.TrimSpace(lines[len(lines)-1]); last != "" {
		return last
	}
	return err.Error()
}
