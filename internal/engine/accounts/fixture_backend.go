package accounts

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// FixtureCode is the pasted code a fixture Claude sign-in accepts, alone or
// as FIXTURE-CODE#<state>. A state that is an email address signs in as that
// address, so tests can provoke an identity mismatch.
const FixtureCode = "FIXTURE-CODE"

// FixtureBackend is a deterministic, in-process Backend for tests and the
// fixture gateway. It never runs a provider tool or touches the network.
// Logins persist in the account homes: a marker file in a Claude config
// directory and a Codex-format auth.json with unsigned tokens, so the
// engine's own readers work unchanged.
type FixtureBackend struct {
	// Clock defaults to time.Now.
	Clock func() time.Time
	// DeviceApproval is how long a device code takes to approve (2 s).
	DeviceApproval time.Duration
	// ClaudeIdentity and ChatGPTIdentity are who fixture sign-ins sign in as.
	ClaudeIdentity, ChatGPTIdentity Identity
	// HostClaude is the host's own Claude Code login, if any.
	HostClaude *Identity

	mu     sync.Mutex
	probes map[string]int
	// claudeTokens counts each Claude config directory's refreshes; an
	// expired entry makes ReadClaudeToken report a past expiry.
	claudeTokens  map[string]int
	claudeExpired map[string]bool
	reset         map[string]bool
	redeem        map[string]bool
	calls         []string
	refresh       int
}

// NewFixtureBackend returns a fixture backend with its default identities.
func NewFixtureBackend() *FixtureBackend {
	return &FixtureBackend{
		Clock: time.Now, DeviceApproval: 2 * time.Second,
		ClaudeIdentity:  Identity{Email: "fixture@example.com", Organization: "Fixture Org", OrganizationID: "org_fixture", Plan: "max"},
		ChatGPTIdentity: Identity{Email: "fixture@example.com", WorkspaceID: "fixture-workspace", Plan: "pro"},
	}
}

func (f *FixtureBackend) now() time.Time {
	if f.Clock == nil {
		return time.Now()
	}
	return f.Clock()
}

func (f *FixtureBackend) record(call string) {
	f.mu.Lock()
	f.calls = append(f.calls, call)
	f.mu.Unlock()
}

// Calls lists the backend operations in order, for assertions.
func (f *FixtureBackend) Calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

// fixtureLogin is a scripted login.
type fixtureLogin struct {
	updates chan LoginUpdate
	submit  func(code, callbackURL string) error
	once    sync.Once
	done    chan struct{}
}

func newFixtureLogin() *fixtureLogin {
	return &fixtureLogin{updates: make(chan LoginUpdate, 8), done: make(chan struct{})}
}

func (l *fixtureLogin) Updates() <-chan LoginUpdate { return l.updates }

func (l *fixtureLogin) Submit(_ context.Context, code, callbackURL string) error {
	return l.submit(code, callbackURL)
}

func (l *fixtureLogin) Cancel() { l.end(nil) }

// end sends a terminal update (if any) and closes the updates once.
func (l *fixtureLogin) end(update *LoginUpdate) {
	l.once.Do(func() {
		if update != nil {
			l.updates <- *update
		}
		close(l.done)
		close(l.updates)
	})
}

func (f *FixtureBackend) ClaudeLogin(_ context.Context, request ClaudeLoginRequest) (LoginDriver, error) {
	f.record("ClaudeLogin:" + request.ConfigDir)
	login := newFixtureLogin()
	const port = 54545
	challenge := Challenge{
		OpenURL:      "https://claude.ai/oauth/authorize?code=true&fixture=1&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback",
		LocalURL:     "https://claude.ai/oauth/authorize?fixture=1&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback",
		CallbackPort: port, Expects: ExpectsCode,
	}
	login.submit = func(code, callbackURL string) error {
		identity := f.ClaudeIdentity
		if callbackURL != "" {
			address, err := parseCallback(callbackURL, port, "/callback")
			if err != nil {
				return err
			}
			if address.Query().Get("code") != "fixture" {
				login.end(&LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: "Claude Code could not sign in: invalid code"})
				return nil
			}
		} else {
			value, state, _ := strings.Cut(code, "#")
			if value != FixtureCode {
				login.end(&LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: "Claude Code could not sign in: invalid code"})
				return nil
			}
			if strings.Contains(state, "@") {
				identity.Email = state
			}
		}
		if err := writeFixtureJSON(filepath.Join(request.ConfigDir, ".fixture-login.json"), identity); err != nil {
			return err
		}
		login.end(&LoginUpdate{Phase: PhaseSucceeded, Identity: identity})
		return nil
	}
	login.updates <- LoginUpdate{Phase: PhaseWaiting, Challenge: challenge}
	return login, nil
}

