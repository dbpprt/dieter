//go:build !windows

package terminal

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

const (
	maxSessions         = 16
	maxFrameBytes       = 32 << 10
	maxInputBytes       = 64 << 10
	maxScrollbackBytes  = 2 << 20
	maxScrollbackFrames = 2048
	defaultColumns      = 120
	defaultRows         = 36
	minimumDimension    = 2
	maximumDimension    = 500
)

type unixBackend struct {
	mu       sync.RWMutex
	sessions map[string]*unixSession
}

type unixSession struct {
	mu      sync.RWMutex
	writeMu sync.Mutex
	value   Session
	pty     *os.File
	process *os.Process
	frames  []Frame
	bytes   int
	changed chan struct{}
	closed  bool
}

func newBackend() backend {
	return &unixBackend{sessions: map[string]*unixSession{}}
}

func (b *unixBackend) List(projectID string) []Session {
	b.mu.RLock()
	values := make([]*unixSession, 0, len(b.sessions))
	for _, session := range b.sessions {
		values = append(values, session)
	}
	b.mu.RUnlock()
	result := make([]Session, 0, len(values))
	for _, session := range values {
		session.mu.RLock()
		value := cloneSession(session.value)
		session.mu.RUnlock()
		if projectID == "" || value.ProjectID == projectID {
			result = append(result, value)
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].CreatedAt.Before(result[j].CreatedAt) })
	return result
}

func (b *unixBackend) Get(id string) (Session, error) { return b.snapshot(id) }

func (b *unixBackend) Create(input CreateInput) (Session, error) {
	b.mu.Lock()
	if len(b.sessions) >= maxSessions {
		b.mu.Unlock()
		return Session{}, ErrLimitReached
	}
	b.mu.Unlock()

	columns, rows, err := dimensions(input.Columns, input.Rows)
	if err != nil {
		return Session{}, err
	}
	shell, err := resolveShell(input.Shell)
	if err != nil {
		return Session{}, err
	}
	workingDirectory := filepath.Clean(input.WorkingDirectory)
	info, err := os.Stat(workingDirectory)
	if err != nil || !info.IsDir() {
		return Session{}, fmt.Errorf("terminal working directory is not a directory")
	}
	name := strings.TrimSpace(input.Name)
	if name == "" {
		name = filepath.Base(workingDirectory)
	}
	if len(name) > 80 {
		return Session{}, errors.New("terminal name is too long")
	}

	command := exec.Command(shell, "-l")
	command.Dir = workingDirectory
	command.Env = terminalEnvironment(os.Environ())
	pseudoTerminal, err := pty.StartWithSize(command, &pty.Winsize{Cols: uint16(columns), Rows: uint16(rows)})
	if err != nil {
		return Session{}, fmt.Errorf("start terminal: %w", err)
	}
	now := time.Now().UTC()
	value := Session{
		ID: randomID(), ProjectID: input.ProjectID, Name: name,
		Shell: filepath.Base(shell), WorkingDirectory: workingDirectory,
		Status: StatusRunning, PID: int64(command.Process.Pid), Columns: columns, Rows: rows,
		CreatedAt: now, UpdatedAt: now,
	}
	session := &unixSession{value: value, pty: pseudoTerminal, process: command.Process, changed: make(chan struct{})}
	b.mu.Lock()
	if len(b.sessions) >= maxSessions {
		b.mu.Unlock()
		_ = pseudoTerminal.Close()
		_ = command.Process.Kill()
		_, _ = command.Process.Wait()
		return Session{}, ErrLimitReached
	}
	b.sessions[value.ID] = session
	b.mu.Unlock()
	go session.capture(command)
	return cloneSession(value), nil
}

