package accounts

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/kv"
)

// Background cadence (plan §4.2, §4.7).
const (
	runInterval    = 20 * time.Second
	checkEvery     = 15 * time.Minute
	adoptEvery     = 30 * time.Minute
	tokenSweep     = 15 * time.Minute
	checkTimeout   = 30 * time.Second
	cleanupRetries = 3
)

// background is the bookkeeping of Run, guarded by Service.mu.
type background struct {
	lastCheck       map[string]time.Time
	checkAt         map[string]time.Time
	nextProbe       map[string]time.Time
	lastRefresh     map[string]time.Time
	pending         map[string]Usage
	lastObserved    map[string]time.Time
	cleanupFailures map[string]int
	nextAdoption    time.Time
	nextTokenSweep  time.Time
	lastPrune       time.Time
}

func newBackground() background {
	return background{
		lastCheck: map[string]time.Time{}, checkAt: map[string]time.Time{}, nextProbe: map[string]time.Time{},
		lastRefresh: map[string]time.Time{}, pending: map[string]Usage{}, lastObserved: map[string]time.Time{},
		cleanupFailures: map[string]int{},
	}
}

// Run does the background work until ctx ends: render the shared Codex
// config, adopt the host's logins, clean up removed accounts, check logins,
// probe usage and keep token sums current.
func (s *Service) Run(ctx context.Context) {
	s.tick(ctx)
	ticker := time.NewTicker(runInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-s.wake:
		}
		s.tick(ctx)
	}
}

func (s *Service) requestBackground() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *Service) tick(ctx context.Context) {
	if err := s.renderCodexHome(); err != nil {
		s.log.Warn("could not render Dieter's Codex config", "error", err)
	}
	if s.daemonID() == "" {
		return
	}
	now := s.now()
	s.mu.Lock()
	adopt := !now.Before(s.bg.nextAdoption)
	if adopt {
		s.bg.nextAdoption = now.Add(adoptEvery)
	}
	sweep := !now.Before(s.bg.nextTokenSweep)
	if sweep {
		s.bg.nextTokenSweep = now.Add(tokenSweep)
	}
	s.mu.Unlock()
	if adopt {
		s.adopt(ctx)
	}
	s.cleanup(ctx)
	s.checkDue(ctx)
	s.probeDue(ctx)
	s.flushObserved()
	if sweep {
		s.sweepTokens()
	}
}

func (s *Service) markChecked(accountID string) {
	s.mu.Lock()
	s.bg.lastCheck[accountID] = s.now()
	delete(s.bg.checkAt, accountID)
	s.mu.Unlock()
}

func (s *Service) scheduleCheck(accountID string, after time.Duration) {
	s.mu.Lock()
	s.bg.checkAt[accountID] = s.now().Add(after)
	s.mu.Unlock()
	if after <= 0 {
		s.requestBackground()
	}
}

// checkDue verifies this machine's logins at most every 15 minutes, and soon
// after a turn's auth failure.
func (s *Service) checkDue(ctx context.Context) {
	r, err := s.load()
	if err != nil {
		return
	}
	daemon := s.daemonID()
	now := s.now()
	for id := range r.accounts {
		account, ok := r.account(id)
		if !ok {
			continue
		}
		login, has := r.ownLogin(id, daemon)
		if !has || (login.State != StateSignedIn && login.State != StateExpired) {
			continue
		}
		s.mu.Lock()
		last, checked := s.bg.lastCheck[id]
		if !checked {
			// After a restart, the record's own verification time counts.
			if verified, err := time.Parse(time.RFC3339Nano, login.VerifiedAt); err == nil {
				last = verified
			}
		}
		forced, hasForced := s.bg.checkAt[id]
		s.mu.Unlock()
		if now.Sub(last) < checkEvery && (!hasForced || now.Before(forced)) {
			continue
		}
		if err := s.checkLogin(ctx, account); err != nil {
			s.log.Debug("provider login check failed", "account", id, "error", err)
		}
	}
}

// Check verifies an account's login on this machine now.
func (s *Service) Check(ctx context.Context, accountID string) (Account, error) {
	account, err := s.get(accountID)
	if err != nil {
		return Account{}, err
	}
	if err := s.checkLogin(ctx, account); err != nil {
		return Account{}, err
	}
	return s.get(accountID)
}

