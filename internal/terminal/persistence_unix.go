//go:build !windows

package terminal

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	persistentTerminalPollInterval       = 250 * time.Millisecond
	persistentTerminalOutputPollInterval = 16 * time.Millisecond
	persistentTerminalStatusRetries      = 20
	persistentTerminalStatusRetryDelay   = 50 * time.Millisecond
)

var errPersistentSessionMissing = errors.New("persistent terminal session is missing")

// tmuxPersistence keeps the shell and its pseudo-terminal server outside the
// Dieter daemon process. Dieter still owns the session metadata and addresses
// a private named tmux server derived from one DIETER_HOME.
type tmuxPersistence struct {
	executable           string
	directory            string
	label                string
	supportsRawPasteFlag bool
}

type tmuxRecord struct {
	Version  int     `json:"version"`
	Name     string  `json:"tmux_name"`
	Terminal Session `json:"terminal"`
}

func newPersistentBackend(root string) backend {
	root = strings.TrimSpace(root)
	executable := findTmux()
	if root == "" || executable == "" {
		return newBackend()
	}
	directory := filepath.Join(root, "runtime", "terminals")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return newBackend()
	}
	_ = os.Chmod(directory, 0o700)
	persistence := &tmuxPersistence{
		executable:           executable,
		directory:            directory,
		label:                fmt.Sprintf("dieter-%x", sha256.Sum256([]byte(filepath.Clean(root))))[:31],
		supportsRawPasteFlag: tmuxSupportsRawPasteFlag(executable),
	}
	backend := &unixBackend{sessions: map[string]*unixSession{}, persistence: persistence}
	backend.restorePersistent()
	return backend
}

func findTmux() string {
	if value, err := exec.LookPath("tmux"); err == nil {
		return value
	}
	for _, candidate := range []string{"/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"} {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return ""
}

func tmuxSupportsRawPasteFlag(executable string) bool {
	output, err := exec.Command(executable, "list-commands", "paste-buffer").Output()
	if err != nil {
		return false
	}
	for _, field := range strings.Fields(string(output)) {
		if strings.HasPrefix(field, "[-") && strings.Contains(field, "S") {
			return true
		}
	}
	return false
}

func (b *unixBackend) createPersistent(
	input CreateInput, shell, workingDirectory, name string, columns, rows int,
) (Session, error) {
	id := randomID()
	tmuxName := "dieter_" + strings.TrimPrefix(id, "term_")
	if err := b.persistence.create(tmuxName, shell, workingDirectory, columns, rows); err != nil {
		return Session{}, err
	}
	now := time.Now().UTC()
	value := Session{
		ID: id, ProjectID: input.ProjectID, CardID: input.CardID, Name: name,
		Shell: filepath.Base(shell), WorkingDirectory: workingDirectory,
		Status: StatusRunning, Columns: columns, Rows: rows, CreatedAt: now, UpdatedAt: now,
	}
	if _, pid, _, err := b.persistence.status(tmuxName); err == nil {
		value.PID = pid
	}
	if err := b.persistence.pipe(tmuxName, id); err != nil {
		_ = b.persistence.close(tmuxName, id)
		return Session{}, err
	}
	if err := b.persistence.start(tmuxName); err != nil {
		_ = b.persistence.close(tmuxName, id)
		return Session{}, err
	}
	if err := b.persistence.save(tmuxName, value); err != nil {
		_ = b.persistence.close(tmuxName, id)
		return Session{}, err
	}
	session := &unixSession{
		value: value, changed: make(chan struct{}),
		durable: tmuxName, owner: b,
	}
	b.mu.Lock()
	if len(b.sessions) >= maxSessions {
		b.mu.Unlock()
		_ = b.persistence.close(tmuxName, id)
		return Session{}, ErrLimitReached
	}
	b.sessions[id] = session
	b.monitorWG.Add(2)
	b.mu.Unlock()
	b.startPersistentMonitors(session)
	return cloneSession(value), nil
}

func (b *unixBackend) restorePersistent() {
	entries, err := os.ReadDir(b.persistence.directory)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".json")
		record, err := b.persistence.load(filepath.Join(b.persistence.directory, entry.Name()))
		if err != nil || record.Terminal.ID == "" || record.Name == "" || len(b.sessions) >= maxSessions {
			if err != nil {
				_ = b.persistence.remove(id)
			}
			continue
		}
		running, pid, exitCode, statusErr := b.persistence.status(record.Name)
		if statusErr != nil {
			_ = b.persistence.remove(record.Terminal.ID)
			continue
		}
		value := record.Terminal
		value.PID = pid
		now := time.Now().UTC()
		value.UpdatedAt = now
		// Output sequences are memory cursors, while scrollback is persisted
		// independently. Start every restored manager above both the saved
		// cursor and any cursor issued by an earlier daemon lifetime.
		restartSequence := uint64(now.UnixNano())
		if value.Sequence < restartSequence {
			value.Sequence = restartSequence
		}
		if running {
			value.Status = StatusRunning
			value.ExitCode = nil
		} else {
			value.Status = StatusExited
			value.PID = 0
			value.ExitCode = &exitCode
		}
		session := &unixSession{
			value: value, changed: make(chan struct{}), durable: record.Name, owner: b,
		}
		if screen, offset, identity, captureErr := b.persistence.logBaseline(value.ID); captureErr == nil {
			session.logOffset = offset
			session.logIdentity = identity
			session.resetLocked(screen)
		} else {
			session.resetLocked(nil)
		}
		if running {
			if pipeErr := b.persistence.pipe(record.Name, value.ID); pipeErr != nil {
				continue
			}
			b.monitorWG.Add(2)
			b.startPersistentMonitors(session)
		}
		b.sessions[value.ID] = session
		_ = b.persistence.save(record.Name, session.value)
	}
}