func (b *unixBackend) Frames(id string, after uint64) ([]Frame, <-chan struct{}, error) {
	session, err := b.session(id)
	if err != nil {
		return nil, nil, err
	}
	session.mu.RLock()
	defer session.mu.RUnlock()
	changed := session.changed
	value := cloneSession(session.value)
	if after == 0 || (len(session.frames) > 0 && after+1 < session.frames[0].Sequence) {
		data := make([]byte, 0, session.bytes)
		for _, frame := range session.frames {
			data = append(data, frame.Data...)
		}
		return []Frame{{Session: value, Sequence: value.Sequence, Data: data, Reset: true}}, changed, nil
	}
	result := Frame{Session: value}
	for _, frame := range session.frames {
		if frame.Sequence > after {
			result.Sequence = frame.Sequence
			result.Data = append(result.Data, frame.Data...)
		}
	}
	if result.Sequence > 0 {
		return []Frame{result}, changed, nil
	}
	if value.Sequence > after {
		return []Frame{{Session: value, Sequence: value.Sequence}}, changed, nil
	}
	return nil, changed, nil
}

func (b *unixBackend) Write(id string, data []byte) (Session, error) {
	if len(data) == 0 {
		return b.snapshot(id)
	}
	if len(data) > maxInputBytes {
		return Session{}, fmt.Errorf("terminal input exceeds %d KiB", maxInputBytes>>10)
	}
	session, err := b.session(id)
	if err != nil {
		return Session{}, err
	}
	session.writeMu.Lock()
	defer session.writeMu.Unlock()
	session.mu.RLock()
	running, pseudoTerminal := session.value.Status == StatusRunning, session.pty
	session.mu.RUnlock()
	if !running || pseudoTerminal == nil {
		return Session{}, ErrNotRunning
	}
	if _, err := pseudoTerminal.Write(data); err != nil {
		return Session{}, fmt.Errorf("write terminal: %w", err)
	}
	return b.snapshot(id)
}

func (b *unixBackend) Resize(id string, columns, rows int) (Session, error) {
	columns, rows, err := dimensions(columns, rows)
	if err != nil {
		return Session{}, err
	}
	session, err := b.session(id)
	if err != nil {
		return Session{}, err
	}
	session.mu.Lock()
	if session.value.Status != StatusRunning || session.pty == nil {
		session.mu.Unlock()
		return Session{}, ErrNotRunning
	}
	if session.value.Columns == columns && session.value.Rows == rows {
		value := cloneSession(session.value)
		session.mu.Unlock()
		return value, nil
	}
	if err := pty.Setsize(session.pty, &pty.Winsize{Cols: uint16(columns), Rows: uint16(rows)}); err != nil {
		session.mu.Unlock()
		return Session{}, fmt.Errorf("resize terminal: %w", err)
	}
	session.value.Columns = columns
	session.value.Rows = rows
	session.advanceLocked(nil)
	value := cloneSession(session.value)
	session.mu.Unlock()
	return value, nil
}

func (b *unixBackend) Rename(id, name string) (Session, error) {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 80 {
		return Session{}, errors.New("terminal name must be between 1 and 80 characters")
	}
	session, err := b.session(id)
	if err != nil {
		return Session{}, err
	}
	session.mu.Lock()
	if session.value.Name != name {
		session.value.Name = name
		session.advanceLocked(nil)
	}
	value := cloneSession(session.value)
	session.mu.Unlock()
	return value, nil
}

func (b *unixBackend) Close(id string) error {
	b.mu.Lock()
	session := b.sessions[id]
	if session == nil {
		b.mu.Unlock()
		return ErrNotFound
	}
	delete(b.sessions, id)
	b.mu.Unlock()
	session.terminate()
	return nil
}

func (b *unixBackend) Shutdown(ctx context.Context) {
	b.mu.Lock()
	values := make([]*unixSession, 0, len(b.sessions))
	for id, session := range b.sessions {
		values = append(values, session)
		delete(b.sessions, id)
	}
	b.mu.Unlock()
	for _, session := range values {
		session.terminate()
	}
	select {
	case <-ctx.Done():
	default:
	}
}

func (b *unixBackend) session(id string) (*unixSession, error) {
	b.mu.RLock()
	session := b.sessions[strings.TrimSpace(id)]
	b.mu.RUnlock()
	if session == nil {
		return nil, ErrNotFound
	}
	return session, nil
}

