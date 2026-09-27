package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Keep child output bounded, including a failed Gradle build or verbose fixture.
type tailBuffer struct {
	mu    sync.Mutex
	data  []byte
	limit int
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(p)
	b.data = append(b.data, p...)
	if len(b.data) > b.limit {
		b.data = bytes.Clone(b.data[len(b.data)-b.limit:])
	}
	return n, nil
}
func (b *tailBuffer) String() string { b.mu.Lock(); defer b.mu.Unlock(); return string(b.data) }

// Build commands own a separate process group. Cancellation stops its descendants
// before returning to the caller that releases a build/device lease. Shared workers
// already running outside this group are never signalled.
func buildCommand(ctx context.Context, executable string, args ...string) (*exec.Cmd, func(error) error) {
	c := exec.CommandContext(ctx, executable, args...)
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c.WaitDelay = 20 * time.Second
	var cleanup chan error
	c.Cancel = func() error {
		cleanup = make(chan error, 1)
		group := c.Process.Pid
		_ = syscall.Kill(-group, syscall.SIGTERM)
		go func() {
			// Go's default WaitDelay kills only the immediate child. Escalation here is
			// restricted to this command's group, including grandchildren retaining pipes.
			deadline := time.Now().Add(15 * time.Second)
			forced := false
			for {
				err := syscall.Kill(-group, 0)
				if errors.Is(err, syscall.ESRCH) {
					cleanup <- nil
					return
				}
				if err != nil {
					cleanup <- fmt.Errorf("inspect owned process group %d: %w", group, err)
					return
				}
				if time.Now().After(deadline) {
					if forced {
						cleanup <- fmt.Errorf("owned process group %d did not exit", group)
						return
					}
					_ = syscall.Kill(-group, syscall.SIGKILL)
					forced = true
					deadline = time.Now().Add(5 * time.Second)
				}
				time.Sleep(20 * time.Millisecond)
			}
		}()
		return nil
	}
	return c, func(err error) error {
		// Cmd.Wait synchronizes with Cancel, so cleanup is stable here.
		if cleanup != nil {
			err = errors.Join(err, <-cleanup)
		}
		return err
	}
}

func command(ctx context.Context, root string, input []byte, args ...string) (string, error) {
	c, finish := buildCommand(ctx, args[0], args[1:]...)
	c.Dir = root
	if input != nil {
		c.Stdin = bytes.NewReader(input)
	}
	out := &tailBuffer{limit: 4 << 20}
	c.Stdout = out
	c.Stderr = out
	err := finish(c.Run())
	return out.String(), err
}
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }
func shellArgs(args []string) string {
	q := make([]string, len(args))
	for i, s := range args {
		q[i] = shellQuote(s)
	}
	return strings.Join(q, " ")
}

// Interoperates with the old Android lease inode; never unlink a lock file.
func acquireLease(path string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("resource leased by another process: %s", path)
	}
	if err = f.Truncate(0); err != nil {
		f.Close()
		return nil, err
	}
	_, err = fmt.Fprintf(f, "{\"pid\":%d,\"owner\":\"dieter-e2e\"}\n", os.Getpid())
	if err != nil {
		f.Close()
		return nil, err
	}
	return func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }, nil
}
func deviceLease(serial string) (func(), error) {
	return acquireLease(filepath.Join("/tmp", fmt.Sprintf("android-device-leases-%d", os.Getuid()), fmt.Sprintf("%x.lock", sha256.Sum256([]byte(serial)))))
}

type ownedProcess struct {
	cmd  *exec.Cmd
	out  *tailBuffer
	done chan struct{}
	err  error
}

func startOwned(root string, args ...string) (*ownedProcess, error) {
	p := &ownedProcess{cmd: exec.Command(args[0], args[1:]...), out: &tailBuffer{limit: 2 << 20}, done: make(chan struct{})}
	p.cmd.Dir = root
	p.cmd.Stdout = p.out
	p.cmd.Stderr = p.out
	p.cmd.Env = append(os.Environ(), "DIETER_HARNESS_RUNTIME_DIR="+filepath.Join(root, "internal/harness/runtime"))
	if err := p.cmd.Start(); err != nil {
		return nil, err
	}
	go func() { p.err = p.cmd.Wait(); close(p.done) }()
	return p, nil
}
func (p *ownedProcess) stop() error {
	select {
	case <-p.done:
		return nil
	default:
	}
	_ = p.cmd.Process.Signal(os.Interrupt)
	select {
	case <-p.done:
		return nil
	case <-time.After(15 * time.Second):
	}
	_ = p.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-p.done:
		return nil
	case <-time.After(10 * time.Second):
		return fmt.Errorf("owned child %d did not exit; resources retained", p.cmd.Process.Pid)
	}
}
func digest(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", h.Sum(nil)), nil
}

// Binary evidence must never mix stderr into tar/PNG or silently keep a truncated tail.
func binaryCommand(ctx context.Context, root string, args ...string) (string, error) {
	c, finish := buildCommand(ctx, args[0], args[1:]...)
	c.Dir = root
	out, diagnostic := &tailBuffer{limit: 32 << 20}, &tailBuffer{limit: 64 << 10}
	c.Stdout, c.Stderr = out, diagnostic
	err := finish(c.Run())
	data := out.String()
	if len(data) >= 32<<20 {
		return "", fmt.Errorf("binary evidence exceeded 32 MiB")
	}
	if err != nil {
		return "", fmt.Errorf("binary capture: %w: %s", err, diagnostic.String())
	}
	return data, nil
}

// Direct Gradle installs share the runner's device lease; cancellation waits for the child.
func leasedCommand(ctx context.Context, args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: device-lease SERIAL COMMAND [ARGS...]")
	}
	serial := args[0]
	unlock, err := deviceLease(serial)
	if err != nil {
		return err
	}
	defer unlock()
	c, finish := buildCommand(ctx, args[1], args[2:]...)
	c.Env = append(os.Environ(), "DIETER_SCREEN_DEVICE_LEASE_V2="+serial)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return finish(c.Run())
}