// startPersistentMonitors starts the two loops after their WaitGroup slots
// have been reserved. Callers reserve while holding the session-map lock when
// creation can race with shutdown.
func (b *unixBackend) startPersistentMonitors(session *unixSession) {
	go func() {
		defer b.monitorWG.Done()
		b.monitorPersistent(session)
	}()
	go func() {
		defer b.monitorWG.Done()
		b.monitorPersistentOutput(session)
	}()
}

func (b *unixBackend) monitorPersistentOutput(session *unixSession) {
	ticker := time.NewTicker(persistentTerminalOutputPollInterval)
	defer ticker.Stop()
	for range ticker.C {
		session.mu.RLock()
		if session.closed {
			session.mu.RUnlock()
			return
		}
		id, offset, identity := session.value.ID, session.logOffset, session.logIdentity
		session.mu.RUnlock()
		data, nextOffset, nextIdentity, reset, err := b.persistence.readLog(id, offset, identity)
		if err != nil || (len(data) == 0 && !reset) {
			continue
		}
		session.mu.Lock()
		if session.closed {
			session.mu.Unlock()
			return
		}
		session.logOffset = nextOffset
		session.logIdentity = nextIdentity
		if reset {
			session.resetLocked(data)
		} else {
			session.advanceLocked(data)
		}
		session.mu.Unlock()
	}
}

func (b *unixBackend) monitorPersistent(session *unixSession) {
	ticker := time.NewTicker(persistentTerminalPollInterval)
	defer ticker.Stop()
	for range ticker.C {
		session.mu.RLock()
		closed, name := session.closed, session.durable
		session.mu.RUnlock()
		if closed {
			return
		}
		running, pid, exitCode, err := b.persistence.status(name)
		if err != nil {
			if !errors.Is(err, errPersistentSessionMissing) {
				// A short-lived tmux client failure must not turn a live shell into
				// a permanently exited Dieter session. The next poll can recover.
				continue
			}
			running, pid, exitCode = false, 0, -1
		}
		session.mu.Lock()
		if session.closed {
			session.mu.Unlock()
			return
		}
		changed := session.value.PID != pid
		if running {
			if session.value.Status != StatusRunning || session.value.ExitCode != nil {
				changed = true
			}
			session.value.Status = StatusRunning
			session.value.PID = pid
			session.value.ExitCode = nil
		} else if session.value.Status == StatusRunning {
			session.value.Status = StatusExited
			session.value.PID = 0
			session.value.ExitCode = &exitCode
			changed = true
		}
		if changed {
			session.advanceLocked(nil)
		}
		value := cloneSession(session.value)
		session.mu.Unlock()
		if changed {
			_ = b.persistence.save(name, value)
		}
		if !running {
			return
		}
	}
}

