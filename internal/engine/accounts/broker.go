package accounts

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// Codex refresh triggers (plan §4.2): an access token within a day of expiry
// or a login not refreshed for a week is refreshed before a turn.
const (
	codexRefreshBefore = 24 * time.Hour
	codexRefreshEvery  = 7 * 24 * time.Hour
	siwcRefreshBefore  = 10 * time.Minute
	refreshTimeout     = 60 * time.Second
)

// codexAuth is the part of a Codex auth.json (file credential store) the
// broker uses.
type codexAuth struct {
	AccessToken string
	AccountID   string
	IDClaims    map[string]any
	Expires     time.Time
	LastRefresh time.Time
}

func readCodexAuth(dir string) (codexAuth, error) {
	var auth codexAuth
	// No Codex home (no HOME, no CODEX_HOME) means no login; never read
	// auth.json relative to the working directory.
	if dir == "" || !filepath.IsAbs(dir) {
		return auth, os.ErrNotExist
	}
	raw, err := os.ReadFile(filepath.Join(dir, "auth.json"))
	if err != nil {
		return auth, err
	}
	var file struct {
		Tokens *struct {
			IDToken     json.RawMessage `json:"id_token"`
			AccessToken string          `json:"access_token"`
			AccountID   string          `json:"account_id"`
		} `json:"tokens"`
		LastRefresh string `json:"last_refresh"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		return auth, fmt.Errorf("unreadable Codex auth.json: %w", err)
	}
	if file.Tokens == nil || file.Tokens.AccessToken == "" {
		return auth, errors.New("Codex auth.json holds no ChatGPT login")
	}
	auth.AccessToken, auth.AccountID = file.Tokens.AccessToken, file.Tokens.AccountID
	if claims := jwtClaims(file.Tokens.AccessToken); claims != nil {
		auth.Expires = claimTime(claims["exp"])
	}
	var idToken string
	if json.Unmarshal(file.Tokens.IDToken, &idToken) != nil {
		var wrapped struct {
			Raw string `json:"raw_jwt"`
		}
		_ = json.Unmarshal(file.Tokens.IDToken, &wrapped)
		idToken = wrapped.Raw
	}
	auth.IDClaims = jwtClaims(idToken)
	if auth.AccountID == "" {
		auth.AccountID = openAIClaim(auth.IDClaims, "chatgpt_account_id")
	}
	if t, err := time.Parse(time.RFC3339Nano, file.LastRefresh); err == nil {
		auth.LastRefresh = t
	}
	return auth, nil
}

// identity is the ChatGPT identity auth.json records.
func (a codexAuth) identity() Identity {
	identity := Identity{WorkspaceID: a.AccountID}
	if email, ok := a.IDClaims["email"].(string); ok {
		identity.Email = email
	}
	identity.Plan = openAIClaim(a.IDClaims, "chatgpt_plan_type")
	return identity
}

func (a codexAuth) due(now time.Time) bool {
	return !a.Expires.IsZero() && a.Expires.Before(now.Add(codexRefreshBefore)) ||
		!a.LastRefresh.IsZero() && a.LastRefresh.Before(now.Add(-codexRefreshEvery))
}

// codexHomeOf is where an account's Codex login lives on this machine.
func (s *Service) codexHomeOf(account Account) (CodexAuthHome, error) {
	switch account.Method {
	case MethodCodex:
		return CodexAuthHome{Dir: s.codexAuthDir(account.ID), Managed: true}, nil
	case MethodHost:
		home := s.hostCodexHome()
		if home == "" {
			return CodexAuthHome{}, fault.New(fault.FailedPrecondition, "this machine has no home directory for Codex")
		}
		return CodexAuthHome{Dir: home}, nil
	}
	return CodexAuthHome{}, fault.Errorf(fault.FailedPrecondition, "the %s login has no Codex home", account.Method)
}

// codexToken returns a ChatGPT access token of a codex or host account,
// asking Codex to refresh it first when it is due. One refresher acts per
// account at a time.
func (s *Service) codexToken(ctx context.Context, account Account) (string, error) {
	token, _, err := s.codexAccessToken(ctx, account)
	return token, err
}

// codexAccessToken is codexToken with the token's expiry.
func (s *Service) codexAccessToken(ctx context.Context, account Account) (string, time.Time, error) {
	home, err := s.codexHomeOf(account)
	if err != nil {
		return "", time.Time{}, err
	}
	release, err := s.lockAccount(ctx, account.ID)
	if err != nil {
		return "", time.Time{}, err
	}
	defer release()
	auth, err := readCodexAuth(home.Dir)
	if err != nil {
		s.markExpired(account.ID, "Codex has no ChatGPT login for this account on this machine")
		return "", time.Time{}, s.notSignedIn(account)
	}
	now := s.now()
	if !auth.due(now) {
		return auth.AccessToken, auth.Expires, nil
	}
	refreshCtx, cancel := context.WithTimeout(ctx, refreshTimeout)
	defer cancel()
	if err := s.backend.RefreshCodex(refreshCtx, home); err != nil {
		if auth.Expires.After(now) {
			s.log.Warn("Codex token refresh failed; using the current token", "account", account.ID, "error", err)
			return auth.AccessToken, auth.Expires, nil
		}
		s.markExpired(account.ID, "Codex could not refresh this account's ChatGPT login")
		return "", time.Time{}, s.notSignedIn(account)
	}
	refreshed, err := readCodexAuth(home.Dir)
	if err != nil {
		return "", time.Time{}, s.notSignedIn(account)
	}
	return refreshed.AccessToken, refreshed.Expires, nil
}

// TurnToken returns the current access token of a Sign in with ChatGPT
// account signed in on this machine, refreshing it when it is close to
// expiry.
func (s *Service) TurnToken(ctx context.Context, accountID string) (string, time.Time, error) {
	account, err := s.get(accountID)
	if err != nil {
		return "", time.Time{}, err
	}
	if account.Method != MethodSIWC {
		return "", time.Time{}, fault.New(fault.FailedPrecondition, "only Sign in with ChatGPT accounts hand out turn tokens")
	}
	tokens, err := s.siwcToken(ctx, account)
	if err != nil {
		return "", time.Time{}, err
	}
	return tokens.AccessToken, tokens.ExpiresAt, nil
}

func (s *Service) siwcToken(ctx context.Context, account Account) (SIWCTokens, error) {
	release, err := s.lockAccount(ctx, account.ID)
	if err != nil {
		return SIWCTokens{}, err
	}
	defer release()
	tokens, err := s.readSIWC(account.ID)
	if err != nil || tokens.AccessToken == "" {
		return SIWCTokens{}, s.notSignedIn(account)
	}
	now := s.now()
	if tokens.ExpiresAt.After(now.Add(siwcRefreshBefore)) {
		return tokens, nil
	}
	refreshCtx, cancel := context.WithTimeout(ctx, refreshTimeout)
	defer cancel()
	refreshed, err := s.backend.RefreshSIWC(refreshCtx, tokens)
	if err != nil {
		if tokens.ExpiresAt.After(now) {
			s.log.Warn("Sign in with ChatGPT refresh failed; using the current token", "account", account.ID, "error", err)
			return tokens, nil
		}
		s.markExpired(account.ID, "the Sign in with ChatGPT session could not be refreshed")
		return SIWCTokens{}, s.notSignedIn(account)
	}
	if err := s.saveSIWC(account.ID, refreshed); err != nil {
		return SIWCTokens{}, err
	}
	return refreshed, nil
}

func (s *Service) notSignedIn(account Account) error {
	return fault.Errorf(fault.FailedPrecondition, "%s isn't signed in on %s", account.Label, s.machineName())
}

// hostID is this host's ext_agent_host_id for Sign in with ChatGPT.
func (s *Service) hostID() string {
	if s.opts.HostID != nil {
		if id := s.opts.HostID(); id != "" {
			return id
		}
	}
	path := filepath.Join(s.store.ProviderAccountsDir(), "host-id")
	if raw, err := os.ReadFile(path); err == nil {
		if id := strings.TrimSpace(string(raw)); strings.HasPrefix(id, "urn:uuid:") {
			return id
		}
	}
	buffer := make([]byte, 16)
	_, _ = rand.Read(buffer)
	buffer[6] = buffer[6]&0x0f | 0x40
	buffer[8] = buffer[8]&0x3f | 0x80
	text := hex.EncodeToString(buffer)
	id := "urn:uuid:" + text[0:8] + "-" + text[8:12] + "-" + text[12:16] + "-" + text[16:20] + "-" + text[20:]
	if err := s.writePrivate(path, []byte(id+"\n")); err != nil {
		s.log.Warn("could not persist the Sign in with ChatGPT host ID", "error", err)
	}
	return id
}

// jwtClaims decodes a JWT's payload without verifying it: the tokens come
// from the provider's own tool or token endpoint over TLS, and Dieter only
// reads expiry and identity claims from them.
func jwtClaims(token string) map[string]any {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return nil
	}
	var claims map[string]any
	if json.Unmarshal(raw, &claims) != nil {
		return nil
	}
	return claims
}

func claimTime(value any) time.Time {
	if seconds, ok := value.(float64); ok && seconds > 0 {
		return time.Unix(int64(seconds), 0)
	}
	return time.Time{}
}

// openAIClaim reads a field of the https://api.openai.com/auth claim.
func openAIClaim(claims map[string]any, name string) string {
	auth, _ := claims["https://api.openai.com/auth"].(map[string]any)
	value, _ := auth[name].(string)
	return value
}
