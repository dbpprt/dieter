package terminal

import (
	"context"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

const (
	StatusRunning = "running"
	StatusExited  = "exited"
)

var (
	ErrNotFound     = fault.New(fault.NotFound, "terminal not found")
	ErrNotRunning   = fault.New(fault.FailedPrecondition, "terminal is not running")
	ErrLimitReached = fault.New(fault.ResourceExhausted, "terminal session limit reached")
	ErrUnsupported  = fault.New(fault.Unimplemented, "terminal sessions are not supported on this platform")
)

type Session struct {
	ID               string
	ProjectID        string
	CardID           string
	Name             string
	Shell            string
	WorkingDirectory string
	Status           string
	PID              int64
	Columns          int
	Rows             int
	Sequence         uint64
	CreatedAt        time.Time
	UpdatedAt        time.Time
	ExitCode         *int
}

type Frame struct {
	Session   Session
	Sequence  uint64
	Data      []byte
	Reset     bool
	Heartbeat bool
}

type CreateInput struct {
	ProjectID        string
	CardID           string
	Name             string
	Shell            string
	WorkingDirectory string
	Columns          int
	Rows             int
}

type backend interface {
	List(projectID string) []Session
	Get(string) (Session, error)
	Create(CreateInput) (Session, error)
	Frames(string, uint64) ([]Frame, <-chan struct{}, error)
	Write(string, []byte) (Session, error)
	Resize(string, int, int) (Session, error)
	Rename(string, string) (Session, error)
	Close(string) error
	Shutdown(context.Context)
}

type durableBackend interface {
	Durable() bool
}

// Manager owns terminal processes independently from RPC and client lifetimes.
// Canceling WatchTerminal only removes that observer; a shell exits only when
// it exits itself or Close is called. Persistent managers detach from their
// shells during daemon shutdown and reattach when the daemon starts again.
type Manager struct {
	backend backend
}

// Options are host settings of terminal shells.
type Options struct {
	// Shell is the default shell when a request names none (SHELL).
	Shell string
	// SystemdScope starts durable tmux servers in their own systemd user scope
	// so a systemd-managed daemon's restart cannot reap them
	// (DIETER_SERVICE_MANAGER=systemd-user).
	SystemdScope bool
}

func New(options Options) *Manager { return &Manager{backend: newBackend(options)} }

// NewPersistent uses a durable host terminal backend when one is available and
// falls back to the in-process PTY backend otherwise. All metadata remains
// inside root.
func NewPersistent(root string, options Options) *Manager {
	return &Manager{backend: newPersistentBackend(root, options)}
}

func (m *Manager) Durable() bool {
	value, ok := m.backend.(durableBackend)
	return ok && value.Durable()
}

func (m *Manager) List(projectID string) []Session { return m.backend.List(projectID) }
func (m *Manager) ListScoped(projectID, cardID string) []Session {
	values := m.backend.List(projectID)
	if cardID == "" {
		return values
	}
	result := values[:0]
	for _, value := range values {
		if value.CardID == cardID {
			result = append(result, value)
		}
	}
	return result
}
func (m *Manager) Get(id string) (Session, error)            { return m.backend.Get(id) }
func (m *Manager) Create(input CreateInput) (Session, error) { return m.backend.Create(input) }
func (m *Manager) Frames(id string, after uint64) ([]Frame, <-chan struct{}, error) {
	return m.backend.Frames(id, after)
}
func (m *Manager) Write(id string, data []byte) (Session, error) { return m.backend.Write(id, data) }
func (m *Manager) Resize(id string, columns, rows int) (Session, error) {
	return m.backend.Resize(id, columns, rows)
}
func (m *Manager) Rename(id, name string) (Session, error) { return m.backend.Rename(id, name) }
func (m *Manager) Close(id string) error                   { return m.backend.Close(id) }
func (m *Manager) Shutdown(ctx context.Context)            { m.backend.Shutdown(ctx) }