func (f *FixtureBackend) CodexLogin(ctx context.Context, request CodexLoginRequest) (LoginDriver, error) {
	f.record("CodexLogin:" + request.Flow + ":" + request.Home.Dir)
	login := newFixtureLogin()
	succeed := func() {
		if err := f.writeCodexAuth(request.Home.Dir, f.now()); err != nil {
			login.end(&LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: err.Error()})
			return
		}
		login.end(&LoginUpdate{Phase: PhaseSucceeded, Identity: f.ChatGPTIdentity})
	}
	switch request.Flow {
	case FlowDeviceCode:
		login.submit = func(string, string) error {
			return fault.New(fault.FailedPrecondition, "this ChatGPT sign-in completes on its own")
		}
		login.updates <- LoginUpdate{Phase: PhaseWaiting, Challenge: Challenge{
			OpenURL: "https://auth.openai.com/codex/device", UserCode: "FIXT-12345", Expects: ExpectsNone,
			ExpiresAt: f.now().Add(codexDeviceLifetime).UTC().Format(time.RFC3339),
		}}
		delay := f.DeviceApproval
		go func() {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
				succeed()
			case <-login.done:
			case <-ctx.Done():
				login.end(nil)
			}
		}()
	case FlowBrowser:
		login.submit = func(_ string, callbackURL string) error {
			address, err := parseCallback(callbackURL, codexCallbackPort, "/auth/callback")
			if err != nil {
				return err
			}
			if address.Query().Get("code") != "fixture" {
				login.end(&LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: "Codex: invalid authorization code"})
				return nil
			}
			succeed()
			return nil
		}
		authURL := "https://auth.openai.com/oauth/authorize?fixture=1&redirect_uri=" + url.QueryEscape("http://localhost:1455/auth/callback")
		login.updates <- LoginUpdate{Phase: PhaseWaiting, Challenge: Challenge{OpenURL: authURL, LocalURL: authURL, CallbackPort: codexCallbackPort, Expects: ExpectsCallback}}
	default:
		return nil, fault.Invalidf("Codex has no %s sign-in", request.Flow)
	}
	return login, nil
}

func (f *FixtureBackend) SIWCLogin(_ context.Context, request SIWCLoginRequest) (LoginDriver, error) {
	f.record("SIWCLogin:" + request.ClientID)
	login := newFixtureLogin()
	const port = 1456
	login.submit = func(_ string, callbackURL string) error {
		address, err := parseCallback(callbackURL, port, siwcCallbackPath)
		if err != nil {
			return err
		}
		if address.Query().Get("code") != "fixture" {
			login.end(&LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: "OpenAI declined the sign-in"})
			return nil
		}
		clientID := request.ClientID
		if clientID == "" {
			clientID = "oaiapp_fixture"
		}
		identity := f.ChatGPTIdentity
		identity.Subject = "user-fixture"
		now := f.now()
		tokens := SIWCTokens{
			ClientID: clientID, HostID: request.HostID, Scope: siwcScope,
			AccessToken:  fixtureJWT(map[string]any{"exp": now.Add(time.Hour).Unix()}),
			RefreshToken: "fixture-refresh", ExpiresAt: now.Add(time.Hour).UTC(),
			IDToken: fixtureJWT(map[string]any{"sub": identity.Subject, "email": identity.Email, "aud": clientID,
				"https://api.openai.com/auth": map[string]any{"chatgpt_account_id": identity.WorkspaceID, "chatgpt_plan_type": identity.Plan}}),
		}
		login.end(&LoginUpdate{Phase: PhaseSucceeded, Identity: identity, SIWC: &tokens})
		return nil
	}
	authorize := "https://auth.openai.com/api/accounts/authorize?fixture=1&redirect_uri=" + url.QueryEscape("http://127.0.0.1:1456/auth/callback")
	login.updates <- LoginUpdate{Phase: PhaseWaiting, Challenge: Challenge{OpenURL: authorize, LocalURL: authorize, CallbackPort: port, Expects: ExpectsCallback}}
	return login, nil
}

