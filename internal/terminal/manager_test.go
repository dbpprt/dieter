//go:build !windows

package terminal

import (
	"bytes"
	"context"
	"errors"
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
