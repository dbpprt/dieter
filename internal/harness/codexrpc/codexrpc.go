// Package codexrpc is a small client of `codex app-server`: JSON-RPC 2.0
// messages, one per line, over the process's stdin and stdout. Dieter uses it
// for Codex's own account operations (sign-in, refresh, sign-out, rate
// limits), never for turns, which run through the harness runner.
package codexrpc

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/harness/agentexec"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
)

// MaxLineBytes bounds one protocol message.
const MaxLineBytes = 1 << 20

const (
	notificationBuffer = 64
	stderrTailBytes    = 4 << 10
	closeGrace         = 2 * time.Second
)

// ErrClosed reports a request on a client whose app-server has exited.
var ErrClosed = errors.New("codex app-server exited")

// Options start an app-server.
type Options struct {
	// Path is the Codex executable; Args its arguments, normally ending in
	// "app-server" (Codex reads -c overrides before the subcommand).
	Path string
	Args []string
	// Env is the complete process environment.
	Env []string
	// Dir is the working directory; empty inherits the daemon's.
	Dir string
}

// Notification is a server-to-client message without an ID.
type Notification struct {
	Method string
	Params json.RawMessage
}

// Error is a JSON-RPC error response.
type Error struct {
	Code    int64           `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *Error) Error() string { return fmt.Sprintf("codex app-server: %s (%d)", e.Message, e.Code) }

type message struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *Error          `json:"error,omitempty"`
}

type response struct {
	result json.RawMessage
	err    error
}

// Client is one running app-server. Close it to stop the process.
type Client struct {
	command *exec.Cmd
	stdin   io.WriteCloser
	writeMu sync.Mutex

	mu      sync.Mutex
	nextID  int64
	pending map[int64]chan response
	err     error

	notifications chan Notification
	done          chan struct{} // reader finished and the process was reaped
	stderr        *tail
	closeOnce     sync.Once
}

// Start launches the app-server and completes the initialize handshake
// (clientInfo dieter, then the initialized notification) within ctx.
func Start(ctx context.Context, options Options) (*Client, error) {
	command := exec.Command(options.Path, options.Args...)
	command.Env, command.Dir = options.Env, options.Dir
	agentexec.PrepareCommand(command, false)
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	client := &Client{
		command: command, stdin: stdin, pending: map[int64]chan response{},
		notifications: make(chan Notification, notificationBuffer), done: make(chan struct{}),
		stderr: &tail{limit: stderrTailBytes},
	}
	command.Stderr = client.stderr
	if err := command.Start(); err != nil {
		return nil, fmt.Errorf("start codex app-server: %w", err)
	}
	go client.read(stdout)
	params := map[string]any{"clientInfo": map[string]any{"name": "dieter", "title": "Dieter", "version": buildinfo.ReleaseVersion}}
	if err := client.Request(ctx, "initialize", params, nil); err != nil {
		client.Close()
		return nil, fmt.Errorf("initialize codex app-server: %w", err)
	}
	if err := client.Notify("initialized", nil); err != nil {
		client.Close()
		return nil, err
	}
	return client, nil
}

// Request sends a request and decodes its result into result (when non-nil).
func (c *Client) Request(ctx context.Context, method string, params, result any) error {
	c.mu.Lock()
	if c.err != nil {
		err := c.err
		c.mu.Unlock()
		return err
	}
	c.nextID++
	id := c.nextID
	reply := make(chan response, 1)
	c.pending[id] = reply
	c.mu.Unlock()
	forget := func() {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
	}
	request := map[string]any{"jsonrpc": "2.0", "id": id, "method": method}
	if params != nil {
		request["params"] = params
	}
	if err := c.write(request); err != nil {
		forget()
		return err
	}
	select {
	case answer := <-reply:
		if answer.err != nil {
			return answer.err
		}
		if result == nil {
			return nil
		}
		if err := json.Unmarshal(answer.result, result); err != nil {
			return fmt.Errorf("codex app-server %s returned an unexpected result: %w", method, err)
		}
		return nil
	case <-ctx.Done():
		forget()
		return ctx.Err()
	}
}

// Notify sends a notification.
func (c *Client) Notify(method string, params any) error {
	notification := map[string]any{"jsonrpc": "2.0", "method": method}
	if params != nil {
		notification["params"] = params
	}
	return c.write(notification)
}

// Notifications delivers server notifications in order. When a consumer falls
// behind by more than 64 messages, the oldest are dropped. It is closed when
// the app-server exits.
func (c *Client) Notifications() <-chan Notification { return c.notifications }

// Done is closed when the app-server has exited.
func (c *Client) Done() <-chan struct{} { return c.done }

// Err is why the app-server exited, or nil while it runs.
func (c *Client) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.err
}

// Close stops the app-server: it closes stdin (app-server exits on EOF), then
// terminates and finally kills the process group. It waits for the exit.
func (c *Client) Close() {
	c.closeOnce.Do(func() {
		c.writeMu.Lock()
		_ = c.stdin.Close()
		c.writeMu.Unlock()
		timer := time.NewTimer(closeGrace)
		defer timer.Stop()
		select {
		case <-c.done:
			return
		case <-timer.C:
		}
		agentexec.Terminate(c.command, c.done, closeGrace)
		<-c.done
	})
}

func (c *Client) write(value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(raw) >= MaxLineBytes {
		return errors.New("codex app-server message exceeds 1 MiB")
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	select {
	case <-c.done:
		return c.Err()
	default:
	}
	if _, err := c.stdin.Write(append(raw, '\n')); err != nil {
		if exitErr := c.Err(); exitErr != nil {
			return exitErr
		}
		return fmt.Errorf("write to codex app-server: %w", err)
	}
	return nil
}

func (c *Client) read(stdout io.Reader) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64<<10), MaxLineBytes)
	var failure error
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var incoming message
		if err := json.Unmarshal(line, &incoming); err != nil {
			failure = fmt.Errorf("codex app-server wrote invalid JSON: %w", err)
			break
		}
		c.dispatch(incoming)
	}
	if failure == nil {
		failure = scanner.Err()
	}
	if failure != nil {
		// A protocol violation ends the session; the process cannot continue.
		agentexec.Terminate(c.command, nil, 0)
		_, _ = io.Copy(io.Discard, stdout)
	}
	waitErr := c.command.Wait()
	switch {
	case failure != nil:
	case waitErr != nil:
		failure = fmt.Errorf("%w: %w%s", ErrClosed, waitErr, c.stderr.suffix())
	default:
		failure = ErrClosed
	}
	c.mu.Lock()
	c.err = failure
	pending := c.pending
	c.pending = map[int64]chan response{}
	c.mu.Unlock()
	for _, reply := range pending {
		reply <- response{err: failure}
	}
	close(c.notifications)
	close(c.done)
}

func (c *Client) dispatch(incoming message) {
	hasID := len(incoming.ID) > 0 && string(incoming.ID) != "null"
	switch {
	case incoming.Method != "" && hasID:
		// Dieter offers no server-request capability (approvals, external
		// token refresh); refuse each so the server never waits.
		_ = c.write(map[string]any{"jsonrpc": "2.0", "id": incoming.ID, "error": map[string]any{"code": -32601, "message": "Dieter does not handle " + incoming.Method}})
	case incoming.Method != "":
		notification := Notification{Method: incoming.Method, Params: incoming.Params}
		select {
		case c.notifications <- notification:
		default:
			select {
			case <-c.notifications:
			default:
			}
			select {
			case c.notifications <- notification:
			default:
			}
		}
	case hasID:
		id, err := strconv.ParseInt(string(bytes.Trim(incoming.ID, `"`)), 10, 64)
		if err != nil {
			return
		}
		c.mu.Lock()
		reply := c.pending[id]
		delete(c.pending, id)
		c.mu.Unlock()
		if reply == nil {
			return
		}
		if incoming.Error != nil {
			reply <- response{err: incoming.Error}
		} else {
			reply <- response{result: incoming.Result}
		}
	}
}

// tail keeps the last bytes of the app-server's stderr for diagnostics.
type tail struct {
	mu     sync.Mutex
	limit  int
	buffer []byte
}

func (t *tail) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buffer = append(t.buffer, p...)
	if len(t.buffer) > t.limit {
		t.buffer = append([]byte(nil), t.buffer[len(t.buffer)-t.limit:]...)
	}
	return len(p), nil
}

func (t *tail) suffix() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	text := string(bytes.TrimSpace(t.buffer))
	if text == "" {
		return ""
	}
	if index := bytes.LastIndexByte([]byte(text), '\n'); index >= 0 {
		text = text[index+1:]
	}
	return ": " + text
}
