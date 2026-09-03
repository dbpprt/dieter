//go:build !windows

package remoteexec

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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
	"unicode"

	"github.com/creack/pty"
)

const (
	maxRunningExecutions         = 8
	maxRetainedExecutions        = 64
	maxRetainedEventFrames       = 4096
	maxFrameBytes                = 32 << 10
	maxInputBytes                = 64 << 10
	defaultMaxOutputBytes  int64 = 8 << 20
	maximumMaxOutputBytes  int64 = 64 << 20
	defaultColumns               = 120
	defaultRows                  = 36
	minimumDimension             = 2
	maximumDimension             = 500
	completedRetention           = 30 * time.Minute
	closedRetention              = time.Minute
	terminationGrace             = 750 * time.Millisecond
)

type unixBackend struct {
	mu       sync.RWMutex
	sessions map[string]*unixSession
}

type unixSession struct {
	mu              sync.RWMutex
	writeMu         sync.Mutex
	value           Execution
	command         *exec.Cmd
	process         *os.Process
	stdin           io.WriteCloser
	pty             *os.File
	events          []Event
	eventBytes      int64
	maxOutputBytes  int64
	changed         chan struct{}
	startupDone     chan struct{}
	requestHash     string
	cancelRequested bool
	timedOut        bool
	closed          bool
	stdinClosed     bool
}

func newBackend() backend { return &unixBackend{sessions: map[string]*unixSession{}} }

func (b *unixBackend) List(projectID, cardID, requestedStatus string) []Execution {
	b.mu.Lock()
	b.pruneLocked(time.Now().UTC())
	values := make([]*unixSession, 0, len(b.sessions))
	for _, session := range b.sessions {
		values = append(values, session)
	}
	b.mu.Unlock()

	result := make([]Execution, 0, len(values))
	for _, session := range values {
		session.mu.RLock()
		value := cloneExecution(session.value)
		closed := session.closed
		session.mu.RUnlock()
		if closed || projectID != "" && value.ProjectID != projectID || cardID != "" && value.CardID != cardID || requestedStatus != "" && value.Status != requestedStatus {
			continue
		}
		result = append(result, value)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].CreatedAt.Before(result[j].CreatedAt) })
	return result
}

func (b *unixBackend) Get(id string) (Execution, error) {
	session, err := b.session(id)
	if err != nil {
		return Execution{}, err
	}
	session.mu.RLock()
	defer session.mu.RUnlock()
	return cloneExecution(session.value), nil
}