func (b *unixBackend) snapshot(id string) (Session, error) {
	session, err := b.session(id)
	if err != nil {
		return Session{}, err
	}
	session.mu.RLock()
	defer session.mu.RUnlock()
	return cloneSession(session.value), nil
}

func (s *unixSession) capture(command *exec.Cmd) {
	buffer := make([]byte, maxFrameBytes)
	for {
		count, err := s.pty.Read(buffer)
		if count > 0 {
			s.mu.Lock()
			s.advanceLocked(buffer[:count])
			s.mu.Unlock()
		}
		if err != nil {
			break
		}
	}
	waitErr := command.Wait()
	exitCode := 0
	if waitErr != nil {
		var exit *exec.ExitError
		if errors.As(waitErr, &exit) {
			exitCode = exit.ExitCode()
		} else {
			exitCode = -1
		}
	}
	s.mu.Lock()
	if s.value.Status == StatusRunning {
		s.value.Status = StatusExited
		s.value.ExitCode = &exitCode
		s.value.PID = 0
		s.advanceLocked(nil)
	}
	s.mu.Unlock()
}

func (s *unixSession) advanceLocked(data []byte) {
	s.value.Sequence++
	s.value.UpdatedAt = time.Now().UTC()
	frame := Frame{Sequence: s.value.Sequence, Data: append([]byte(nil), data...)}
	s.frames = append(s.frames, frame)
	s.bytes += len(frame.Data)
	for len(s.frames) > maxScrollbackFrames || (s.bytes > maxScrollbackBytes && len(s.frames) > 1) {
		s.bytes -= len(s.frames[0].Data)
		s.frames = s.frames[1:]
	}
	close(s.changed)
	s.changed = make(chan struct{})
}

func (s *unixSession) terminate() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	process, pseudoTerminal := s.process, s.pty
	s.mu.Unlock()
	if process != nil {
		_ = process.Signal(syscall.SIGHUP)
	}
	if pseudoTerminal != nil {
		_ = pseudoTerminal.Close()
	}
	if process != nil {
		go func() {
			timer := time.NewTimer(750 * time.Millisecond)
			defer timer.Stop()
			<-timer.C
			_ = process.Kill()
		}()
	}
}

func dimensions(columns, rows int) (int, int, error) {
	if columns == 0 {
		columns = defaultColumns
	}
	if rows == 0 {
		rows = defaultRows
	}
	if columns < minimumDimension || columns > maximumDimension || rows < minimumDimension || rows > maximumDimension {
		return 0, 0, fmt.Errorf("terminal dimensions must be between %d and %d", minimumDimension, maximumDimension)
	}
	return columns, rows, nil
}

func resolveShell(requested string) (string, error) {
	name := filepath.Base(strings.TrimSpace(requested))
	if name == "." || name == "" {
		name = filepath.Base(os.Getenv("SHELL"))
	}
	if name == "." || name == "" {
		name = "zsh"
	}
	switch name {
	case "zsh", "bash", "fish", "sh":
	default:
		return "", errors.New("terminal shell must be zsh, bash, fish, or sh")
	}
	path, err := exec.LookPath(name)
	if err != nil {
		return "", fmt.Errorf("terminal shell %q is unavailable", name)
	}
	return path, nil
}

func terminalEnvironment(values []string) []string {
	result := make([]string, 0, len(values)+3)
	for _, value := range values {
		if strings.HasPrefix(value, "TERM=") || strings.HasPrefix(value, "COLORTERM=") || strings.HasPrefix(value, "TERM_PROGRAM=") {
			continue
		}
		result = append(result, value)
	}
	return append(result, "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=Dieter")
}

func randomID() string {
	value := make([]byte, 12)
	if _, err := io.ReadFull(rand.Reader, value); err != nil {
		return fmt.Sprintf("term_%d", time.Now().UnixNano())
	}
	return "term_" + hex.EncodeToString(value)
}

func cloneSession(value Session) Session {
	if value.ExitCode != nil {
		exitCode := *value.ExitCode
		value.ExitCode = &exitCode
	}
	return value
}
