package accounts

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
)

// Login session bounds (plan §4.2).
const (
	maxSessions       = 4
	maxWatchers       = 16
	sessionLifetime   = 30 * time.Minute
	orphanAfter       = 5 * time.Minute
	finishedRetention = 10 * time.Minute
	startWait         = 20 * time.Second
	maxCodeBytes      = 4 << 10
	maxCallbackBytes  = 8 << 10
)

// session is one sign-in on this machine. The login snapshot is versioned;
// watchers wait on changed, which is closed and replaced on every change, so a
// slow watcher skips intermediate states but never misses the latest.
type session struct {
	svc      *Service
	method   string
	codexWeb bool

	mu       sync.Mutex
	login    Login
	version  uint64
	changed  chan struct{}
	watchers int
	orphan   *time.Timer
	driver   LoginDriver
	cancel   context.CancelFunc
	scratch  string
	// siwcClient is the client a Sign in with ChatGPT session started with;
	// "" registers one.
	siwcClient string
	finished   bool
}

func (sess *session) snapshot() (Login, uint64, chan struct{}) {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	return sess.login, sess.version, sess.changed
}

func (sess *session) terminal() bool {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	return sess.finished
}

// update applies change unless the session already ended.
func (sess *session) update(change func(*Login)) bool {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	if sess.finished {
		return false
	}
	change(&sess.login)
	sess.login.UpdatedAt = sess.svc.timestamp()
	sess.version++
	close(sess.changed)
	sess.changed = make(chan struct{})
	return true
}

// finish ends the session in a terminal phase, stops its driver and removes
// its scratch directory. The finished login stays readable for a while.
func (sess *session) finish(phase, code, message string) bool {
	ended := sess.update(func(login *Login) {
		login.Phase, login.ErrorCode, login.ErrorMessage = phase, code, singleLine(message, 512)
	})
	if !ended {
		return false
	}
	sess.mu.Lock()
	sess.finished = true
	driver, cancel, scratch := sess.driver, sess.cancel, sess.scratch
	if sess.orphan != nil {
		sess.orphan.Stop()
	}
	id := sess.login.ID
	sess.mu.Unlock()
	if driver != nil {
		driver.Cancel()
	}
	if cancel != nil {
		cancel()
	}
	if scratch != "" {
		_ = os.RemoveAll(scratch)
	}
	time.AfterFunc(finishedRetention, func() {
		sess.svc.mu.Lock()
		if sess.svc.sessions[id] == sess {
			delete(sess.svc.sessions, id)
		}
		sess.svc.mu.Unlock()
	})
	return true
}

// armOrphan cancels the session when nobody watches it for orphanAfter.
func (sess *session) armOrphan() {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	if sess.finished || sess.watchers > 0 {
		return
	}
	if sess.orphan != nil {
		sess.orphan.Stop()
	}
	sess.orphan = time.AfterFunc(orphanAfter, func() { sess.finish(PhaseCanceled, "", "") })
}