// checkLogin asks the provider's tool whether this machine's login of an
// account works and records the result.
func (s *Service) checkLogin(ctx context.Context, account Account) error {
	ctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	var loggedIn bool
	var verified Identity
	switch account.Method {
	case MethodClaudeCode, MethodHost:
		if account.Provider == ProviderClaude {
			dir := s.hostClaudeArg()
			if account.Method == MethodClaudeCode {
				if _, err := os.Stat(s.claudeDir(account.ID)); err != nil {
					break
				}
				dir = s.claudeDir(account.ID)
			}
			status, err := s.backend.CheckClaude(ctx, dir)
			if err != nil {
				return err
			}
			loggedIn, verified = status.Subscription(), status.Identity
			break
		}
		auth, err := readCodexAuth(s.hostCodexHome())
		loggedIn = err == nil
		verified = auth.identity()
	case MethodCodex:
		home := CodexAuthHome{Dir: s.codexAuthDir(account.ID), Managed: true}
		if _, err := os.Stat(filepath.Join(home.Dir, "auth.json")); err != nil {
			break
		}
		status, err := s.backend.CheckCodex(ctx, home)
		if err != nil {
			return err
		}
		loggedIn, verified = status.LoggedIn, status.Identity
	case MethodSIWC:
		tokens, err := s.readSIWC(account.ID)
		loggedIn = err == nil && tokens.RefreshToken != ""
		verified = account.Identity
	case MethodEnvironment:
		if account.Provider == ProviderClaude {
			_, value := s.claudeEnvironmentKey()
			loggedIn = value != ""
		} else {
			_, value := s.openAIEnvironmentKey()
			loggedIn = value != ""
		}
		verified = account.Identity
	}
	s.markChecked(account.ID)
	mismatch := loggedIn && identityKey(account.Provider, account.Method, account.Identity) != "" &&
		identityKey(account.Provider, account.Method, verified) != identityKey(account.Provider, account.Method, account.Identity)
	return s.updateLogin(account.ID, func(record *schema.ProviderLoginRecord, exists bool) bool {
		if !exists && !loggedIn {
			return false
		}
		next := *record
		next.Method, next.VerifiedAt = account.Method, s.timestamp()
		switch {
		case mismatch:
			next.State = StateFailed
			if account.Method == MethodHost {
				next.State = StateSignedOut
			}
			next.Error = &schema.ProviderLoginError{Code: ErrorIdentityMismatch, Message: singleLine((&mismatchError{got: verified, want: account.Identity}).Error(), 512)}
		case loggedIn:
			next.State, next.Error = StateSignedIn, nil
			next.Identity = identityPointer(mergeIdentity(verified, account.Identity))
		default:
			next.State, next.Error, next.Usage = StateSignedOut, nil, nil
		}
		*record = next
		return true
	})
}

// mergeIdentity fills fields the check did not report from the bound identity.
func mergeIdentity(verified, bound Identity) Identity {
	if verified.Email == "" {
		verified.Email = bound.Email
	}
	if verified.Organization == "" {
		verified.Organization = bound.Organization
	}
	if verified.OrganizationID == "" {
		verified.OrganizationID = bound.OrganizationID
	}
	if verified.WorkspaceID == "" {
		verified.WorkspaceID = bound.WorkspaceID
	}
	if verified.Subject == "" {
		verified.Subject = bound.Subject
	}
	if verified.Plan == "" {
		verified.Plan = bound.Plan
	}
	return verified
}

// hostClaudeArg is the config directory argument of the host's Claude login:
// "" for Claude Code's default, or the daemon's CLAUDE_CONFIG_DIR.
func (s *Service) hostClaudeArg() string {
	if dir := s.opts.Environment["CLAUDE_CONFIG_DIR"]; dir != "" && filepath.IsAbs(dir) {
		return filepath.Clean(dir)
	}
	return ""
}

// adopt turns what this machine already has into accounts: the host's own
// Claude Code and Codex logins (matched by identity, created if missing) and
// API keys in the daemon environment. Nothing is copied or moved. An account
// the person removed stays removed while the login is the same.
func (s *Service) adopt(ctx context.Context) {
	daemon := s.daemonID()
	adopted := s.readAdopted()
	changed := false
	ctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	if status, err := s.backend.CheckClaude(ctx, s.hostClaudeArg()); err == nil && status.Subscription() {
		label := status.Identity.Email
		if label == "" {
			label = "Claude Code on " + s.machineName()
		}
		changed = s.adoptLogin(adopted, ProviderClaude, MethodHost, status.Identity, label) || changed
	} else if err != nil {
		s.log.Debug("could not read the host's Claude Code login", "error", err)
	}
	if auth, err := readCodexAuth(s.hostCodexHome()); err == nil {
		identity := auth.identity()
		label := identity.Email
		if label == "" {
			label = "Codex on " + s.machineName()
		}
		changed = s.adoptLogin(adopted, ProviderChatGPT, MethodHost, identity, label) || changed
	}
	if _, value := s.claudeEnvironmentKey(); value != "" {
		changed = s.adoptLogin(adopted, ProviderClaude, MethodEnvironment, Identity{Subject: "environment:" + daemon + ":claude"}, "Anthropic API key on "+s.machineName()) || changed
	}
	if _, value := s.openAIEnvironmentKey(); value != "" {
		changed = s.adoptLogin(adopted, ProviderChatGPT, MethodEnvironment, Identity{Subject: "environment:" + daemon + ":chatgpt"}, "OpenAI API key on "+s.machineName()) || changed
	}
	if changed {
		if err := s.writeAdopted(adopted); err != nil {
			s.log.Warn("could not record adopted provider logins", "error", err)
		}
	}
}

