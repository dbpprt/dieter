// Package accounts manages the Claude and ChatGPT accounts agent turns run on:
// the replicated account records, each machine's login through the
// provider's own tool (Claude Code, Codex, Sign in with ChatGPT), the
// per-account homes those tools keep their credentials in, turn credentials,
// and plan usage. Dieter never reads Claude.ai credentials; Claude Code owns
// each login in a per-account config directory. Credentials never leave the
// machine that signed in and never enter replicated records.
package accounts

import (
	"context"
	"crypto/rand"
	"encoding/base32"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
)

// Providers, methods, login states, flows, phases and challenge inputs.
const (
	ProviderClaude  = schema.ProviderClaude
	ProviderChatGPT = schema.ProviderChatGPT

	MethodClaudeCode  = schema.MethodClaudeCode
	MethodCodex       = schema.MethodCodex
	MethodSIWC        = schema.MethodSIWC
	MethodHost        = schema.MethodHost
	MethodEnvironment = schema.MethodEnvironment

	StateSignedIn  = schema.LoginSignedIn
	StateSignedOut = schema.LoginSignedOut
	StateExpired   = schema.LoginExpired
	StateFailed    = schema.LoginFailed

	FlowPasteCode  = "paste_code"
	FlowDeviceCode = "device_code"
	FlowBrowser    = "browser"

	PhaseStarting   = "starting"
	PhaseWaiting    = "waiting"
	PhaseCompleting = "completing"
	PhaseSucceeded  = "succeeded"
	PhaseFailed     = "failed"
	PhaseCanceled   = "canceled"

	ExpectsCode     = "code"
	ExpectsNone     = "none"
	ExpectsCallback = "callback"

	// ErrorIdentityMismatch is a sign-in as someone other than the account's
	// bound identity.
	ErrorIdentityMismatch = "identity_mismatch"
)

// Identity, usage and token totals are the replicated JSON shapes.
type (
	Identity     = schema.ProviderIdentity
	Usage        = schema.ProviderUsage
	UsageWindow  = schema.ProviderUsageWindow
	Credits      = schema.ProviderCredits
	Spend        = schema.ProviderSpend
	ResetCredits = schema.ProviderResetCredits
	TokenTotals  = schema.ProviderTokenTotals
	TokenUsage   = schema.ProviderTokenUsage
)

// Account is an account record joined with every machine's login and the
// provider's default.
type Account struct {
	ID, Provider, Label, Method string
	Identity                    Identity
	IncludeInSummary, IsDefault bool
	// OMPAccess lets Oh My Pi turns use this Claude login.
	OMPAccess bool
	Logins    []MachineLogin
	// Usage is the freshest usage any machine observed.
	Usage *Usage
	// DieterTokens sums Dieter's own turns over machines.
	DieterTokens         *TokenUsage
	CreatedAt, CreatedBy string
}

// MachineLogin is one machine's login of an account.
type MachineLogin struct {
	DaemonID, State, Method             string
	Identity                            Identity
	VerifiedAt, ErrorCode, ErrorMessage string
	Usage                               *Usage
	DieterTokens                        *TokenUsage
}

// Login is a running or finished sign-in on this machine.
type Login struct {
	ID, AccountID, DaemonID, Flow, Phase string
	Challenge                            Challenge
	Identity                             Identity
	ErrorCode, ErrorMessage, UpdatedAt   string
}

// Challenge is what the person signing in needs: a URL to open, the variant
// that redirects to this machine's loopback, a device code, and which input
// completes it (code, none or callback).
type Challenge struct {
	OpenURL, LocalURL string
	CallbackPort      int
	UserCode          string
	ExpiresAt         string
	Expects           string
}

// CreateInput adds an account. Method defaults to claude-code or codex;
// AccountID optionally makes a retry idempotent.
type CreateInput struct {
	Provider, Label, Method, AccountID string
}

// TurnAuth is what a Claude Code or Codex turn on an account needs.
type TurnAuth struct {
	// AccountID is the resolved account.
	AccountID string
	// Env is appended to the worker environment; empty values mask host keys.
	Env map[string]string
	// Auth is the adapter's auth object ({} for Claude logins).
	Auth map[string]string
}

