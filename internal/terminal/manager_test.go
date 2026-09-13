//go:build !windows

package terminal

import (
	"bytes"
	"context"
	"errors"
	"os"
	"testing"
	"time"
)

func TestSessionSurvivesObserverDisconnectAndResumesFromCursor(t *testing.T) {
	manager := New()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		manager.Shutdown(ctx)
	})
	session, err := manager.Create(CreateInput{
		ProjectID: "project", Name: "persistent", Shell: "sh", WorkingDirectory: t.TempDir(),
		Columns: 90, Rows: 28,
	})
	if err != nil {
		t.Fatal(err)
	}
	initial, _, err := manager.Frames(session.ID, 0)
	if err != nil || len(initial) != 1 || !initial[0].Reset {
		t.Fatalf("initial frame = %#v, %v", initial, err)
	}

	if _, err := manager.Write(session.ID, []byte("printf 'first-terminal-marker\\n'\n")); err != nil {
		t.Fatal(err)
	}
	first, cursor := waitForTerminalOutput(t, manager, session.ID, 0, []byte("first-terminal-marker"))
	if !bytes.Contains(first, []byte("first-terminal-marker")) {
		t.Fatalf("first output = %q", first)
	}

	// No observer is held here. The daemon-owned PTY remains alive and output
	// can be resumed from the previous cursor by a later client.
	if _, err := manager.Write(session.ID, []byte("printf 'resumed-terminal-marker\\n'\n")); err != nil {
		t.Fatal(err)
	}
	resumed, next := waitForTerminalOutput(t, manager, session.ID, cursor, []byte("resumed-terminal-marker"))
	if !bytes.Contains(resumed, []byte("resumed-terminal-marker")) || next <= cursor {
		t.Fatalf("resumed output=%q cursor=%d next=%d", resumed, cursor, next)
	}

	resized, err := manager.Resize(session.ID, 132, 40)
	if err != nil || resized.Columns != 132 || resized.Rows != 40 {
		t.Fatalf("resize = %#v, %v", resized, err)
	}
	if err := manager.Close(session.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Get(session.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get closed terminal error = %v", err)
	}
}

func TestPersistentSessionSurvivesManagerRestart(t *testing.T) {
	root := t.TempDir()
	manager := NewPersistent(root)
	if !manager.Durable() {
		t.Skip("tmux is unavailable")
	}
	t.Cleanup(func() {
		cleanup := NewPersistent(root)
		for _, session := range cleanup.List("") {
			_ = cleanup.Close(session.ID)
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		cleanup.Shutdown(ctx)
	})
	session, err := manager.Create(CreateInput{
		Name: "daemon-restart", Shell: "sh", WorkingDirectory: t.TempDir(), Columns: 90, Rows: 28,
	})
	if err != nil {
		t.Fatal(err)
	}
	prompt, _ := waitForTerminalOutput(t, manager, session.ID, 0, []byte(" "))
	if len(bytes.Trim(prompt, "\r\n")) == 0 {
		t.Fatalf("initial shell prompt was not captured: %q", prompt)
	}
	// Status polling runs independently from output capture. Give it several
	// cycles so a transient tmux client failure cannot poison a live session.
	time.Sleep(4 * persistentTerminalPollInterval)
	stable, err := manager.Get(session.ID)
	if err != nil || stable.Status != StatusRunning {
		t.Fatalf("persistent terminal became unavailable while its shell was alive: %#v, %v", stable, err)
	}
	if _, err := manager.Write(session.ID, []byte("printf 'before-daemon-restart\\n'\n")); err != nil {
		t.Fatal(err)
	}
	_, cursor := waitForTerminalOutput(t, manager, session.ID, 0, []byte("before-daemon-restart"))

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	manager.Shutdown(ctx)
	cancel()

	restarted := NewPersistent(root)
	if !restarted.Durable() {
		t.Fatal("persistent backend was not restored")
	}
	listed := restarted.List("")
	if len(listed) != 1 || listed[0].ID != session.ID || listed[0].Status != StatusRunning {
		t.Fatalf("restored sessions = %#v", listed)
	}
	replayed, resumedCursor := waitForTerminalOutput(
		t, restarted, session.ID, cursor, []byte("before-daemon-restart"))
	if !bytes.Contains(replayed, []byte("before-daemon-restart")) {
		t.Fatalf("restored scrollback = %q", replayed)
	}
	if _, err := restarted.Write(session.ID, []byte("printf 'after-daemon-restart\\n'\n")); err != nil {
		t.Fatal(err)
	}
	continued, _ := waitForTerminalOutput(
		t, restarted, session.ID, resumedCursor, []byte("after-daemon-restart"))
	if !bytes.Contains(continued, []byte("after-daemon-restart")) {
		t.Fatalf("continued output = %q", continued)
	}
	if err := restarted.Close(session.ID); err != nil {
		t.Fatal(err)
	}
}

func TestPersistentRestoreRemovesOrphanedTerminalFiles(t *testing.T) {
	root := t.TempDir()
	manager := NewPersistent(root)
	if !manager.Durable() {
		t.Skip("tmux is unavailable")
	}
	backend := manager.backend.(*unixBackend)
	const id = "term_orphaned"
	if err := backend.persistence.save("missing_tmux_session", Session{ID: id, Name: "Orphaned"}); err != nil {
		t.Fatal(err)
	}
	paths := []string{
		backend.persistence.recordPath(id), backend.persistence.logPath(id),
		backend.persistence.logPath(id) + ".chunk", backend.persistence.logPath(id) + ".next",
	}
	for _, path := range paths[1:] {
		if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	restored := NewPersistent(root)
	for _, path := range paths {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("orphaned terminal file %q was retained: %v", path, err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	restored.Shutdown(ctx)
}

func TestStaleCursorReceivesBoundedResetBaseline(t *testing.T) {
	session := &unixSession{
		value:   Session{ID: "term", Status: StatusRunning},
		changed: make(chan struct{}),
	}
	chunk := bytes.Repeat([]byte("x"), maxFrameBytes)
	for total := 0; total < maxScrollbackBytes+(4*maxFrameBytes); total += len(chunk) {
		session.mu.Lock()
		session.advanceLocked(chunk)
		session.mu.Unlock()
	}
	backend := &unixBackend{sessions: map[string]*unixSession{"term": session}}
	frames, _, err := backend.Frames("term", 1)
	if err != nil || len(frames) != 1 || !frames[0].Reset {
		t.Fatalf("stale frames = %#v, %v", frames, err)
	}
	if len(frames[0].Data) > maxScrollbackBytes {
		t.Fatalf("reset baseline is not bounded: %d", len(frames[0].Data))
	}
}

func waitForTerminalOutput(t *testing.T, manager *Manager, id string, after uint64, marker []byte) ([]byte, uint64) {
	t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	var result []byte
	for {
		frames, changed, err := manager.Frames(id, after)
		if err != nil {
			t.Fatal(err)
		}
		for _, frame := range frames {
			result = append(result, frame.Data...)
			if frame.Sequence > after {
				after = frame.Sequence
			}
		}
		if bytes.Contains(result, marker) {
			return result, after
		}
		select {
		case <-changed:
		case <-deadline.C:
			t.Fatalf("timed out waiting for %q in %q", marker, result)
		}
	}
}