// adoptLogin matches or creates the account of one host login and records
// this machine's login of it. It reports whether adopted changed.
func (s *Service) adoptLogin(adopted map[string]string, provider, method string, identity Identity, label string) bool {
	key := identityKey(provider, method, identity)
	if key == "" {
		return false
	}
	r, err := s.load()
	if err != nil {
		return false
	}
	mapKey := provider + "|" + method + "|" + key
	id, known := adopted[mapKey]
	changed := false
	if known {
		if _, ok := r.live(id); !ok {
			// Removed by a person: this login stays hidden.
			return false
		}
	} else {
		for candidate, entry := range r.accounts {
			if entry.Deleted || entry.Record.Provider != provider || entry.Record.Method != method || entry.Record.Identity == nil {
				continue
			}
			if identityKey(provider, method, *entry.Record.Identity) == key {
				id = candidate
				break
			}
		}
		if id == "" {
			id = newAccountID()
			if err := s.createAccount(id, provider, truncateRunes(label, schema.ProviderLabelRunes), method, &identity); err != nil {
				s.log.Warn("could not adopt a provider login", "provider", provider, "method", method, "error", err)
				return false
			}
		}
		adopted[mapKey], changed = id, true
	}
	if r.signedIn(id, s.daemonID()) {
		return changed
	}
	if err := s.updateLogin(id, func(record *schema.ProviderLoginRecord, _ bool) bool {
		record.State, record.Method, record.Error = StateSignedIn, method, nil
		record.Identity, record.VerifiedAt = identityPointer(identity), s.timestamp()
		return true
	}); err != nil {
		s.log.Warn("could not record an adopted provider login", "account", id, "error", err)
		return changed
	}
	s.markChecked(id)
	s.audit(id, "adopt", "succeeded")
	return changed
}

func (s *Service) adoptedPath() string {
	return filepath.Join(s.store.ProviderAccountsDir(), "adopted.json")
}

func (s *Service) readAdopted() map[string]string {
	adopted := map[string]string{}
	if raw, err := os.ReadFile(s.adoptedPath()); err == nil {
		_ = json.Unmarshal(raw, &adopted)
	}
	return adopted
}

func (s *Service) writeAdopted(adopted map[string]string) error {
	raw, err := json.MarshalIndent(adopted, "", "  ")
	if err != nil {
		return err
	}
	return s.writePrivate(s.adoptedPath(), append(raw, '\n'))
}

// cleanup acts on removed accounts: it signs this machine's managed login out
// (never a host or environment login, which hold no files here), removes the
// account's directory and tombstones this machine's login record.
func (s *Service) cleanup(ctx context.Context) {
	r, err := s.load()
	if err != nil {
		return
	}
	daemon := s.daemonID()
	ownLogin := map[string]bool{}
	_ = s.store.KV.EachProviderLogin("", true, func(entry kv.ProviderLoginEntry) error {
		if entry.DaemonID == daemon && !entry.Deleted {
			ownLogin[entry.AccountID] = true
		}
		return nil
	})
	for id, entry := range r.accounts {
		if !entry.Deleted {
			continue
		}
		_, dirErr := os.Lstat(s.accountDir(id))
		if !ownLogin[id] && errors.Is(dirErr, os.ErrNotExist) {
			continue
		}
		outcome := "succeeded"
		if err := s.signOutRemoved(ctx, id); err != nil {
			s.mu.Lock()
			s.bg.cleanupFailures[id]++
			failures := s.bg.cleanupFailures[id]
			s.mu.Unlock()
			s.log.Warn("could not sign a removed provider account out", "account", id, "attempt", failures, "error", err)
			if failures < cleanupRetries {
				continue
			}
			outcome = "sign_out_failed"
		}
		if err := s.removeAccountDir(id); err != nil {
			s.log.Warn("could not remove a provider account's files", "account", id, "error", err)
			continue
		}
		if ownLogin[id] {
			if err := s.store.KV.DeleteProviderLogin(id, daemon); err != nil {
				s.log.Warn("could not remove a provider login record", "account", id, "error", err)
				continue
			}
		}
		s.mu.Lock()
		delete(s.bg.cleanupFailures, id)
		s.mu.Unlock()
		s.audit(id, "cleanup", outcome)
	}
}

// signOutRemoved signs out whatever managed login a removed account left on
// this machine. The tombstone carries no method, so the files decide.
func (s *Service) signOutRemoved(ctx context.Context, id string) error {
	release, err := s.lockAccount(ctx, id)
	if err != nil {
		return err
	}
	defer release()
	ctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	var failures []error
	if _, err := os.Stat(s.claudeDir(id)); err == nil {
		if err := s.backend.SignOutClaude(ctx, s.claudeDir(id)); err != nil {
			failures = append(failures, err)
		}
	}
	if _, err := os.Stat(filepath.Join(s.codexAuthDir(id), "auth.json")); err == nil {
		if err := s.backend.SignOutCodex(ctx, CodexAuthHome{Dir: s.codexAuthDir(id), Managed: true}); err != nil {
			failures = append(failures, err)
		}
	}
	if tokens, err := s.readSIWC(id); err == nil {
		if err := s.backend.RevokeSIWC(ctx, tokens); err != nil {
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}

func truncateRunes(text string, limit int) string {
	text = strings.TrimSpace(text)
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	return strings.TrimSpace(string([]rune(text)[:limit]))
}
