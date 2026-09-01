package remoteexec

import (
	"context"
	"errors"
	"time"
)

const (
	StatusRunning  = "running"
	StatusExited   = "exited"
	StatusCanceled = "canceled"
	StatusTimedOut = "timed_out"
	StatusClosed   = "closed"
)

type Stream int

const (
	StreamState Stream = iota
	StreamStdout
	StreamStderr
	StreamPTY
)

type Signal int

const (
	SignalInterrupt Signal = iota + 1
	SignalTerminate
	SignalKill
	SignalHangup
)

var (
	ErrNotFound            = errors.New("execution not found")
	ErrNotRunning          = errors.New("execution is not running")
	ErrLimitReached        = errors.New("remote execution limit reached")
	ErrUnsupported         = errors.New("remote executions are not supported on this platform")
	ErrIdempotencyConflict = errors.New("execution idempotency key was reused with a different request")
)

type Execution struct {
	ID                      string
	ProjectID               string
	CardID                  string
	Name                    string
	Argv                    []string
	WorkingDirectory        string
	Status                  string
	PID                     int64
	PTY                     bool
	Columns                 int
	Rows                    int
	Sequence                uint64
	CreatedAt               time.Time
	StartedAt               time.Time
	UpdatedAt               time.Time
	CompletedAt             time.Time
	ExitCode                *int
	ExitSignal              string
	Error                   string
	IdempotencyKey          string
	StdoutBytes             uint64
	StderrBytes             uint64
	OutputTruncated         bool
	TruncatedBeforeSequence uint64
	Timeout                 time.Duration
}

type Event struct {
	Execution Execution
	Sequence  uint64
	Stream    Stream
	Data      []byte
	Reset     bool
	Heartbeat bool
	EOF       bool
}

type StartInput struct {
	ProjectID        string
	CardID           string
	Name             string
	Argv             []string
	WorkingDirectory string
	Environment      map[string]string
	Stdin            []byte
	StdinEOF         bool
	Timeout          time.Duration
	IdempotencyKey   string
	PTY              bool
	Columns          int
	Rows             int
	MaxOutputBytes   int64
}

type backend interface {
	List(projectID, cardID, status string) []Execution
	Get(string) (Execution, error)
	Start(StartInput) (Execution, error)
	Events(string, uint64) ([]Event, <-chan struct{}, error)
	Write(string, []byte, bool) (Execution, error)
	Signal(string, Signal) (Execution, error)
	Resize(string, int, int) (Execution, error)
	Cancel(string) (Execution, error)
	Close(string) error
	Shutdown(context.Context)
}

// Manager owns command processes independently from RPC and client lifetimes.
// Canceling a watch only removes that observer; an execution continues until
// it exits, is canceled, times out, is closed, or the daemon shuts down.
type Manager struct{ backend backend }

func New() *Manager { return &Manager{backend: newBackend()} }

func (m *Manager) List(projectID, cardID, status string) []Execution {
	return m.backend.List(projectID, cardID, status)
}
func (m *Manager) Get(id string) (Execution, error) { return m.backend.Get(id) }
func (m *Manager) Start(input StartInput) (Execution, error) {
	return m.backend.Start(input)
}
func (m *Manager) Events(id string, after uint64) ([]Event, <-chan struct{}, error) {
	return m.backend.Events(id, after)
}
func (m *Manager) Write(id string, data []byte, eof bool) (Execution, error) {
	return m.backend.Write(id, data, eof)
}
func (m *Manager) Signal(id string, signal Signal) (Execution, error) {
	return m.backend.Signal(id, signal)
}
func (m *Manager) Resize(id string, columns, rows int) (Execution, error) {
	return m.backend.Resize(id, columns, rows)
}
func (m *Manager) Cancel(id string) (Execution, error) { return m.backend.Cancel(id) }
func (m *Manager) Close(id string) error               { return m.backend.Close(id) }
func (m *Manager) Shutdown(ctx context.Context)        { m.backend.Shutdown(ctx) }
