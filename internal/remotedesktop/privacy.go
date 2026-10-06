package remotedesktop

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

// PrivacyDriver is injectable only by isolated daemon/native fixtures. All
// production operations use the signed capture helper, never an app viewer.
type PrivacyDriver interface {
	Snapshot(context.Context) (*dieterv1.MachinePrivacy, error)
	Set(context.Context, bool) (*dieterv1.MachinePrivacy, error)
}

type privacyOperationError struct{ message string }

func (e *privacyOperationError) Error() string { return e.message }

type NativePrivacy struct {
	mu                 sync.Mutex
	root, helper, boot string
	synthetic          bool
}

func NewNativePrivacy(root, helper string, synthetic bool) *NativePrivacy {
	return &NativePrivacy{root: root, helper: helper, synthetic: synthetic}
}

func (n *NativePrivacy) BootID(ctx context.Context) (string, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.boot != "" {
		return n.boot, nil
	}
	if n.synthetic {
		n.boot = "synthetic-boot"
		return n.boot, nil
	}
	if runtime.GOOS != "darwin" {
		return "", errors.New("Privacy mode requires macOS")
	}
	command := exec.CommandContext(ctx, "/usr/sbin/sysctl", "-n", "kern.bootsessionuuid")
	raw, err := command.Output()
	if err != nil {
		return "", err
	}
	n.boot = strings.TrimSpace(string(raw))
	if len(n.boot) < 8 || len(n.boot) > 64 {
		return "", errors.New("macOS boot identity is unavailable")
	}
	return n.boot, nil
}

func (n *NativePrivacy) directory() string { return filepath.Join(n.root, "runtime", "privacy") }

func (n *NativePrivacy) exchange(ctx context.Context, action string) (*dieterv1.MachinePrivacy, error) {
	connection, err := (&net.Dialer{}).DialContext(ctx, "unix", filepath.Join(n.directory(), "control.sock"))
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	deadline := time.Now().Add(3 * time.Second)
	if value, ok := ctx.Deadline(); ok && value.Before(deadline) {
		deadline = value
	}
	_ = connection.SetDeadline(deadline)
	stop := context.AfterFunc(ctx, func() { _ = connection.Close() })
	defer stop()
	raw, _ := json.Marshal(map[string]string{"action": action})
	if _, err = connection.Write(append(raw, '\n')); err != nil {
		return nil, err
	}
	scanner := bufio.NewScanner(connection)
	scanner.Buffer(make([]byte, 1024), 8192)
	if !scanner.Scan() {
		if scanner.Err() != nil {
			return nil, scanner.Err()
		}
		return nil, errors.New("privacy helper closed without a reply")
	}
	return decodePrivacy(scanner.Bytes())
}

func decodePrivacy(raw []byte) (*dieterv1.MachinePrivacy, error) {
	var value struct {
		Supported    bool   `json:"supported"`
		Requested    bool   `json:"requested"`
		State        int32  `json:"state"`
		Reason       string `json:"reason"`
		DisplayCount uint32 `json:"display_count"`
		Error        string `json:"error"`
	}
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, err
	}
	if len(value.Error) > 1024 {
		return nil, errors.New("invalid native privacy error")
	}
	if value.Error != "" {
		return nil, &privacyOperationError{value.Error}
	}
	if value.State < 0 || value.State > 2 || value.DisplayCount > 32 || len(value.Reason) > 1024 || (value.State == 1 && (!value.Supported || !value.Requested)) || (value.State == 2 && !value.Requested) {
		return nil, errors.New("invalid native privacy state")
	}
	return &dieterv1.MachinePrivacy{Supported: value.Supported, Requested: value.Requested, State: dieterv1.MachinePrivacy_State(value.State), Reason: value.Reason, DisplayCount: value.DisplayCount}, nil
}

func (n *NativePrivacy) Snapshot(ctx context.Context) (*dieterv1.MachinePrivacy, error) {
	if runtime.GOOS != "darwin" && !n.synthetic {
		return &dieterv1.MachinePrivacy{Reason: "Privacy mode requires macOS"}, nil
	}
	if value, err := n.exchange(ctx, "status"); err == nil {
		return value, nil
	}
	helper, err := resolveCaptureHelper(n.helper)
	if err != nil {
		return &dieterv1.MachinePrivacy{Reason: err.Error()}, nil
	}
	args := []string{"--privacy-capabilities"}
	if n.synthetic {
		args = append(args, "--dry-run")
	}
	command := exec.CommandContext(ctx, helper, args...)
	configureCaptureCommand(command)
	command.Stdout = &boundedPrivacyOutput{}
	diagnostic := &boundedPrivacyOutput{}
	command.Stderr = diagnostic
	if err = command.Run(); err != nil {
		return nil, fmt.Errorf("privacy capability probe: %w", nativeCaptureFailure(err, strings.TrimSpace(string(diagnostic.data))))
	}
	return decodePrivacy(command.Stdout.(*boundedPrivacyOutput).data)
}

// The helper is a boot-scoped privacy owner. Its private Unix socket lets a
// replacement daemon adopt it, retaining input/display protection across
// daemon restarts. It exits on explicit unlock; no parent pipe disconnect can
// unlock the machine. launch admission is serialized by the helper's flock.
func (n *NativePrivacy) Set(ctx context.Context, enabled bool) (*dieterv1.MachinePrivacy, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	action := "off"
	if enabled {
		action = "on"
	}
	if value, err := n.exchange(ctx, action); err == nil {
		return value, nil
	} else {
		var rejected *privacyOperationError
		if errors.As(err, &rejected) {
			return nil, err
		}
	}
	if runtime.GOOS != "darwin" && !n.synthetic {
		return nil, errors.New("Privacy mode requires macOS")
	}
	helper, err := resolveCaptureHelper(n.helper)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(n.directory(), 0700); err != nil {
		return nil, err
	}
	args := []string{"--privacy-service", "--privacy-directory", n.directory()}
	if n.synthetic {
		args = append(args, "--dry-run")
	}
	command := exec.CommandContext(context.Background(), helper, args...)
	configureCaptureCommand(command)
	diagnostic := &boundedPrivacyOutput{}
	command.Stderr = diagnostic
	if err = command.Start(); err != nil {
		return nil, err
	}
	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	timeout := time.NewTimer(5 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case err := <-exited:
			if err != nil {
				return nil, nativeCaptureFailure(err, strings.TrimSpace(string(diagnostic.data)))
			}
			exited = nil // Another live helper may have won the owner lock.
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timeout.C:
			return nil, errors.New("privacy helper did not become ready")
		case <-ticker.C:
			if value, err := n.exchange(ctx, action); err == nil {
				return value, nil
			} else {
				var rejected *privacyOperationError
				if errors.As(err, &rejected) {
					return nil, err
				}
			}
		}
	}
}

type boundedPrivacyOutput struct{ data []byte }

func (b *boundedPrivacyOutput) Write(p []byte) (int, error) {
	if len(b.data)+len(p) > 8192 {
		return 0, errors.New("privacy probe output exceeded its bound")
	}
	b.data = append(b.data, p...)
	return len(p), nil
}