func (p *tmuxPersistence) create(name, shell, directory string, columns, rows int) error {
	// Hold the requested shell behind one line of PTY input. This lets Dieter
	// install pipe-pane first, so the shell's initial prompt is never lost.
	command := persistentServerCommand(
		p.executable, "-L", p.label, "new-session", "-d", "-s", name,
		"-x", strconv.Itoa(columns), "-y", strconv.Itoa(rows), "-c", directory,
		"/bin/sh", "-c", `IFS= read -r _; exec "$1" -l`, "dieter-terminal", shell,
	)
	command.Env = terminalEnvironment(os.Environ())
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("start persistent terminal: %s: %w", strings.TrimSpace(string(output)), err)
	}
	for _, option := range [][]string{
		{"set-option", "-t", name, "remain-on-exit", "on"},
		{"set-option", "-t", name, "status", "off"},
		{"set-option", "-t", name, "prefix", "None"},
		{"set-option", "-t", name, "prefix2", "None"},
		{"set-option", "-t", name, "escape-time", "0"},
	} {
		if output, err := p.run(option...); err != nil {
			_ = p.kill(name)
			return fmt.Errorf("configure persistent terminal: %s: %w", strings.TrimSpace(string(output)), err)
		}
	}
	_, _ = p.run("set-option", "-g", "history-limit", "20000")
	return nil
}

