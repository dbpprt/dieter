package remotedesktop

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

// A separate instance of the installed signed helper owns clipboard IPC. A
// stalled pasteboard provider cannot occupy the capture helper's command pipe.
type nativeClipboard struct {
	ctx     context.Context
	options SourceOptions
	name    string
	cancel  context.CancelFunc
	command *exec.Cmd
	input   io.WriteCloser
	output  chan nativeClipboardReply
}
type nativeClipboardReply struct {
	value *dieterv1.RemoteDesktopClipboardResponse
	err   error
}

func newNativeClipboard(ctx context.Context, o SourceOptions, name string) ClipboardBackend {
	return &nativeClipboard{ctx: ctx, options: o, name: name}
}
func (n *nativeClipboard) Close() {
	if n.cancel != nil {
		n.cancel()
	}
	if n.input != nil {
		_ = n.input.Close()
	}
}
func (n *nativeClipboard) start() error {
	path, err := resolveCaptureHelper(n.options.HelperPath)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(n.ctx)
	n.cancel = cancel
	args := []string{"--clipboard-service"}
	if n.options.ClipboardName != "" {
		args = append(args, "--clipboard-name", n.options.ClipboardName)
	} else if n.options.Kind == "native-synthetic" {
		args = append(args, "--clipboard-name", n.name)
	}
	if n.options.Kind == "native-synthetic" {
		args = append(args, "--dry-run")
	}
	command := exec.CommandContext(ctx, path, args...)
	n.input, err = command.StdinPipe()
	if err != nil {
		cancel()
		return err
	}
	out, err := command.StdoutPipe()
	if err != nil {
		cancel()
		return err
	}
	n.output = make(chan nativeClipboardReply, 1)
	if err = command.Start(); err != nil {
		cancel()
		return err
	}
	n.command = command
	go func() {
		scanner := bufio.NewScanner(out)
		scanner.Buffer(make([]byte, 65536), 8<<20)
		for scanner.Scan() {
			var value struct {
				Revision string `json:"revision"`
				Text     string `json:"text"`
				Changed  bool   `json:"changed"`
				HasText  bool   `json:"hasText"`
				Error    string `json:"error"`
			}
			err := json.Unmarshal(scanner.Bytes(), &value)
			reply := nativeClipboardReply{&dieterv1.RemoteDesktopClipboardResponse{Revision: value.Revision, Text: value.Text, Changed: value.Changed, HasText: value.HasText, Error: value.Error}, err}
			select {
			case n.output <- reply:
			case <-ctx.Done():
				return
			}
		}
		select {
		case n.output <- nativeClipboardReply{err: errors.New("native clipboard worker stopped")}:
		case <-ctx.Done():
		}
	}()
	go func() { _ = command.Wait(); cancel() }()
	return nil
}
func (n *nativeClipboard) Exchange(ctx context.Context, r *dieterv1.RemoteDesktopClipboardRequest) (*dieterv1.RemoteDesktopClipboardResponse, error) {
	if n.command == nil {
		if err := n.start(); err != nil {
			return nil, err
		}
	}
	raw, err := json.Marshal(struct {
		Action        int32  `json:"action"`
		Text          string `json:"text"`
		KnownRevision string `json:"knownRevision"`
	}{int32(r.Action), r.Text, r.KnownRevision})
	if err != nil {
		return nil, err
	}
	write := make(chan error, 1)
	go func() { _, err := n.input.Write(append(raw, '\n')); write <- err }()
	select {
	case err = <-write:
		if err != nil {
			n.Close()
			return nil, errors.New("native clipboard write failed")
		}
	case <-ctx.Done():
		n.Close()
		return nil, errors.New("clipboard timed out; outcome unknown, not retried")
	}
	select {
	case value := <-n.output:
		return value.value, value.err
	case <-ctx.Done():
		n.Close()
		return nil, errors.New("clipboard timed out; outcome unknown, not retried")
	}
}
