// Package claudedesign connects Claude Code turns on this daemon host to Claude
// Design (claude.ai/design).
//
// Claude Code owns everything account related. Its pinned CLI reports whether
// Claude Design is available, runs the design sign-in and stores the resulting
// credential in its own secure storage, and grants or revokes the Claude
// account's durable agent access to Design projects. Dieter only records
// whether its own Claude Code turns on this machine may use the Claude Design
// tools. Nothing here is replicated or sent to the gateway.
package claudedesign

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/dbpprt/dieter/internal/store"
)

// Status is the host's Claude Design state as reported by Claude Code.
type Status struct {
	RuntimeReady bool   `json:"runtimeReady"`
	Version      string `json:"version"`
	Available    bool   `json:"available"`
	SignedIn     bool   `json:"signedIn"`
	CanSignIn    bool   `json:"canSignIn"`
	Reason       string `json:"reason"`
}

// Event is one step of a sign-in. Kind is started, preparing, pages or done;
// the done event carries the refreshed snapshot.
type Event struct {
	Kind        string
	SignInID    string
	URL         string
	ManualURL   string
	ManualFirst bool
	OK          bool
	Message     string
	Snapshot    *Snapshot
}

// Host runs Claude Code's Claude Design commands on the daemon host.
type Host interface {
	Status(context.Context) (Status, error)
	// SignIn runs one sign-in until Claude Code reports done or ctx ends. It
	// forwards authorization codes from codes to Claude Code.
	SignIn(ctx context.Context, codes <-chan string, event func(Event) error) error
	// SetGrant grants or revokes the Claude account's agent access to Design
	// projects and returns Claude Code's confirmation.
	SetGrant(ctx context.Context, granted bool) (string, error)
}

// Snapshot combines the host status with Dieter's machine-local access setting.
type Snapshot struct {
	Status
	AccessEnabled   bool
	AccessUpdatedAt string
	SignInActive    bool
}

var (
	ErrInvalidCode  = errors.New("the authorization code must be 1 to 4096 printable characters")
	ErrNoSignIn     = errors.New("that Claude Design sign-in is no longer running; start a new sign-in")
	ErrCodePending  = errors.New("an authorization code is already being checked")
	ErrUnavailable  = errors.New("Claude Design is unavailable on this machine")
	statusCacheTTL  = 3 * time.Second
	maxCodeLength   = 4096
	maxSignInLength = 6 * time.Minute
)

// FailedPrecondition carries a user-facing reason from Claude Code.
type FailedPrecondition struct{ Message string }

func (err FailedPrecondition) Error() string { return err.Message }

type activeSignIn struct {
	id     string
	codes  chan string
	cancel context.CancelFunc
	// events reaches the stream that started the sign-in; closed after done.
	events chan Event
}

type Manager struct {
	host  Host
	store *store.Store

	statusMu sync.Mutex
	cached   Status
	cachedAt time.Time

	accessMu sync.Mutex

	mu     sync.Mutex
	signIn *activeSignIn
}

func New(host Host, data *store.Store) *Manager {
	return &Manager{host: host, store: data}
}

// AccessEnabled reports Dieter's machine-local setting for Claude Code turns.
func (m *Manager) AccessEnabled() bool {
	access, err := m.store.ClaudeDesignAccess()
	return err == nil && access.Enabled
}

func (m *Manager) Status(ctx context.Context) (Snapshot, error) {
	status, err := m.hostStatus(ctx, false)
	if err != nil {
		return Snapshot{}, err
	}
	return m.snapshot(status)
}

func (m *Manager) snapshot(status Status) (Snapshot, error) {
	access, err := m.store.ClaudeDesignAccess()
	if err != nil {
		return Snapshot{}, err
	}
	m.mu.Lock()
	active := m.signIn != nil
	m.mu.Unlock()
	return Snapshot{Status: status, AccessEnabled: access.Enabled, AccessUpdatedAt: access.UpdatedAt, SignInActive: active}, nil
}

func (m *Manager) hostStatus(ctx context.Context, refresh bool) (Status, error) {
	m.statusMu.Lock()
	defer m.statusMu.Unlock()
	if !refresh && !m.cachedAt.IsZero() && time.Since(m.cachedAt) < statusCacheTTL {
		return m.cached, nil
	}
	status, err := m.host.Status(ctx)
	if err != nil {
		return Status{}, err
	}
	m.cached, m.cachedAt = status, time.Now()
	return status, nil
}

func (m *Manager) invalidate() {
	m.statusMu.Lock()
	m.cachedAt = time.Time{}
	m.statusMu.Unlock()
}

