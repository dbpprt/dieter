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
)

type nativeDisplay struct {
	mu      sync.Mutex
	options SourceOptions
	cancel  context.CancelFunc
	input   io.WriteCloser
	output  chan []byte
	done    chan struct{}
	closed  bool
}

func newNativeDisplay(options SourceOptions) *nativeDisplay { return &nativeDisplay{options: options} }

func (n *nativeDisplay) start() error {
	path, err := resolveCaptureHelper(n.options.HelperPath)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	args := []string{"--display-service"}
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
				heartbeat, stop := context.WithTimeout(ctx, time.Second)
				_, err := n.Exchange(heartbeat, "heartbeat", "", "", "")
				stop()
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
		case <-time.After(500 * time.Millisecond):
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
	raw, _ := json.Marshal(map[string]string{"action": action, "display_id": display, "mode_id": mode, "expected_current_mode_id": expected})
	written := make(chan error, 1)
	go func() { _, err := n.input.Write(append(raw, '\n')); written <- err }()
	select {
	case err := <-written:
		if err != nil {
			n.closeLocked()
			return nil, err
		}
	case <-ctx.Done():
		n.closeLocked()
		return nil, ctx.Err()
	}
	select {
	case raw, ok := <-n.output:
		if !ok {
			n.closeLocked()
			return nil, errors.New("display helper stopped")
		}
		var reply struct {
			Result json.RawMessage `json:"result"`
			Error  string          `json:"error"`
		}
		if err := json.Unmarshal(raw, &reply); err != nil {
			n.closeLocked()
			return nil, err
		}
		if reply.Error != "" {
			return nil, errors.New(reply.Error)
		}
		result := &dieterv1.RemoteDesktopDisplayModes{}
		if len(reply.Result) > 0 {
			if err := protojson.Unmarshal(reply.Result, result); err != nil {
				n.closeLocked()
				return nil, err
			}
		}
		return result, nil
	case <-ctx.Done():
		n.closeLocked()
		return nil, ctx.Err()
	}
}
