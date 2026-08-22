package terminal

import (
	"context"
	"errors"
	"time"
)

const (
	StatusRunning = "running"
	StatusExited  = "exited"
)

var (
	ErrNotFound     = errors.New("terminal not found")
	ErrNotRunning   = errors.New("terminal is not running")
	ErrLimitReached = errors.New("terminal session limit reached")
	ErrUnsupported  = errors.New("terminal sessions are not supported on this platform")
)

type Session struct {
	ID               string
	ProjectID        string
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

// Manager owns terminal processes independently from RPC and client lifetimes.
// Canceling WatchTerminal only removes that observer; a shell exits only when
// it exits itself, Close is called, or the daemon shuts down.
type Manager struct {
	backend backend
}

func New() *Manager { return &Manager{backend: newBackend()} }

func (m *Manager) List(projectID string) []Session           { return m.backend.List(projectID) }
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