func (b *unixBackend) Start(input StartInput) (Execution, error) {
	input, requestHash, err := normalizeStartInput(input)
	if err != nil {
		return Execution{}, err
	}

	b.mu.Lock()
	b.pruneLocked(time.Now().UTC())
	if input.IdempotencyKey != "" {
		for _, existing := range b.sessions {
			existing.mu.RLock()
			matches := existing.value.IdempotencyKey == input.IdempotencyKey
			hash := existing.requestHash
			value := cloneExecution(existing.value)
			existing.mu.RUnlock()
			if !matches {
				continue
			}
			b.mu.Unlock()
			if hash != requestHash {
				return Execution{}, ErrIdempotencyConflict
			}
			return value, nil
		}
	}
	running := 0
	for _, session := range b.sessions {
		session.mu.RLock()
		if session.value.Status == StatusRunning {
			running++
		}
		session.mu.RUnlock()
	}
	if running >= maxRunningExecutions {
		b.mu.Unlock()
		return Execution{}, ErrLimitReached
	}

	command := exec.Command(input.Argv[0], input.Argv[1:]...)
	command.Dir = input.WorkingDirectory
	command.Env = executionEnvironment(os.Environ(), input.Environment, input.PTY)

	var stdin io.WriteCloser
	var stdout, stderr io.ReadCloser
	var pseudoTerminal *os.File
	if input.PTY {
		pseudoTerminal, err = pty.StartWithSize(command, &pty.Winsize{Cols: uint16(input.Columns), Rows: uint16(input.Rows)})
		stdin = pseudoTerminal
	} else {
		command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		stdin, err = command.StdinPipe()
		if err == nil {
			stdout, err = command.StdoutPipe()
		}
		if err == nil {
			stderr, err = command.StderrPipe()
		}
		if err == nil {
			err = command.Start()
		}
	}
	if err != nil {
		b.mu.Unlock()
		if stdin != nil {
			_ = stdin.Close()
		}
		return Execution{}, fmt.Errorf("start remote execution: %w", err)
	}

	now := time.Now().UTC()
	value := Execution{
		ID: randomID(), ProjectID: input.ProjectID, CardID: input.CardID, Name: input.Name,
		Argv: append([]string(nil), input.Argv...), WorkingDirectory: input.WorkingDirectory,
		Status: StatusRunning, PID: int64(command.Process.Pid), PTY: input.PTY,
		Columns: input.Columns, Rows: input.Rows, CreatedAt: now, StartedAt: now, UpdatedAt: now,
		IdempotencyKey: input.IdempotencyKey, Timeout: input.Timeout,
	}
	session := &unixSession{
		value: value, command: command, process: command.Process, stdin: stdin, pty: pseudoTerminal,
		maxOutputBytes: input.MaxOutputBytes, changed: make(chan struct{}), startupDone: make(chan struct{}), requestHash: requestHash,
	}
	session.mu.Lock()
	session.advanceLocked(StreamState, nil, false)
	value = cloneExecution(session.value)
	session.mu.Unlock()
	b.sessions[value.ID] = session
	b.mu.Unlock()

	if input.PTY {
		go session.capturePTY()
	} else {
		go session.capturePipes(stdout, stderr)
	}
	if len(input.Stdin) > 0 || input.StdinEOF {
		if _, err := session.write(input.Stdin, input.StdinEOF); err != nil {
			_, _ = session.cancel()
			close(session.startupDone)
			return Execution{}, err
		}
	}
	close(session.startupDone)
	if input.Timeout > 0 {
		go session.enforceTimeout(input.Timeout)
	}
	return value, nil
}

func (b *unixBackend) Events(id string, after uint64) ([]Event, <-chan struct{}, error) {
	session, err := b.session(id)
	if err != nil {
		return nil, nil, err
	}
	session.mu.RLock()
	defer session.mu.RUnlock()
	changed := session.changed
	reset := after == 0 || session.value.TruncatedBeforeSequence > 0 && after < session.value.TruncatedBeforeSequence
	result := make([]Event, 0, len(session.events))
	for _, event := range session.events {
		if reset || event.Sequence > after {
			result = append(result, cloneEvent(event))
		}
	}
	if len(result) > 0 && reset {
		result[0].Reset = true
		result[0].Execution = cloneExecution(session.value)
	}
	if len(result) == 0 {
		if session.value.Status != StatusRunning {
			result = append(result, Event{Execution: cloneExecution(session.value), Sequence: session.value.Sequence, Stream: StreamState, EOF: true})
		} else if session.value.Sequence > after {
			result = append(result, Event{Execution: cloneExecution(session.value), Sequence: session.value.Sequence, Stream: StreamState})
		}
	}
	return result, changed, nil
}

func (b *unixBackend) Write(id string, data []byte, eof bool) (Execution, error) {
	session, err := b.session(id)
	if err != nil {
		return Execution{}, err
	}
	return session.write(data, eof)
}

func (b *unixBackend) Signal(id string, requested Signal) (Execution, error) {
	session, err := b.session(id)
	if err != nil {
		return Execution{}, err
	}
	return session.signal(requested)
}