// SignIn starts a sign-in and relays its events until it finishes or ctx
// ends. The sign-in itself outlives ctx: a phone that leaves for the browser
// may lose its stream, and the code it brings back must still complete the
// sign-in. It ends when Claude Code finishes, after about five minutes, or
// when a newer sign-in replaces it. The last relayed event has Kind done.
func (m *Manager) SignIn(ctx context.Context, send func(Event) error) error {
	current, err := m.start()
	if err != nil {
		return err
	}
	for {
		select {
		case event, ok := <-current.events:
			if !ok {
				return nil
			}
			if err := send(event); err != nil {
				return err
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (m *Manager) start() (*activeSignIn, error) {
	id, err := randomID()
	if err != nil {
		return nil, err
	}
	signInCtx, cancel := context.WithTimeout(context.Background(), maxSignInLength)
	current := &activeSignIn{id: id, codes: make(chan string, 1), cancel: cancel, events: make(chan Event, maxEvents+2)}
	m.mu.Lock()
	if previous := m.signIn; previous != nil {
		previous.cancel()
	}
	m.signIn = current
	m.mu.Unlock()
	current.events <- Event{Kind: "started", SignInID: id}
	go m.run(signInCtx, current)
	return current, nil
}

// run drives one sign-in. Events beyond the bounded buffer of a stream that
// stopped reading are dropped; the sign-in continues regardless.
func (m *Manager) run(ctx context.Context, current *activeSignIn) {
	defer current.cancel()
	deliver := func(event Event) {
		event.SignInID = current.id
		select {
		case current.events <- event:
		default:
		}
	}
	var final *Event
	runErr := m.host.SignIn(ctx, current.codes, func(event Event) error {
		if event.Kind == "done" {
			final = &event
			return nil
		}
		deliver(event)
		return nil
	})
	if final == nil {
		message := "The Claude Design sign-in ended without a result."
		switch {
		case errors.Is(ctx.Err(), context.Canceled):
			message = "A newer Claude Design sign-in replaced this one."
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			message = "The Claude Design sign-in timed out. Try again."
		case runErr != nil:
			message = fmt.Sprintf("The Claude Design sign-in failed: %v", runErr)
		}
		final = &Event{Kind: "done", Message: message}
	}
	m.mu.Lock()
	if m.signIn == current {
		m.signIn = nil
	}
	m.mu.Unlock()
	m.invalidate()
	statusCtx, cancel := context.WithTimeout(context.Background(), statusTimeout)
	defer cancel()
	status, statusErr := m.hostStatus(statusCtx, true)
	if statusErr != nil {
		status = Status{Reason: statusErr.Error()}
	}
	if snapshot, err := m.snapshot(status); err == nil {
		final.Snapshot = &snapshot
	}
	deliver(*final)
	close(current.events)
}

// Close ends a running sign-in, e.g. when the daemon stops.
func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.signIn != nil {
		m.signIn.cancel()
	}
}

// SubmitCode forwards a manual authorization code to the running sign-in.
func (m *Manager) SubmitCode(id, code string) error {
	code = strings.TrimSpace(code)
	if code == "" || len(code) > maxCodeLength || strings.IndexFunc(code, func(r rune) bool { return unicode.IsControl(r) }) >= 0 {
		return ErrInvalidCode
	}
	m.mu.Lock()
	current := m.signIn
	m.mu.Unlock()
	if current == nil || current.id != strings.TrimSpace(id) {
		return ErrNoSignIn
	}
	select {
	case current.codes <- code:
		return nil
	default:
		return ErrCodePending
	}
}

// SetAccess changes whether Claude Code turns on this machine may use Claude
// Design. Enabling first grants the Claude account's agent access, which
// headless turns cannot confirm interactively. Disabling takes effect locally
// first; revoke additionally withdraws that account-wide grant.
func (m *Manager) SetAccess(ctx context.Context, enabled, revoke bool) (Snapshot, error) {
	m.accessMu.Lock()
	defer m.accessMu.Unlock()
	if enabled {
		status, err := m.hostStatus(ctx, true)
		if err != nil {
			return Snapshot{}, err
		}
		if !status.Available {
			reason := status.Reason
			if reason == "" {
				reason = ErrUnavailable.Error()
			}
			return Snapshot{}, FailedPrecondition{Message: reason}
		}
		if _, err := m.host.SetGrant(ctx, true); err != nil {
			return Snapshot{}, err
		}
		if _, err := m.store.SetClaudeDesignAccess(true); err != nil {
			return Snapshot{}, err
		}
		return m.Status(ctx)
	}
	if _, err := m.store.SetClaudeDesignAccess(false); err != nil {
		return Snapshot{}, err
	}
	if revoke {
		if _, err := m.host.SetGrant(ctx, false); err != nil {
			return Snapshot{}, err
		}
		m.invalidate()
	}
	return m.Status(ctx)
}

func randomID() (string, error) {
	buffer := make([]byte, 12)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return "cds_" + hex.EncodeToString(buffer), nil
}

type unavailableHost struct{ reason string }

// Unavailable reports Claude Design as unavailable, for daemons without the
// pinned harness runtime.
func Unavailable(reason string) Host { return unavailableHost{reason: reason} }

func (h unavailableHost) Status(context.Context) (Status, error) {
	return Status{Reason: h.reason}, nil
}

func (h unavailableHost) SignIn(context.Context, <-chan string, func(Event) error) error {
	return FailedPrecondition{Message: h.reason}
}

func (h unavailableHost) SetGrant(context.Context, bool) (string, error) {
	return "", FailedPrecondition{Message: h.reason}
}