// Options configures a Service.
type Options struct {
	Store *store.Store
	// DaemonID is this machine's daemon ID, "" while it has none (then
	// account-wide writes fail with FailedPrecondition). Nil reads the
	// replica's identity without ever creating one.
	DaemonID func() string
	// RuntimeDir stages the harness runtime (Claude Code and Codex
	// executables, usage-claude.mjs).
	RuntimeDir func(context.Context) (string, error)
	// HostHome is the operator's home directory (~/.claude, ~/.codex).
	HostHome string
	// Environment is the daemon environment subset provider tools and
	// environment accounts use: PATH, USER, LANG, TMPDIR, proxy settings,
	// CLAUDE_CONFIG_DIR and CODEX_HOME of host logins, and the API keys
	// ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, OPENAI_API_KEY, CODEX_API_KEY
	// (with ANTHROPIC_BASE_URL and OPENAI_BASE_URL).
	Environment map[string]string
	// Backend runs the provider tools; nil runs the real ones.
	Backend Backend
	Clock   func() time.Time
	Logger  *slog.Logger
	// HostID is this host's Sign in with ChatGPT ext_agent_host_id. Nil uses a
	// urn:uuid persisted under DIETER_HOME/provider-accounts.
	HostID func() string
	// MachineName names this machine in messages ("Work isn't signed in on
	// box"). Nil uses the host name.
	MachineName func() string
	// Roster reports the daemons of the device roster; login records of other
	// daemons are ignored. Nil counts every login record.
	Roster func() map[string]bool
}

// Service is the accounts engine of one daemon.
type Service struct {
	opts    Options
	store   *store.Store
	backend Backend
	now     func() time.Time
	log     *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc
	// running counts session and notification goroutines, which Shutdown
	// waits for.
	running sync.WaitGroup

	mu       sync.Mutex
	sessions map[string]*session
	locks    map[string]*sync.Mutex
	shutdown bool
	bg       background

	// loginMu serializes read-modify-write of this machine's login records.
	loginMu sync.Mutex
	// fileMu serializes the token ledger and the audit log.
	fileMu sync.Mutex
	// renderMu guards the rendered Codex config's source stamp.
	renderMu     sync.Mutex
	renderedFrom string

	wake chan struct{}
}

// New returns the accounts engine. It starts no background work; Run does.
func New(opts Options) (*Service, error) {
	if opts.Store == nil {
		return nil, errors.New("accounts: a store is required")
	}
	if opts.HostHome != "" && !filepath.IsAbs(opts.HostHome) {
		return nil, errors.New("accounts: the host home must be absolute")
	}
	if opts.Clock == nil {
		opts.Clock = time.Now
	}
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.Environment == nil {
		opts.Environment = map[string]string{}
	}
	ctx, cancel := context.WithCancel(context.Background())
	service := &Service{
		opts: opts, store: opts.Store, now: opts.Clock, log: opts.Logger,
		ctx: ctx, cancel: cancel,
		sessions: map[string]*session{}, locks: map[string]*sync.Mutex{},
		bg:   newBackground(),
		wake: make(chan struct{}, 1),
	}
	service.backend = opts.Backend
	if service.backend == nil {
		service.backend = newExecBackend(execOptions{
			RuntimeDir: opts.RuntimeDir, HostHome: opts.HostHome, Environment: opts.Environment, Clock: opts.Clock,
		})
	}
	return service, nil
}

// CodexHome is the CODEX_HOME every Dieter Codex process shares.
func (s *Service) CodexHome() string { return s.store.CodexHome() }

// Shutdown cancels every login session and refuses new ones.
func (s *Service) Shutdown() {
	s.mu.Lock()
	s.shutdown = true
	sessions := make([]*session, 0, len(s.sessions))
	for _, sess := range s.sessions {
		sessions = append(sessions, sess)
	}
	s.mu.Unlock()
	for _, sess := range sessions {
		sess.finish(PhaseCanceled, "", "")
	}
	s.cancel()
	// Let sessions finish their last record writes, briefly.
	done := make(chan struct{})
	go func() {
		s.running.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
	}
}