func (f *FixtureBackend) CheckClaude(_ context.Context, configDir string) (ClaudeStatus, error) {
	if configDir == "" {
		if f.HostClaude == nil {
			return ClaudeStatus{}, nil
		}
		return ClaudeStatus{LoggedIn: true, AuthMethod: "claude.ai", APIProvider: "firstParty", Identity: *f.HostClaude}, nil
	}
	var identity Identity
	if err := readFixtureJSON(filepath.Join(configDir, ".fixture-login.json"), &identity); err != nil {
		return ClaudeStatus{}, nil
	}
	return ClaudeStatus{LoggedIn: true, AuthMethod: "claude.ai", APIProvider: "firstParty", Identity: identity}, nil
}

func (f *FixtureBackend) CheckCodex(_ context.Context, home CodexAuthHome) (CodexStatus, error) {
	auth, err := readCodexAuth(home.Dir)
	if err != nil {
		return CodexStatus{}, nil
	}
	return CodexStatus{LoggedIn: true, Identity: auth.identity()}, nil
}

func (f *FixtureBackend) SignOutClaude(_ context.Context, configDir string) error {
	f.record("SignOutClaude:" + configDir)
	err := os.Remove(filepath.Join(configDir, ".fixture-login.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (f *FixtureBackend) SignOutCodex(_ context.Context, home CodexAuthHome) error {
	f.record("SignOutCodex:" + home.Dir)
	err := os.Remove(filepath.Join(home.Dir, "auth.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (f *FixtureBackend) RefreshCodex(_ context.Context, home CodexAuthHome) error {
	f.record("RefreshCodex:" + home.Dir)
	if _, err := readCodexAuth(home.Dir); err != nil {
		return err
	}
	f.mu.Lock()
	f.refresh++
	f.mu.Unlock()
	return f.writeCodexAuth(home.Dir, f.now())
}

// Refreshes counts RefreshCodex calls.
func (f *FixtureBackend) Refreshes() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.refresh
}

func (f *FixtureBackend) ProbeClaudeUsage(ctx context.Context, configDir string) (ClaudeProbe, error) {
	f.record("ProbeClaudeUsage:" + configDir)
	status, _ := f.CheckClaude(ctx, configDir)
	if !status.LoggedIn {
		return ClaudeProbe{}, nil
	}
	f.mu.Lock()
	if f.probes == nil {
		f.probes = map[string]int{}
	}
	n := f.probes["claude:"+configDir]
	f.probes["claude:"+configDir]++
	// Like Claude Code, the probe's request renews a due login first.
	if f.claudeExpired[configDir] {
		delete(f.claudeExpired, configDir)
		if f.claudeTokens == nil {
			f.claudeTokens = map[string]int{}
		}
		f.claudeTokens[configDir]++
	}
	f.mu.Unlock()
	now := f.now().UTC().Truncate(time.Hour)
	return ClaudeProbe{LoggedIn: true, Identity: status.Identity, Usage: Usage{
		Plan: status.Identity.Plan,
		Windows: []UsageWindow{
			{Kind: "five_hour", Label: "5h", UsedPercent: float64(20 + 5*(n%4)), ResetsAt: now.Add(2 * time.Hour).Format(time.RFC3339), DurationMinutes: 300},
			{Kind: "weekly", Label: "Weekly", UsedPercent: 40, ResetsAt: now.Add(72 * time.Hour).Format(time.RFC3339), DurationMinutes: 10080},
		},
	}}, nil
}

// ReadClaudeToken returns a deterministic fixture access token for a signed-in
// Claude config directory; each refresh yields a new one.
func (f *FixtureBackend) ReadClaudeToken(ctx context.Context, configDir string) (ClaudeToken, error) {
	f.record("ReadClaudeToken:" + configDir)
	status, _ := f.CheckClaude(ctx, configDir)
	if !status.LoggedIn {
		return ClaudeToken{}, errors.New("no fixture Claude login")
	}
	f.mu.Lock()
	generation, expired := f.claudeTokens[configDir], f.claudeExpired[configDir]
	f.mu.Unlock()
	expires := f.now().Add(8 * time.Hour)
	if expired {
		expires = f.now().Add(-time.Minute)
	}
	sum := ClaudeCredentialsService(configDir)
	return ClaudeToken{AccessToken: fmt.Sprintf("sk-ant-oat01-fixture-%s-%d", strings.TrimPrefix(sum, claudeCredentialsService), generation), ExpiresAt: expires}, nil
}

// ExpireClaudeToken makes a fixture Claude login's access token expired until
// the next usage probe refreshes it.
func (f *FixtureBackend) ExpireClaudeToken(configDir string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.claudeExpired == nil {
		f.claudeExpired = map[string]bool{}
	}
	f.claudeExpired[configDir] = true
}

func (f *FixtureBackend) ProbeCodexUsage(_ context.Context, home CodexAuthHome) (Usage, error) {
	f.record("ProbeCodexUsage:" + home.Dir)
	if _, err := readCodexAuth(home.Dir); err != nil {
		return Usage{}, err
	}
	f.mu.Lock()
	reset := f.reset[home.Dir]
	f.mu.Unlock()
	now := f.now().UTC().Truncate(time.Hour)
	fiveHour, credits := 15.0, 1
	if reset {
		fiveHour, credits = 0, 0
	}
	return Usage{Plan: f.ChatGPTIdentity.Plan, ResetCredits: &ResetCredits{Available: credits}, Windows: []UsageWindow{
		{Kind: "five_hour", Label: "5h", UsedPercent: fiveHour, ResetsAt: now.Add(3 * time.Hour).Format(time.RFC3339), DurationMinutes: 300},
		{Kind: "weekly", Label: "Weekly", UsedPercent: 30, ResetsAt: now.Add(96 * time.Hour).Format(time.RFC3339), DurationMinutes: 10080},
	}}, nil
}

func (f *FixtureBackend) ConsumeCodexReset(_ context.Context, home CodexAuthHome, idempotencyKey, _ string) (string, error) {
	f.record("ConsumeCodexReset:" + home.Dir)
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.reset == nil {
		f.reset, f.redeem = map[string]bool{}, map[string]bool{}
	}
	switch {
	case f.redeem[idempotencyKey]:
		return "alreadyRedeemed", nil
	case f.reset[home.Dir]:
		return "noCredit", nil
	}
	f.reset[home.Dir], f.redeem[idempotencyKey] = true, true
	return "reset", nil
}

func (f *FixtureBackend) RefreshSIWC(_ context.Context, tokens SIWCTokens) (SIWCTokens, error) {
	f.record("RefreshSIWC:" + tokens.ClientID)
	if tokens.RefreshToken == "" {
		return tokens, errors.New("no refresh token")
	}
	now := f.now()
	tokens.AccessToken = fixtureJWT(map[string]any{"exp": now.Add(time.Hour).Unix(), "n": now.UnixNano()})
	tokens.ExpiresAt = now.Add(time.Hour).UTC()
	return tokens, nil
}

func (f *FixtureBackend) RevokeSIWC(_ context.Context, tokens SIWCTokens) error {
	f.record("RevokeSIWC:" + tokens.ClientID)
	return nil
}

// writeCodexAuth writes a Codex-format auth.json for the ChatGPT identity
// with a ten-day access token, like Codex's own.
func (f *FixtureBackend) writeCodexAuth(dir string, now time.Time) error {
	identity := f.ChatGPTIdentity
	auth := map[string]any{
		"OPENAI_API_KEY": nil,
		"tokens": map[string]any{
			"id_token": fixtureJWT(map[string]any{"email": identity.Email,
				"https://api.openai.com/auth": map[string]any{"chatgpt_account_id": identity.WorkspaceID, "chatgpt_plan_type": identity.Plan}}),
			"access_token":  fixtureJWT(map[string]any{"exp": now.Add(240 * time.Hour).Unix(), "n": now.UnixNano()}),
			"refresh_token": "fixture-refresh",
			"account_id":    identity.WorkspaceID,
		},
		"last_refresh": now.UTC().Format(time.RFC3339Nano),
	}
	return writeFixtureJSON(filepath.Join(dir, "auth.json"), auth)
}

// fixtureJWT is an unsigned token carrying claims.
func fixtureJWT(claims map[string]any) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT"}`))
	payload, _ := json.Marshal(claims)
	return header + "." + base64.RawURLEncoding.EncodeToString(payload) + ".fixture"
}

func writeFixtureJSON(path string, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o600)
}

func readFixtureJSON(path string, value any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, value)
}
