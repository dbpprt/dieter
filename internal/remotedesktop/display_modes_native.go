package remotedesktop

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"sync"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type nativeDisplay struct {
	mu        sync.Mutex
	options   SourceOptions
	arguments []string
	cancel    context.CancelFunc
	input     io.WriteCloser
	output    chan []byte
	done      chan struct{}
	closed    bool
}

func newNativeDisplay(options SourceOptions) *nativeDisplay { return &nativeDisplay{options: options} }

func (n *nativeDisplay) start() error {
	path, err := resolveCaptureHelper(n.options.HelperPath)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	args := n.arguments
	if len(args) == 0 {
		args = []string{"--display-service"}
	}
	if n.options.Kind == "native-synthetic" {
		args = append(args, "--dry-run")
	}
	cmd := exec.CommandContext(ctx, path, args...)
	configureCaptureCommand(cmd)
	input, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		return err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		input.Close()
		cancel()
		return err
	}
	if err = cmd.Start(); err != nil {
		input.Close()
		cancel()
		return err
	}
	n.input = input
	n.cancel = cancel
	n.output = make(chan []byte, 1)
	n.done = make(chan struct{})
	go func() {
		defer close(n.output)
		scanner := bufio.NewScanner(out)
		scanner.Buffer(make([]byte, 4096), 131072)
		for scanner.Scan() {
			value := append([]byte(nil), scanner.Bytes()...)
			select {
			case n.output <- value:
			case <-ctx.Done():
				return
			}
		}
	}()
	go func() { _ = cmd.Wait(); close(n.done); cancel() }()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				// A bounded mutation already owns the pipe. Start the heartbeat
				// deadline after admission, never while waiting for that mutation.
				if !n.mu.TryLock() {
					continue
				}
				if n.closed {
					n.mu.Unlock()
					return
				}
				heartbeat, stop := context.WithTimeout(ctx, time.Second)
				err := n.exchangeLocked(heartbeat, map[string]string{"action": "heartbeat"}, nil)
				stop()
				n.mu.Unlock()
				if err != nil {
					n.Close()
					return
				}
			}
		}
	}()
	return nil
}

func (n *nativeDisplay) Close() {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.closeLocked()
}
func (n *nativeDisplay) closeLocked() {
	if n.closed {
		return
	}
	n.closed = true
	if n.input != nil {
		_ = n.input.Close()
	}
	if n.done != nil {
		select {
		case <-n.done:
		case <-time.After(n.closeGrace()):
			n.cancel()
			<-n.done
		}
	}
	if n.cancel != nil {
		n.cancel()
	}
}
func (n *nativeDisplay) Exchange(ctx context.Context, action, display, mode, expected string) (*dieterv1.RemoteDesktopDisplayModes, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.closed {
		return nil, errors.New("display helper stopped; reconnect to retry")
	}
	if n.input == nil {
		if err := n.start(); err != nil {
			return nil, err
		}
	}
	result := &dieterv1.RemoteDesktopDisplayModes{}
	var destination proto.Message = result
	if action == "heartbeat" {
		destination = nil
	}
	err := n.exchangeLocked(ctx, map[string]string{"action": action, "display_id": display, "mode_id": mode, "expected_current_mode_id": expected}, destination)
	return result, err
}

func (n *nativeDisplay) exchangeLocked(ctx context.Context, request any, result proto.Message) error {
	raw, _ := json.Marshal(request)
	written := make(chan error, 1)
	go func() { _, err := n.input.Write(append(raw, '\n')); written <- err }()
	select {
	case err := <-written:
		if err != nil {
			n.closeLocked()
			return err
		}
	case <-ctx.Done():
		n.closeLocked()
		return ctx.Err()
	}
	select {
	case raw, ok := <-n.output:
		if !ok {
			n.closeLocked()
			return errors.New("display helper stopped")
		}
		var reply struct {
			Result json.RawMessage `json:"result"`
			Error  string          `json:"error"`
		}
		if err := json.Unmarshal(raw, &reply); err != nil {
			n.closeLocked()
			return err
		}
		if reply.Error != "" {
			return errors.New(reply.Error)
		}
		if result != nil && len(reply.Result) > 0 {
			if err := protojson.Unmarshal(reply.Result, result); err != nil {
				n.closeLocked()
				return err
			}
		}
		return nil
	case <-ctx.Done():
		n.closeLocked()
		return ctx.Err()
	}
}

func (n *nativeDisplay) closeGrace() time.Duration {
	if len(n.arguments) > 0 && n.arguments[0] == "--virtual-display-service" {
		return 3 * time.Second
	}
	return 500 * time.Millisecond
}
