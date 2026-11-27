package accounts

import (
	"context"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// Oh My Pi turns run their implementation model and their advisor model on
// Dieter's provider accounts (ADR 0007). OMP never holds a login: its rendered
// models.yml asks `dieter provider token --turn --provider P` for the access
// token of the account its turn uses for provider P. The daemon serves only
// access tokens and keeps them fresh through each provider's own tool (Codex's
// app-server, Claude Code's usage probe), so every login keeps exactly one
// refresher.

// OMP model selectors name their provider: "anthropic/claude-opus-5-5",
// "openai-codex/gpt-6-sol".
const (
	ompAnthropicPrefix = "anthropic/"
	ompCodexPrefix     = "openai-codex/"
)

// claudeRefreshBefore is Claude Code's own refresh window: it renews a login
// only within five minutes of expiry, so asking earlier changes nothing.
const claudeRefreshBefore = 5 * time.Minute

// OMPModelProvider is the provider whose accounts an OMP model runs on, or ""
// for a model Dieter does not manage.
func OMPModelProvider(selector string) string {
	selector = strings.TrimSpace(selector)
	switch {
	case strings.HasPrefix(selector, ompAnthropicPrefix):
		return ProviderClaude
	case strings.HasPrefix(selector, ompCodexPrefix):
		return ProviderChatGPT
	}
	return ""
}

// OMPTurn is the accounts an OMP turn uses.
type OMPTurn struct {
	// AccountID runs the implementation model.
	AccountID string
	// AdvisorAccountID runs the advisor model: AccountID when both models
	// use one provider (OMP holds one credential per provider), "" without
	// an advisor.
	AdvisorAccountID string
}

// ResolveOMPTurn resolves the accounts of an OMP turn and makes sure their
// access tokens are fresh. Empty account IDs fall back like other turns: the
// provider default, else the one account signed in here; so does an advisor
// account of the other provider, left from an earlier advisor model. Both
// accounts must be signed in on this machine, and Claude accounts need Oh My
// Pi access. Refreshing here keeps the token helper OMP runs mid-turn (10 s
// budget) a plain read.
func (s *Service) ResolveOMPTurn(ctx context.Context, model, accountID, advisorModel, advisorAccountID string) (OMPTurn, error) {
	provider := OMPModelProvider(model)
	if provider == "" {
		return OMPTurn{}, fault.Invalidf("Oh My Pi runs Claude and ChatGPT models only, not %q", model)
	}
	main, err := s.readyOMPAccount(ctx, provider, accountID)
	if err != nil {
		return OMPTurn{}, err
	}
	turn := OMPTurn{AccountID: main.ID}
	advisorModel = strings.TrimSpace(advisorModel)
	if advisorModel == "" || advisorModel == "off" {
		return turn, nil
	}
	advisorProvider := OMPModelProvider(advisorModel)
	switch advisorProvider {
	case "":
		return OMPTurn{}, fault.Invalidf("Oh My Pi's advisor runs Claude and ChatGPT models only, not %q", advisorModel)
	case provider:
		turn.AdvisorAccountID = main.ID
		return turn, nil
	}
	if advisorAccountID != "" {
		// The advisor's account was chosen for another provider's model (the
		// advisor moved to this provider since): use this provider's default.
		if account, err := s.get(advisorAccountID); err == nil && account.Provider != advisorProvider {
			advisorAccountID = ""
		}
	}
	advisor, err := s.readyOMPAccount(ctx, advisorProvider, advisorAccountID)
	if err != nil {
		return OMPTurn{}, err
	}
	turn.AdvisorAccountID = advisor.ID
	return turn, nil
}

func (s *Service) readyOMPAccount(ctx context.Context, provider, accountID string) (Account, error) {
	r, err := s.load()
	if err != nil {
		return Account{}, err
	}
	daemon := s.daemonID()
	account, err := s.resolveAccount(r, provider, accountID, daemon)
	if err != nil {
		return Account{}, err
	}
	if !r.signedIn(account.ID, daemon) {
		return Account{}, s.notSignedIn(account)
	}
	if _, _, err := s.ompToken(ctx, account); err != nil {
		return Account{}, err
	}
	return account, nil
}

// OMPTurnToken returns the access token an OMP turn uses for provider: the
// one of the turn's accounts (implementation or advisor) of that provider.
func (s *Service) OMPTurnToken(ctx context.Context, provider string, accountIDs ...string) (string, time.Time, error) {
	for _, id := range accountIDs {
		if id == "" {
			continue
		}
		account, err := s.get(id)
		if err != nil {
			continue
		}
		if account.Provider == provider {
			return s.ompToken(ctx, account)
		}
	}
	return "", time.Time{}, fault.Errorf(fault.FailedPrecondition, "this turn uses no %s account", providerName(provider))
}

// ompToken is an account's current access token for OMP.
func (s *Service) ompToken(ctx context.Context, account Account) (string, time.Time, error) {
	switch account.Provider {
	case ProviderClaude:
		if !account.OMPAccess {
			return "", time.Time{}, fault.Errorf(fault.FailedPrecondition, "Allow Oh My Pi to use %s in Settings › Providers first", account.Label)
		}
		switch account.Method {
		case MethodClaudeCode, MethodHost:
			return s.claudeAccessToken(ctx, account)
		case MethodEnvironment:
			// An Anthropic API key; OMP shapes non-OAuth keys as API keys.
			_, value := s.claudeEnvironmentKey()
			if value == "" {
				return "", time.Time{}, s.notSignedIn(account)
			}
			return value, time.Time{}, nil
		}
	case ProviderChatGPT:
		switch account.Method {
		case MethodCodex, MethodHost:
			return s.codexAccessToken(ctx, account)
		case MethodSIWC, MethodEnvironment:
			// OMP's openai-codex provider talks to the ChatGPT Codex backend,
			// which takes ChatGPT logins only.
			return "", time.Time{}, fault.Errorf(fault.FailedPrecondition, "Oh My Pi runs ChatGPT models only on ChatGPT logins; %s is not one", account.Label)
		}
	}
	return "", time.Time{}, fault.Errorf(fault.FailedPrecondition, "%s cannot run Oh My Pi turns", account.Label)
}

// claudeConfigArg is the CLAUDE_CONFIG_DIR a Claude login lives under, as
// Claude Code was given it ("" for the host default): Claude Code names its
// store after this exact string.
func (s *Service) claudeConfigArg(account Account) (string, error) {
	if account.Method == MethodClaudeCode {
		return s.prepareClaudeHome(account.ID)
	}
	return strings.TrimSpace(s.opts.Environment["CLAUDE_CONFIG_DIR"]), nil
}

// claudeAccessToken reads a Claude login's access token from Claude Code's own
// store. When it is due, Claude Code refreshes it: its prompt-less usage probe
// is a request, and Claude Code renews its login before any request. Dieter
// never reads, uses or stores the refresh token.
func (s *Service) claudeAccessToken(ctx context.Context, account Account) (string, time.Time, error) {
	dir, err := s.claudeConfigArg(account)
	if err != nil {
		return "", time.Time{}, err
	}
	release, err := s.lockAccount(ctx, account.ID)
	if err != nil {
		return "", time.Time{}, err
	}
	defer release()
	token, err := s.backend.ReadClaudeToken(ctx, dir)
	if err != nil || token.AccessToken == "" {
		return "", time.Time{}, s.notSignedIn(account)
	}
	now := s.now()
	if token.ExpiresAt.IsZero() || token.ExpiresAt.After(now.Add(claudeRefreshBefore)) {
		return token.AccessToken, token.ExpiresAt, nil
	}
	refreshCtx, cancel := context.WithTimeout(ctx, refreshTimeout)
	defer cancel()
	if _, err := s.backend.ProbeClaudeUsage(refreshCtx, dir); err != nil {
		s.log.Warn("Claude Code could not refresh a login for Oh My Pi", "account", account.ID, "error", err)
	}
	refreshed, err := s.backend.ReadClaudeToken(ctx, dir)
	if err != nil || refreshed.AccessToken == "" || !refreshed.ExpiresAt.After(now) {
		s.markExpired(account.ID, "Claude Code could not refresh this account's login")
		return "", time.Time{}, s.notSignedIn(account)
	}
	return refreshed.AccessToken, refreshed.ExpiresAt, nil
}
