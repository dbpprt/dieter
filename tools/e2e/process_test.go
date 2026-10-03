package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestCommandCancellationWaitsForOwnedGrandchildren(t *testing.T) {
	root := t.TempDir()
	script := filepath.Join(root, "nested child.sh")
	// A shell grandchild owns a sleeper and records graceful cleanup. The root
	// exits immediately on TERM, reproducing the former orphaned compiler bug.
	body := `#!/bin/sh
if [ "$1" = child ]; then
 trap 'kill "$sleep_pid" 2>/dev/null; wait "$sleep_pid" 2>/dev/null; echo stopped > stopped; exit 0' TERM
 sleep 30 &
 sleep_pid=$!
 echo $$ > grandchild
 wait "$sleep_pid"
else
 trap 'exit 0' TERM
 /bin/sh "$0" child &
 wait
fi
`
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := command(ctx, root, nil, "/bin/sh", script); done <- err }()
	deadline := time.Now().Add(5 * time.Second)
	var pid int
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(filepath.Join(root, "grandchild"))
		if err == nil {
			pid, _ = strconv.Atoi(strings.TrimSpace(string(data)))
			if pid > 0 {
				break
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	if pid == 0 {
		t.Fatal("grandchild did not start")
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled command reported success")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("owned process group did not stop")
	}
	if _, err := os.Stat(filepath.Join(root, "stopped")); err != nil {
		t.Fatal("grandchild cleanup not awaited", err)
	}
	if err := syscall.Kill(pid, 0); err != syscall.ESRCH {
		t.Fatal(fmt.Sprintf("grandchild %d remains: %v", pid, err))
	}
}

func TestAppleBuildLeaseInteroperatesWithDirectRecipes(t *testing.T) {
	root := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	leased, unlock, err := leaseAppleBuild(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	released := false
	defer func() {
		if !released {
			unlock()
		}
	}()
	out, err := command(leased, root, nil, "/bin/sh", "-c", `printf '%s' "$DIETER_APPLE_BUILD_LEASE"`)
	if err != nil || out != root {
		t.Fatal("nested recipe did not inherit the owned lease", out, err)
	}
	helper, err := filepath.Abs("../../scripts/native_build_lock.py")
	if err != nil {
		t.Fatal(err)
	}
	out, err = command(ctx, root, nil, "python3", helper, "apple-build", root, "/bin/sh", "-c", "exit 0")
	if err == nil || !strings.Contains(out, "Native build resource busy") || !strings.Contains(out, strconv.Itoa(os.Getpid())) {
		t.Fatal("direct recipe bypassed runner lease", out, err)
	}
	unlock()
	released = true
	if out, err = command(ctx, root, nil, "python3", helper, "apple-build", root, "/bin/sh", "-c", "exit 0"); err != nil {
		t.Fatal("lease not released", out, err)
	}
}