// StartLogin starts the provider's own sign-in for an account on this
// machine. flow "" picks the method's default: paste_code for Claude,
// device_code for Codex and browser for Sign in with ChatGPT. A new sign-in
// replaces a running one of the same account. It returns once the first
// challenge is ready (or after a short wait).
func (s *Service) StartLogin(ctx context.Context, accountID, flow string) (Login, error) {
	daemon, err := s.writerDaemon()
	if err != nil {
		return Login{}, err
	}
	account, err := s.get(accountID)
	if err != nil {
		return Login{}, err
	}
	flow, err = loginFlow(account.Method, flow)
	if err != nil {
		return Login{}, err
	}
	// Finishing a session cancels its context, which stops its driver.
	sessionCtx, cancel := context.WithTimeout(s.ctx, sessionLifetime)
	sess := &session{
		svc: s, method: account.Method, codexWeb: account.Method == MethodCodex && flow == FlowBrowser,
		login:   Login{ID: newLoginID(), AccountID: accountID, DaemonID: daemon, Flow: flow, Phase: PhaseStarting, UpdatedAt: s.timestamp()},
		changed: make(chan struct{}), cancel: cancel,
	}
	var replaced *session
	s.mu.Lock()
	if s.shutdown {
		s.mu.Unlock()
		cancel()
		return Login{}, fault.New(fault.Unavailable, "the daemon is shutting down")
	}
	active := 0
	for _, other := range s.sessions {
		if other.terminal() {
			continue
		}
		if other.login.AccountID == accountID {
			replaced = other
			continue
		}
		active++
		if sess.codexWeb && other.codexWeb {
			s.mu.Unlock()
			cancel()
			return Login{}, fault.New(fault.FailedPrecondition, "another ChatGPT browser sign-in is running on this machine; finish or cancel it first")
		}
	}
	if active >= maxSessions {
		s.mu.Unlock()
		cancel()
		return Login{}, fault.New(fault.ResourceExhausted, "too many sign-ins are running on this machine")
	}
	s.sessions[sess.login.ID] = sess
	s.mu.Unlock()
	if replaced != nil {
		replaced.finish(PhaseCanceled, "", "replaced by a new sign-in")
	}
	sess.armOrphan()
	driver, err := s.startDriver(sessionCtx, sess, account)
	if err != nil {
		sess.finish(PhaseFailed, "login_failed", err.Error())
		login, _, _ := sess.snapshot()
		return login, nil
	}
	sess.mu.Lock()
	sess.driver = driver
	finished := sess.finished
	sess.mu.Unlock()
	if finished {
		// Canceled while the driver started.
		driver.Cancel()
		login, _, _ := sess.snapshot()
		return login, nil
	}
	// Shutdown sets shutdown under s.mu before it waits; register under it.
	s.mu.Lock()
	if s.shutdown {
		s.mu.Unlock()
		sess.finish(PhaseCanceled, "", "")
		login, _, _ := sess.snapshot()
		return login, nil
	}
	s.running.Add(1)
	s.mu.Unlock()
	go func() {
		defer s.running.Done()
		s.runSession(sessionCtx, sess, driver)
	}()
	wait, stop := context.WithTimeout(ctx, startWait)
	defer stop()
	for {
		login, _, changed := sess.snapshot()
		if login.Phase != PhaseStarting {
			return login, nil
		}
		select {
		case <-changed:
		case <-wait.Done():
			return login, nil
		}
	}
}

func loginFlow(method, flow string) (string, error) {
	switch method {
	case MethodClaudeCode:
		switch flow {
		case "", FlowPasteCode:
			return FlowPasteCode, nil
		case FlowBrowser:
			return FlowBrowser, nil
		}
	case MethodCodex:
		switch flow {
		case "", FlowDeviceCode:
			return FlowDeviceCode, nil
		case FlowBrowser:
			return FlowBrowser, nil
		}
	case MethodSIWC:
		if flow == "" || flow == FlowBrowser {
			return FlowBrowser, nil
		}
	case MethodHost, MethodEnvironment:
		return "", fault.New(fault.FailedPrecondition, "this account uses this machine's own login; sign in with the provider's tool instead")
	}
	return "", fault.Invalidf("the %s login has no %s flow", method, flow)
}

func (s *Service) startDriver(ctx context.Context, sess *session, account Account) (LoginDriver, error) {
	switch account.Method {
	case MethodClaudeCode:
		dir, err := s.prepareClaudeHome(account.ID)
		if err != nil {
			return nil, err
		}
		scratch := filepath.Join(s.accountDir(account.ID), "session")
		_ = os.RemoveAll(scratch)
		if err := os.MkdirAll(scratch, 0o700); err != nil {
			return nil, err
		}
		sess.mu.Lock()
		sess.scratch = scratch
		sess.mu.Unlock()
		return s.backend.ClaudeLogin(ctx, ClaudeLoginRequest{ConfigDir: dir, SessionDir: scratch, Email: account.Identity.Email})
	case MethodCodex:
		if err := os.MkdirAll(s.codexAuthDir(account.ID), 0o700); err != nil {
			return nil, err
		}
		return s.backend.CodexLogin(ctx, CodexLoginRequest{Home: CodexAuthHome{Dir: s.codexAuthDir(account.ID), Managed: true}, Flow: sess.login.Flow})
	case MethodSIWC:
		request := SIWCLoginRequest{HostID: s.hostID()}
		r, err := s.load()
		if err != nil {
			return nil, err
		}
		if record, ok := r.live(account.ID); ok && record.SIWC != nil {
			request.ClientID = record.SIWC.ClientID
		}
		if saved, err := s.readSIWC(account.ID); err == nil && saved.ClientID == request.ClientID {
			request.IDTokenHint = saved.IDToken
		}
		sess.siwcClient = request.ClientID
		return s.backend.SIWCLogin(ctx, request)
	}
	return nil, fault.Invalidf("the %s login has no sign-in", account.Method)
}