func (b *unixBackend) Resize(id string, columns, rows int) (Execution, error) {
	columns, rows, err := dimensions(columns, rows)
	if err != nil {
		return Execution{}, err
	}
	session, err := b.session(id)
	if err != nil {
		return Execution{}, err
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.value.Status != StatusRunning {
		return Execution{}, ErrNotRunning
	}
	if !session.value.PTY || session.pty == nil {
		return Execution{}, errors.New("only PTY executions can be resized")
	}
	if err := pty.Setsize(session.pty, &pty.Winsize{Cols: uint16(columns), Rows: uint16(rows)}); err != nil {
		return Execution{}, fmt.Errorf("resize remote execution: %w", err)
	}
	session.value.Columns, session.value.Rows = columns, rows
	session.advanceLocked(StreamState, nil, false)
	return cloneExecution(session.value), nil
}

func (b *unixBackend) Cancel(id string) (Execution, error) {
	session, err := b.session(id)
	if err != nil {
		return Execution{}, err
	}
	return session.cancel()
}

func (b *unixBackend) Close(id string) error {
	session, err := b.session(id)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	session.close()
	return nil
}

func (b *unixBackend) Shutdown(ctx context.Context) {
	b.mu.RLock()
	values := make([]*unixSession, 0, len(b.sessions))
	for _, session := range b.sessions {
		values = append(values, session)
	}
	b.mu.RUnlock()
	for _, session := range values {
		session.close()
	}
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		running := false
		for _, session := range values {
			session.mu.RLock()
			running = running || session.process != nil
			session.mu.RUnlock()
		}
		if !running {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
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

func (b *unixBackend) pruneLocked(now time.Time) {
	type candidate struct {
		id        string
		completed time.Time
	}
	var completed []candidate
	for id, session := range b.sessions {
		session.mu.RLock()
		value, closed := session.value, session.closed
		session.mu.RUnlock()
		age := now.Sub(value.CompletedAt)
		if !value.CompletedAt.IsZero() && (closed && age >= closedRetention || age >= completedRetention) {
			delete(b.sessions, id)
			continue
		}
		if value.Status != StatusRunning {
			completed = append(completed, candidate{id: id, completed: value.CompletedAt})
		}
	}
	if len(b.sessions) < maxRetainedExecutions {
		return
	}
	sort.Slice(completed, func(i, j int) bool { return completed[i].completed.Before(completed[j].completed) })
	for len(b.sessions) >= maxRetainedExecutions && len(completed) > 0 {
		delete(b.sessions, completed[0].id)
		completed = completed[1:]
	}
}

func (s *unixSession) capturePTY() {
	buffer := make([]byte, maxFrameBytes)
	for {
		count, err := s.pty.Read(buffer)
		if count > 0 {
			s.advance(StreamPTY, buffer[:count], false)
		}
		if err != nil {
			break
		}
	}
	// exec.Cmd.Wait closes its pipes. Do not let it take ownership of stdin
	// before Start has delivered the initial input and EOF.
	<-s.startupDone
	s.finish(s.command.Wait())
}

func (s *unixSession) capturePipes(stdout, stderr io.ReadCloser) {
	var readers sync.WaitGroup
	readers.Add(2)
	go s.capturePipe(stdout, StreamStdout, &readers)
	go s.capturePipe(stderr, StreamStderr, &readers)
	readers.Wait()
	// Keep stdout and stderr draining concurrently with startup, but delay Wait
	// so it cannot close stdin before the initial handoff is complete.
	<-s.startupDone
	s.finish(s.command.Wait())
}

func (s *unixSession) capturePipe(reader io.ReadCloser, stream Stream, readers *sync.WaitGroup) {
	defer readers.Done()
	defer reader.Close()
	buffer := make([]byte, maxFrameBytes)
	for {
		count, err := reader.Read(buffer)
		if count > 0 {
			s.advance(stream, buffer[:count], false)
		}
		if err != nil {
			return
		}
	}
}

func (s *unixSession) finish(waitErr error) {
	exitCode, exitSignal := processResult(waitErr)
	now := time.Now().UTC()
	s.mu.Lock()
	if s.stdin != nil && !s.stdinClosed {
		_ = s.stdin.Close()
		s.stdinClosed = true
	}
	s.value.PID = 0
	s.value.CompletedAt = now
	s.value.ExitCode = &exitCode
	s.value.ExitSignal = exitSignal
	s.process = nil
	if s.pty != nil {
		_ = s.pty.Close()
	}
	if !s.closed {
		switch {
		case s.timedOut:
			s.value.Status = StatusTimedOut
		case s.cancelRequested:
			s.value.Status = StatusCanceled
		default:
			s.value.Status = StatusExited
		}
		s.advanceLocked(StreamState, nil, true)
	}
	s.mu.Unlock()
}

func (s *unixSession) advance(stream Stream, data []byte, eof bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.advanceLocked(stream, data, eof)
}

func (s *unixSession) advanceLocked(stream Stream, data []byte, eof bool) {
	s.value.Sequence++
	s.value.UpdatedAt = time.Now().UTC()
	switch stream {
	case StreamStdout, StreamPTY:
		s.value.StdoutBytes += uint64(len(data))
	case StreamStderr:
		s.value.StderrBytes += uint64(len(data))
	}
	event := Event{
		Execution: cloneExecution(s.value), Sequence: s.value.Sequence, Stream: stream,
		Data: append([]byte(nil), data...), EOF: eof,
	}
	s.events = append(s.events, event)
	s.eventBytes += int64(len(event.Data))
	for s.eventBytes > s.maxOutputBytes || len(s.events) > maxRetainedEventFrames {
		removed := s.events[0]
		s.eventBytes -= int64(len(removed.Data))
		s.events = s.events[1:]
		s.value.OutputTruncated = true
		if removed.Sequence > s.value.TruncatedBeforeSequence {
			s.value.TruncatedBeforeSequence = removed.Sequence
		}
	}
	close(s.changed)
	s.changed = make(chan struct{})
}

func (s *unixSession) write(data []byte, eof bool) (Execution, error) {
	if len(data) > maxInputBytes {
		return Execution{}, fmt.Errorf("execution input exceeds %d KiB", maxInputBytes>>10)
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.RLock()
	if s.value.Status != StatusRunning || s.stdin == nil || s.stdinClosed {
		s.mu.RUnlock()
		return Execution{}, ErrNotRunning
	}
	stdin, ptyMode := s.stdin, s.value.PTY
	s.mu.RUnlock()
	if len(data) > 0 {
		if _, err := stdin.Write(data); err != nil {
			return Execution{}, fmt.Errorf("write execution input: %w", err)
		}
	}
	if eof {
		if ptyMode {
			if _, err := stdin.Write([]byte{4}); err != nil {
				return Execution{}, fmt.Errorf("close PTY execution input: %w", err)
			}
		} else {
			if err := stdin.Close(); err != nil {
				return Execution{}, fmt.Errorf("close execution input: %w", err)
			}
			s.mu.Lock()
			s.stdinClosed = true
			s.mu.Unlock()
		}
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return cloneExecution(s.value), nil
}

func (s *unixSession) signal(requested Signal) (Execution, error) {
	s.mu.Lock()
	if s.value.Status != StatusRunning || s.process == nil {
		s.mu.Unlock()
		return Execution{}, ErrNotRunning
	}
	process := s.process
	s.advanceLocked(StreamState, nil, false)
	value := cloneExecution(s.value)
	s.mu.Unlock()
	if err := signalProcessGroup(process, unixSignal(requested)); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return Execution{}, fmt.Errorf("signal remote execution: %w", err)
	}
	return value, nil
}

func (s *unixSession) cancel() (Execution, error) {
	s.mu.Lock()
	if s.value.Status != StatusRunning || s.process == nil {
		value := cloneExecution(s.value)
		s.mu.Unlock()
		return value, nil
	}
	if !s.cancelRequested {
		s.cancelRequested = true
		s.advanceLocked(StreamState, nil, false)
	}
	process := s.process
	value := cloneExecution(s.value)
	s.mu.Unlock()
	terminateProcess(process, syscall.SIGTERM)
	return value, nil
}

func (s *unixSession) enforceTimeout(timeout time.Duration) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	<-timer.C
	s.mu.Lock()
	if s.value.Status != StatusRunning || s.process == nil {
		s.mu.Unlock()
		return
	}
	s.timedOut = true
	process := s.process
	s.advanceLocked(StreamState, nil, false)
	s.mu.Unlock()
	terminateProcess(process, syscall.SIGTERM)
}

func (s *unixSession) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.value.Status = StatusClosed
	s.value.CompletedAt = time.Now().UTC()
	process := s.process
	s.advanceLocked(StreamState, nil, true)
	s.mu.Unlock()
	if process != nil {
		terminateProcess(process, syscall.SIGHUP)
	}
}

func terminateProcess(process *os.Process, initial syscall.Signal) {
	_ = signalProcessGroup(process, initial)
	go func() {
		timer := time.NewTimer(terminationGrace)
		defer timer.Stop()
		<-timer.C
		_ = signalProcessGroup(process, syscall.SIGKILL)
	}()
}

func signalProcessGroup(process *os.Process, signal syscall.Signal) error {
	if process == nil {
		return os.ErrProcessDone
	}
	if err := syscall.Kill(-process.Pid, signal); err == nil || !errors.Is(err, syscall.ESRCH) {
		return err
	}
	return process.Signal(signal)
}

func unixSignal(value Signal) syscall.Signal {
	switch value {
	case SignalInterrupt:
		return syscall.SIGINT
	case SignalTerminate:
		return syscall.SIGTERM
	case SignalKill:
		return syscall.SIGKILL
	case SignalHangup:
		return syscall.SIGHUP
	default:
		return syscall.SIGTERM
	}
}

func processResult(err error) (int, string) {
	if err == nil {
		return 0, ""
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		return -1, ""
	}
	code := exit.ExitCode()
	if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return code, status.Signal().String()
	}
	return code, ""
}

func normalizeStartInput(input StartInput) (StartInput, string, error) {
	if len(input.Argv) == 0 || strings.TrimSpace(input.Argv[0]) == "" {
		return StartInput{}, "", errors.New("at least one non-empty argv value is required")
	}
	if len(input.Argv) > 256 {
		return StartInput{}, "", errors.New("execution argv exceeds 256 values")
	}
	for _, value := range input.Argv {
		if strings.ContainsRune(value, 0) {
			return StartInput{}, "", errors.New("execution argv cannot contain NUL bytes")
		}
	}
	info, err := os.Stat(input.WorkingDirectory)
	if err != nil || !info.IsDir() {
		return StartInput{}, "", errors.New("execution working directory is not a directory")
	}
	input.WorkingDirectory, err = filepath.EvalSymlinks(filepath.Clean(input.WorkingDirectory))
	if err != nil {
		return StartInput{}, "", err
	}
	input.Name = strings.TrimSpace(input.Name)
	if input.Name == "" {
		input.Name = filepath.Base(input.Argv[0])
	}
	if len(input.Name) > 80 {
		return StartInput{}, "", errors.New("execution name is too long")
	}
	if len(input.Stdin) > maxInputBytes {
		return StartInput{}, "", fmt.Errorf("initial execution input exceeds %d KiB", maxInputBytes>>10)
	}
	if input.Timeout < 0 || input.Timeout > 7*24*time.Hour {
		return StartInput{}, "", errors.New("execution timeout must be between zero and seven days")
	}
	if input.MaxOutputBytes == 0 {
		input.MaxOutputBytes = defaultMaxOutputBytes
	}
	if input.MaxOutputBytes < maxFrameBytes || input.MaxOutputBytes > maximumMaxOutputBytes {
		return StartInput{}, "", fmt.Errorf("max output must be between %d KiB and %d MiB", maxFrameBytes>>10, maximumMaxOutputBytes>>20)
	}
	if input.PTY {
		input.Columns, input.Rows, err = dimensions(input.Columns, input.Rows)
		if err != nil {
			return StartInput{}, "", err
		}
	} else {
		input.Columns, input.Rows = 0, 0
	}
	if len(input.Environment) > 128 {
		return StartInput{}, "", errors.New("execution environment exceeds 128 values")
	}
	for key, value := range input.Environment {
		if !validEnvironmentKey(key) || strings.ContainsRune(value, 0) {
			return StartInput{}, "", fmt.Errorf("invalid execution environment value %q", key)
		}
	}
	payload := struct {
		ProjectID, CardID, Name, WorkingDirectory string
		Argv                                      []string
		Environment                               [][2]string
		Stdin                                     []byte
		StdinEOF                                  bool
		Timeout                                   int64
		PTY                                       bool
		Columns, Rows                             int
		MaxOutput                                 int64
	}{
		ProjectID: input.ProjectID, CardID: input.CardID, Name: input.Name, WorkingDirectory: input.WorkingDirectory,
		Argv: input.Argv, Stdin: input.Stdin, StdinEOF: input.StdinEOF, Timeout: int64(input.Timeout),
		PTY: input.PTY, Columns: input.Columns, Rows: input.Rows, MaxOutput: input.MaxOutputBytes,
	}
	keys := make([]string, 0, len(input.Environment))
	for key := range input.Environment {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		payload.Environment = append(payload.Environment, [2]string{key, input.Environment[key]})
	}
	raw, _ := json.Marshal(payload)
	digest := sha256.Sum256(raw)
	return input, hex.EncodeToString(digest[:]), nil
}

func executionEnvironment(base []string, overrides map[string]string, ptyMode bool) []string {
	values := make(map[string]string, len(base)+len(overrides)+3)
	for _, entry := range base {
		if key, value, ok := strings.Cut(entry, "="); ok {
			values[key] = value
		}
	}
	for key, value := range overrides {
		values[key] = value
	}
	if ptyMode {
		if _, ok := values["TERM"]; !ok {
			values["TERM"] = "xterm-256color"
		}
		if _, ok := values["COLORTERM"]; !ok {
			values["COLORTERM"] = "truecolor"
		}
		values["TERM_PROGRAM"] = "Dieter"
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]string, 0, len(keys))
	for _, key := range keys {
		result = append(result, key+"="+values[key])
	}
	return result
}