func (p *tmuxPersistence) start(name string) error {
	output, err := p.run("send-keys", "-t", name, "Enter")
	if err != nil {
		return fmt.Errorf("start persistent terminal shell: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (p *tmuxPersistence) resize(name string, columns, rows int) error {
	output, err := p.run("resize-window", "-t", name, "-x", strconv.Itoa(columns), "-y", strconv.Itoa(rows))
	if err != nil {
		return fmt.Errorf("resize persistent terminal: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (p *tmuxPersistence) pipe(name, id string) error {
	logPath, chunkPath, nextPath := p.logPath(id), p.logPath(id)+".chunk", p.logPath(id)+".next"
	if _, err := os.Stat(logPath); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(logPath, nil, 0o600); err != nil {
			return err
		}
	}
	quotedLog, quotedChunk, quotedNext := shellQuote(logPath), shellQuote(chunkPath), shellQuote(nextPath)
	script := fmt.Sprintf(`
	umask 077
while :; do
  : > %s
  dd bs=%d count=1 of=%s 2>/dev/null
  test -s %s || break
  cat %s >> %s
  size=$(wc -c < %s)
  if test "$size" -gt %d; then
    tail -c %d %s > %s && mv -f %s %s
  fi
done
rm -f %s %s
`, quotedChunk, maxFrameBytes, quotedChunk, quotedChunk, quotedChunk, quotedLog, quotedLog,
		maxScrollbackBytes, maxScrollbackBytes, quotedLog, quotedNext, quotedNext, quotedLog,
		quotedChunk, quotedNext)
	output, err := p.run("pipe-pane", "-O", "-t", name, script)
	if err != nil {
		return fmt.Errorf("capture persistent terminal output: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (p *tmuxPersistence) logBaseline(id string) ([]byte, int64, uint64, error) {
	info, err := os.Stat(p.logPath(id))
	if err != nil {
		return nil, 0, 0, err
	}
	identity := fileIdentity(info)
	start := max(int64(0), info.Size()-maxScrollbackBytes)
	file, err := os.Open(p.logPath(id))
	if err != nil {
		return nil, 0, 0, err
	}
	defer file.Close()
	if _, err := file.Seek(start, io.SeekStart); err != nil {
		return nil, 0, 0, err
	}
	data, err := io.ReadAll(io.LimitReader(file, maxScrollbackBytes))
	return data, start + int64(len(data)), identity, err
}

func (p *tmuxPersistence) readLog(
	id string, offset int64, identity uint64,
) ([]byte, int64, uint64, bool, error) {
	info, err := os.Stat(p.logPath(id))
	if err != nil {
		return nil, offset, identity, false, err
	}
	nextIdentity := fileIdentity(info)
	if identity == 0 || identity != nextIdentity || info.Size() < offset {
		data, nextOffset, value, err := p.logBaseline(id)
		return data, nextOffset, value, true, err
	}
	if info.Size() == offset {
		return nil, offset, identity, false, nil
	}
	file, err := os.Open(p.logPath(id))
	if err != nil {
		return nil, offset, identity, false, err
	}
	defer file.Close()
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil, offset, identity, false, err
	}
	data, err := io.ReadAll(io.LimitReader(file, maxFrameBytes))
	return data, offset + int64(len(data)), identity, false, err
}

func fileIdentity(info os.FileInfo) uint64 {
	if value, ok := info.Sys().(*syscall.Stat_t); ok {
		return value.Ino
	}
	return uint64(info.ModTime().UnixNano())
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func (p *tmuxPersistence) write(name, id string, data []byte) error {
	buffer := "input_" + strings.TrimPrefix(id, "term_")
	command := exec.Command(p.executable, "-L", p.label, "load-buffer", "-b", buffer, "-")
	command.Env = terminalEnvironment(os.Environ())
	command.Stdin = bytes.NewReader(data)
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("buffer persistent terminal input: %s: %w", strings.TrimSpace(string(output)), err)
	}
	arguments := []string{"paste-buffer", "-d"}
	if p.supportsRawPasteFlag {
		// tmux 3.7 sanitizes control bytes such as DEL, ESC and Ctrl-C by
		// default. Terminal input is not clipboard text: those bytes are the
		// keyboard protocol and must reach the PTY unchanged. Older tmux
		// releases did not sanitize and do not recognize -S.
		arguments = append(arguments, "-S")
	}
	arguments = append(arguments, "-b", buffer, "-t", name)
	output, err := p.run(arguments...)
	if err != nil {
		return fmt.Errorf("write persistent terminal: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (p *tmuxPersistence) status(name string) (bool, int64, int, error) {
	var output []byte
	var statusErr error
	for attempt := 0; attempt < persistentTerminalStatusRetries; attempt++ {
		output, statusErr = p.run(
			"display-message", "-p", "-t", name,
			"#{pane_dead}|#{pane_dead_status}|#{pane_pid}",
		)
		if statusErr == nil {
			parts := strings.Split(strings.TrimSpace(string(output)), "|")
			if len(parts) == 3 {
				pid, _ := strconv.ParseInt(parts[2], 10, 64)
				if parts[0] == "0" {
					return true, pid, 0, nil
				}
				exitCode, err := strconv.Atoi(parts[1])
				if err != nil {
					exitCode = -1
				}
				return false, 0, exitCode, nil
			}
			statusErr = fmt.Errorf("invalid persistent terminal status %q", string(output))
		}
		if attempt+1 < persistentTerminalStatusRetries {
			time.Sleep(persistentTerminalStatusRetryDelay)
		}
	}
	message := strings.ToLower(strings.TrimSpace(string(output)))
	if strings.Contains(message, "can't find session") || strings.Contains(message, "no server running") ||
		strings.Contains(message, "error connecting to") {
		return false, 0, -1, fmt.Errorf("%w: %s", errPersistentSessionMissing, message)
	}
	return false, 0, -1, fmt.Errorf("query persistent terminal status: %w", statusErr)
}

func (p *tmuxPersistence) close(name, id string) error {
	return errors.Join(p.kill(name), p.remove(id))
}

func (p *tmuxPersistence) remove(id string) error {
	var result error
	for _, path := range []string{
		p.recordPath(id), p.logPath(id), p.logPath(id) + ".chunk", p.logPath(id) + ".next",
	} {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			result = errors.Join(result, err)
		}
	}
	return result
}

func (p *tmuxPersistence) kill(name string) error {
	output, err := p.run("kill-session", "-t", name)
	if err != nil && !strings.Contains(string(output), "can't find session") {
		return fmt.Errorf("close persistent terminal: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (p *tmuxPersistence) load(path string) (tmuxRecord, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return tmuxRecord{}, err
	}
	var value tmuxRecord
	if err := json.Unmarshal(data, &value); err != nil {
		return tmuxRecord{}, err
	}
	if value.Version != 1 || filepath.Base(path) != value.Terminal.ID+".json" {
		return tmuxRecord{}, errors.New("invalid persistent terminal metadata")
	}
	return value, nil
}

func (p *tmuxPersistence) save(name string, value Session) error {
	data, err := json.MarshalIndent(tmuxRecord{Version: 1, Name: name, Terminal: cloneSession(value)}, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(p.directory, ".terminal-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err == nil {
		_, err = temporary.Write(append(data, '\n'))
	}
	if err == nil {
		err = temporary.Sync()
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(temporaryPath, p.recordPath(value.ID))
}

func (p *tmuxPersistence) recordPath(id string) string {
	return filepath.Join(p.directory, id+".json")
}

func (p *tmuxPersistence) logPath(id string) string {
	return filepath.Join(p.directory, id+".scrollback")
}

func (p *tmuxPersistence) run(arguments ...string) ([]byte, error) {
	command := exec.Command(p.executable, append([]string{"-L", p.label}, arguments...)...)
	command.Env = terminalEnvironment(os.Environ())
	return command.CombinedOutput()
}