func (s *Service) runSession(ctx context.Context, sess *session, driver LoginDriver) {
	updates := driver.Updates()
	for {
		select {
		case update, open := <-updates:
			if !open {
				if ctx.Err() == nil {
					sess.finish(PhaseFailed, "login_failed", "the sign-in stopped unexpectedly")
				}
				s.finishTimedOut(ctx, sess)
				return
			}
			switch update.Phase {
			case PhaseWaiting:
				sess.update(func(login *Login) {
					login.Phase, login.Challenge = PhaseWaiting, update.Challenge
				})
			case PhaseCompleting:
				sess.update(func(login *Login) { login.Phase = PhaseCompleting })
			case PhaseSucceeded:
				s.completeLogin(ctx, sess, update)
				return
			case PhaseFailed:
				code := update.ErrorCode
				if code == "" {
					code = "login_failed"
				}
				sess.finish(PhaseFailed, code, update.ErrorMessage)
				return
			}
		case <-ctx.Done():
			driver.Cancel()
			s.finishTimedOut(ctx, sess)
			return
		}
	}
}

func (s *Service) finishTimedOut(ctx context.Context, sess *session) {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		sess.finish(PhaseFailed, "timeout", "the sign-in took longer than 30 minutes")
		return
	}
	sess.finish(PhaseCanceled, "", "")
}

// completeLogin binds the verified identity, records the login and ends the
// session. A sign-in as someone other than the bound identity is signed out
// at once.
func (s *Service) completeLogin(ctx context.Context, sess *session, update LoginUpdate) {
	login, _, _ := sess.snapshot()
	if !sess.update(func(login *Login) { login.Phase = PhaseCompleting }) {
		return
	}
	bound, err := s.bindIdentity(login.AccountID, update.Identity)
	var mismatch *mismatchError
	if errors.As(err, &mismatch) {
		signOutCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		defer cancel()
		if signOutErr := s.signOutMethod(signOutCtx, login.AccountID, sess.method, update.SIWC); signOutErr != nil {
			s.log.Warn("provider sign-out after an identity mismatch failed", "account", login.AccountID, "error", signOutErr)
		}
		_ = s.updateLogin(login.AccountID, func(record *schema.ProviderLoginRecord, _ bool) bool {
			*record = schema.ProviderLoginRecord{State: StateFailed, Method: sess.method, Identity: identityPointer(update.Identity),
				Error: &schema.ProviderLoginError{Code: ErrorIdentityMismatch, Message: singleLine(mismatch.Error(), 512)},
				Usage: record.Usage, DieterTokens: record.DieterTokens}
			return true
		})
		s.audit(login.AccountID, "sign_in", "identity_mismatch")
		sess.finish(PhaseFailed, ErrorIdentityMismatch, mismatch.Error())
		return
	}
	if err != nil {
		sess.finish(PhaseFailed, "login_failed", err.Error())
		return
	}
	var unavailable string
	if update.SIWC != nil {
		if err := s.saveSIWC(login.AccountID, *update.SIWC); err != nil {
			sess.finish(PhaseFailed, "login_failed", err.Error())
			return
		}
		if sess.siwcClient == "" && update.SIWC.ClientID != "" {
			if err := s.bindSIWCClient(login.AccountID, update.SIWC.ClientID); err != nil {
				sess.finish(PhaseFailed, "login_failed", err.Error())
				return
			}
		}
		if !update.SIWC.PlanUsageGranted() {
			unavailable = "plan_usage_not_granted"
		}
	}
	verified := update.Identity
	if verified.Plan == "" {
		verified.Plan = bound.Plan
	}
	err = s.updateLogin(login.AccountID, func(record *schema.ProviderLoginRecord, _ bool) bool {
		next := schema.ProviderLoginRecord{State: StateSignedIn, Method: sess.method, Identity: identityPointer(verified),
			VerifiedAt: s.timestamp(), Usage: record.Usage, DieterTokens: record.DieterTokens}
		if unavailable != "" {
			next.Usage = &schema.ProviderUsage{ObservedAt: s.timestamp(), Unavailable: unavailable}
		}
		*record = next
		return true
	})
	if err != nil {
		sess.finish(PhaseFailed, "login_failed", err.Error())
		return
	}
	s.markChecked(login.AccountID)
	s.audit(login.AccountID, "sign_in", "succeeded")
	sess.update(func(login *Login) { login.Identity = verified })
	sess.finish(PhaseSucceeded, "", "")
	s.requestBackground()
}