// async runs a turn notification in the background, so callers that hold
// store locks never wait on (or deadlock with) the record writes it does.
// Shutdown waits for it.
func (s *Service) async(work func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.shutdown {
		return
	}
	s.running.Add(1)
	go func() {
		defer s.running.Done()
		work()
	}()
}

func (s *Service) daemonID() string {
	if s.opts.DaemonID != nil {
		return s.opts.DaemonID()
	}
	id, err := s.store.KV.KnownChannelDaemon()
	if err != nil {
		return ""
	}
	return id
}

// writerDaemon is the daemon ID account-wide writes publish as.
func (s *Service) writerDaemon() (string, error) {
	id := s.daemonID()
	if id == "" {
		return "", fault.New(fault.FailedPrecondition, "this machine has no daemon identity yet; enroll it first")
	}
	return id, nil
}

func (s *Service) machineName() string {
	if s.opts.MachineName != nil {
		if name := s.opts.MachineName(); name != "" {
			return name
		}
	}
	if name, err := os.Hostname(); err == nil && name != "" {
		return strings.TrimSuffix(name, ".local")
	}
	return "this machine"
}

func (s *Service) timestamp() string { return s.now().UTC().Format(time.RFC3339) }

func (s *Service) accountDir(id string) string { return s.store.ProviderAccountDir(id) }

func (s *Service) claudeDir(id string) string { return filepath.Join(s.accountDir(id), "claude") }

func (s *Service) codexAuthDir(id string) string { return filepath.Join(s.accountDir(id), "codex") }

func (s *Service) siwcPath(id string) string { return filepath.Join(s.accountDir(id), "siwc.json") }

// accountLock serializes refreshes and sign-outs of one account in process.
func (s *Service) accountLock(id string) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	lock := s.locks[id]
	if lock == nil {
		lock = &sync.Mutex{}
		s.locks[id] = lock
	}
	return lock
}

// lockAccount holds an account's in-process lock and its lock file, so one
// refresher acts on its credentials at a time.
func (s *Service) lockAccount(ctx context.Context, id string) (func(), error) {
	lock := s.accountLock(id)
	lock.Lock()
	if err := os.MkdirAll(s.accountDir(id), 0o700); err != nil {
		lock.Unlock()
		return nil, err
	}
	file, err := fsx.LockContext(ctx, filepath.Join(s.accountDir(id), ".lock"), 20*time.Millisecond)
	if err != nil {
		lock.Unlock()
		return nil, err
	}
	return func() {
		_ = file.Close()
		lock.Unlock()
	}, nil
}

// writePrivate atomically replaces a private file under the central lock.
func (s *Service) writePrivate(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	staged, err := fsx.Stage(path, data, 0o600)
	if err != nil {
		return err
	}
	defer staged.Discard()
	release, err := s.store.BeginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	return staged.Publish()
}

var accountIDEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// newAccountID is pa_ plus 26 lowercase base32 characters (128 random bits).
func newAccountID() string {
	buffer := make([]byte, 16)
	_, _ = rand.Read(buffer)
	return "pa_" + strings.ToLower(accountIDEncoding.EncodeToString(buffer))
}

func newLoginID() string {
	buffer := make([]byte, 12)
	_, _ = rand.Read(buffer)
	return "pl_" + strings.ToLower(accountIDEncoding.EncodeToString(buffer))
}

func providerName(provider string) string {
	if provider == ProviderChatGPT {
		return "ChatGPT"
	}
	return "Claude"
}

// singleLine bounds provider-reported text before it reaches records.
func singleLine(text string, limit int) string {
	text = strings.Join(strings.Fields(strings.ToValidUTF8(text, "")), " ")
	if len(text) > limit {
		text = text[:limit]
		for !utf8.ValidString(text) {
			text = text[:len(text)-1]
		}
	}
	return text
}