func validEnvironmentKey(value string) bool {
	if value == "" {
		return false
	}
	for index, character := range value {
		if character == '_' || unicode.IsLetter(character) || index > 0 && unicode.IsDigit(character) {
			continue
		}
		return false
	}
	return true
}

func dimensions(columns, rows int) (int, int, error) {
	if columns == 0 {
		columns = defaultColumns
	}
	if rows == 0 {
		rows = defaultRows
	}
	if columns < minimumDimension || columns > maximumDimension || rows < minimumDimension || rows > maximumDimension {
		return 0, 0, fmt.Errorf("execution dimensions must be between %d and %d", minimumDimension, maximumDimension)
	}
	return columns, rows, nil
}

func randomID() string {
	value := make([]byte, 12)
	if _, err := io.ReadFull(rand.Reader, value); err != nil {
		return fmt.Sprintf("exec_%d", time.Now().UnixNano())
	}
	return "exec_" + hex.EncodeToString(value)
}

func cloneExecution(value Execution) Execution {
	value.Argv = append([]string(nil), value.Argv...)
	if value.ExitCode != nil {
		exitCode := *value.ExitCode
		value.ExitCode = &exitCode
	}
	return value
}

func cloneEvent(value Event) Event {
	value.Execution = cloneExecution(value.Execution)
	value.Data = append([]byte(nil), value.Data...)
	return value
}