// bindSIWCClient stores the client ID issued at first registration.
func (s *Service) bindSIWCClient(id, clientID string) error {
	_, err := s.store.KV.PutProviderAccount(id, func(current *schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
		if current == nil {
			return nil, fault.NotFoundf("provider account %s not found", id)
		}
		if current.SIWC != nil && current.SIWC.ClientID != "" {
			return nil, nil
		}
		next := *current
		next.SIWC = &schema.ProviderSIWC{ClientID: clientID}
		return &next, nil
	})
	return err
}

func (s *Service) session(loginID string) (*session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess := s.sessions[loginID]
	if sess == nil {
		return nil, fault.NotFoundf("sign-in %s not found", loginID)
	}
	return sess, nil
}

// WatchLogin emits the sign-in's current state, then each change, until it
// ends or ctx is done.
func (s *Service) WatchLogin(ctx context.Context, loginID string, emit func(Login) error) error {
	sess, err := s.session(loginID)
	if err != nil {
		return err
	}
	sess.mu.Lock()
	if sess.watchers >= maxWatchers {
		sess.mu.Unlock()
		return fault.New(fault.ResourceExhausted, "too many watchers of this sign-in")
	}
	sess.watchers++
	if sess.orphan != nil {
		sess.orphan.Stop()
	}
	sess.mu.Unlock()
	defer func() {
		sess.mu.Lock()
		sess.watchers--
		sess.mu.Unlock()
		sess.armOrphan()
	}()
	var emitted uint64
	first := true
	for {
		login, version, changed := sess.snapshot()
		if first || version != emitted {
			if err := emit(login); err != nil {
				return err
			}
			first, emitted = false, version
		}
		if terminalPhase(login.Phase) {
			return nil
		}
		select {
		case <-changed:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func terminalPhase(phase string) bool {
	return phase == PhaseSucceeded || phase == PhaseFailed || phase == PhaseCanceled
}

// SubmitLoginInput hands a pasted code or a loopback callback URL to a
// waiting sign-in. The code is never logged or stored.
func (s *Service) SubmitLoginInput(ctx context.Context, loginID, code, callbackURL string) (Login, error) {
	sess, err := s.session(loginID)
	if err != nil {
		return Login{}, err
	}
	code, callbackURL = strings.TrimSpace(code), strings.TrimSpace(callbackURL)
	if (code == "") == (callbackURL == "") {
		return Login{}, fault.New(fault.Invalid, "submit either a code or a callback address")
	}
	if len(code) > maxCodeBytes || strings.ContainsAny(code, "\r\n\x00") || len(callbackURL) > maxCallbackBytes {
		return Login{}, fault.New(fault.Invalid, "that input is not a sign-in code or address")
	}
	login, _, _ := sess.snapshot()
	if login.Phase != PhaseWaiting {
		return login, fault.Errorf(fault.FailedPrecondition, "the sign-in is %s, not waiting for input", login.Phase)
	}
	if code != "" && login.Challenge.Expects == ExpectsNone {
		return login, fault.New(fault.FailedPrecondition, "this sign-in completes on its own; enter the code on the provider's page")
	}
	sess.mu.Lock()
	driver := sess.driver
	sess.mu.Unlock()
	if driver == nil {
		return login, fault.New(fault.FailedPrecondition, "the sign-in is not ready yet")
	}
	submitCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := driver.Submit(submitCtx, code, callbackURL); err != nil {
		if _, classified := fault.KindOf(err); !classified {
			err = fault.Wrap(fault.Invalid, err)
		}
		login, _, _ = sess.snapshot()
		return login, err
	}
	sess.update(func(login *Login) {
		if login.Phase == PhaseWaiting {
			login.Phase = PhaseCompleting
		}
	})
	login, _, _ = sess.snapshot()
	return login, nil
}

// CancelLogin cancels a sign-in.
func (s *Service) CancelLogin(_ context.Context, loginID string) (Login, error) {
	sess, err := s.session(loginID)
	if err != nil {
		return Login{}, err
	}
	sess.finish(PhaseCanceled, "", "")
	login, _, _ := sess.snapshot()
	return login, nil
}

// signOutMethod removes this machine's managed credential of an account.
func (s *Service) signOutMethod(ctx context.Context, accountID, method string, tokens *SIWCTokens) error {
	switch method {
	case MethodClaudeCode:
		if _, err := os.Stat(s.claudeDir(accountID)); err != nil {
			return nil
		}
		return s.backend.SignOutClaude(ctx, s.claudeDir(accountID))
	case MethodCodex:
		if _, err := os.Stat(s.codexAuthDir(accountID)); err != nil {
			return nil
		}
		return s.backend.SignOutCodex(ctx, CodexAuthHome{Dir: s.codexAuthDir(accountID), Managed: true})
	case MethodSIWC:
		if tokens == nil {
			saved, err := s.readSIWC(accountID)
			if err != nil {
				return nil
			}
			tokens = &saved
		}
		err := s.backend.RevokeSIWC(ctx, *tokens)
		if removeErr := os.Remove(s.siwcPath(accountID)); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
			err = errors.Join(err, removeErr)
		}
		return err
	}
	return nil
}

// SignOut signs an account out on this machine. Logins that belong to the
// machine itself (host, environment) are signed out with their own tools.
func (s *Service) SignOut(ctx context.Context, accountID string) (Account, error) {
	account, err := s.get(accountID)
	if err != nil {
		return Account{}, err
	}
	if account.Method == MethodHost || account.Method == MethodEnvironment {
		return Account{}, fault.New(fault.FailedPrecondition, "this account uses this machine's own login; sign out with the provider's tool")
	}
	release, err := s.lockAccount(ctx, accountID)
	if err != nil {
		return Account{}, err
	}
	err = s.signOutMethod(ctx, accountID, account.Method, nil)
	release()
	if err != nil {
		s.audit(accountID, "sign_out", "failed")
		return Account{}, err
	}
	if err := s.updateLogin(accountID, func(record *schema.ProviderLoginRecord, exists bool) bool {
		if !exists {
			return false
		}
		record.State, record.Error, record.Usage = StateSignedOut, nil, nil
		record.VerifiedAt = s.timestamp()
		return true
	}); err != nil {
		return Account{}, err
	}
	s.audit(accountID, "sign_out", "succeeded")
	return s.get(accountID)
}

// readSIWC reads this host's Sign in with ChatGPT session of an account.
func (s *Service) readSIWC(accountID string) (SIWCTokens, error) {
	var tokens SIWCTokens
	raw, err := os.ReadFile(s.siwcPath(accountID))
	if err != nil {
		return tokens, err
	}
	err = json.Unmarshal(raw, &tokens)
	return tokens, err
}

func (s *Service) saveSIWC(accountID string, tokens SIWCTokens) error {
	tokens.SavedAt = s.now().UTC()
	raw, err := json.MarshalIndent(tokens, "", "  ")
	if err != nil {
		return err
	}
	return s.writePrivate(s.siwcPath(accountID), append(raw, '\n'))
}
