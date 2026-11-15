package accounts

import (
	"context"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
)

// Turn base URLs: ChatGPT logins go to the Codex backend, API keys and Sign
// in with ChatGPT to the public API.
const (
	chatGPTCodexBaseURL = "https://chatgpt.com/backend-api/codex"
	openAIAPIBaseURL    = "https://api.openai.com/v1"
)

// harnessProvider maps a harness to the provider whose accounts it runs on.
func harnessProvider(harness string) string {
	switch harness {
	case "claude-code":
		return ProviderClaude
	case "codex":
		return ProviderChatGPT
	}
	return ""
}

// ResolveTurn returns the credentials a turn of harness needs on accountID.
// An empty accountID resolves to the provider's default account, else the
// single account of that provider signed in on this machine. Harnesses
// without accounts get an empty TurnAuth and must not name one.
func (s *Service) ResolveTurn(ctx context.Context, harness, accountID string) (TurnAuth, error) {
	provider := harnessProvider(harness)
	if provider == "" {
		if accountID != "" {
			return TurnAuth{}, fault.Invalidf("the %s harness does not use provider accounts", harness)
		}
		return TurnAuth{}, nil
	}
	r, err := s.load()
	if err != nil {
		return TurnAuth{}, err
	}
	daemon := s.daemonID()
	account, err := s.resolveAccount(r, provider, accountID, daemon)
	if err != nil {
		return TurnAuth{}, err
	}
	if !r.signedIn(account.ID, daemon) {
		return TurnAuth{}, s.notSignedIn(account)
	}
	auth := TurnAuth{AccountID: account.ID}
	switch provider {
	case ProviderClaude:
		err = s.claudeTurn(account, &auth)
	case ProviderChatGPT:
		err = s.codexTurn(ctx, account, &auth)
	}
	if err != nil {
		return TurnAuth{}, err
	}
	return auth, nil
}

func (s *Service) resolveAccount(r registry, provider, accountID, daemon string) (Account, error) {
	if accountID != "" {
		account, ok := r.account(accountID)
		if !ok {
			return Account{}, fault.Errorf(fault.FailedPrecondition, "the chosen %s account was removed; choose another in Settings › Providers", providerName(provider))
		}
		if account.Provider != provider {
			return Account{}, fault.Invalidf("%s is a %s account", account.Label, providerName(account.Provider))
		}
		return account, nil
	}
	fallback, hasDefault := r.account(r.defaults[provider])
	hasDefault = hasDefault && fallback.Provider == provider
	if hasDefault && r.signedIn(fallback.ID, daemon) {
		return fallback, nil
	}
	// A default signed in only elsewhere yields to the one account that is
	// signed in here.
	var ready []Account
	for id := range r.accounts {
		if account, ok := r.account(id); ok && account.Provider == provider && r.signedIn(id, daemon) {
			ready = append(ready, account)
		}
	}
	switch {
	case len(ready) == 1:
		return ready[0], nil
	case hasDefault:
		return fallback, nil
	case len(ready) == 0:
		return Account{}, fault.Errorf(fault.FailedPrecondition, "Add a %s account in Settings › Providers", providerName(provider))
	}
	return Account{}, fault.Errorf(fault.FailedPrecondition, "Choose a default %s account in Settings › Providers", providerName(provider))
}

// claudeTurn lets Claude Code use its own login: the account's config
// directory, with host keys masked so they cannot override it.
func (s *Service) claudeTurn(account Account, auth *TurnAuth) error {
	masked := map[string]string{"ANTHROPIC_API_KEY": "", "ANTHROPIC_AUTH_TOKEN": "", "CLAUDE_CODE_OAUTH_TOKEN": ""}
	switch account.Method {
	case MethodClaudeCode:
		dir, err := s.prepareClaudeHome(account.ID)
		if err != nil {
			return err
		}
		masked["CLAUDE_CONFIG_DIR"] = dir
		auth.Env, auth.Auth = masked, map[string]string{}
	case MethodHost:
		auth.Env, auth.Auth = masked, map[string]string{}
	case MethodEnvironment:
		key, value := s.claudeEnvironmentKey()
		if value == "" {
			return s.notSignedIn(account)
		}
		auth.Auth = map[string]string{key: value}
		if base := s.opts.Environment["ANTHROPIC_BASE_URL"]; base != "" {
			auth.Auth["ANTHROPIC_BASE_URL"] = base
		}
	default:
		return fault.Errorf(fault.FailedPrecondition, "%s cannot run Claude Code turns", account.Label)
	}
	return nil
}

// codexTurn hands the account's token to the bridge's provider in the
// shared Dieter Codex home.
func (s *Service) codexTurn(ctx context.Context, account Account, auth *TurnAuth) error {
	if err := s.renderCodexHome(); err != nil {
		return err
	}
	auth.Env = map[string]string{"CODEX_HOME": s.CodexHome()}
	switch account.Method {
	case MethodCodex, MethodHost:
		token, err := s.codexToken(ctx, account)
		if err != nil {
			return err
		}
		auth.Auth = map[string]string{"CODEX_API_KEY": token, "OPENAI_BASE_URL": chatGPTCodexBaseURL}
	case MethodSIWC:
		tokens, err := s.siwcToken(ctx, account)
		if err != nil {
			return err
		}
		auth.Auth = map[string]string{"CODEX_API_KEY": tokens.AccessToken, "OPENAI_BASE_URL": openAIAPIBaseURL}
	case MethodEnvironment:
		_, value := s.openAIEnvironmentKey()
		if value == "" {
			return s.notSignedIn(account)
		}
		base := s.opts.Environment["OPENAI_BASE_URL"]
		if base == "" {
			base = openAIAPIBaseURL
		}
		auth.Auth = map[string]string{"CODEX_API_KEY": value, "OPENAI_BASE_URL": base}
	default:
		return fault.Errorf(fault.FailedPrecondition, "%s cannot run Codex turns", account.Label)
	}
	return nil
}

func (s *Service) claudeEnvironmentKey() (string, string) {
	for _, key := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"} {
		if value := s.opts.Environment[key]; value != "" {
			return key, value
		}
	}
	return "", ""
}

func (s *Service) openAIEnvironmentKey() (string, string) {
	for _, key := range []string{"CODEX_API_KEY", "OPENAI_API_KEY"} {
		if value := s.opts.Environment[key]; value != "" {
			return key, value
		}
	}
	return "", ""
}

// QuickTitleAuth is the Codex turn auth of the default ChatGPT account signed
// in on this machine, for quick task titles. Without one, titles are skipped.
func (s *Service) QuickTitleAuth(ctx context.Context) (TurnAuth, bool) {
	auth, err := s.ResolveTurn(ctx, "codex", "")
	if err != nil {
		return TurnAuth{}, false
	}
	return auth, true
}

// MarkExpired records that a turn's provider rejected this machine's login of
// an account (runner "auth-failure" frames). A status check follows shortly:
// Claude Code refreshes its own store after a rejected request, so the login
// may recover by itself. It never blocks the caller.
func (s *Service) MarkExpired(accountID, reason string) {
	s.async(func() { s.markExpired(accountID, reason) })
}

func (s *Service) markExpired(accountID, reason string) {
	if !schema.ValidProviderAccountID(accountID) {
		return
	}
	err := s.updateLogin(accountID, func(record *schema.ProviderLoginRecord, exists bool) bool {
		if !exists || record.State != StateSignedIn {
			return false
		}
		record.State = StateExpired
		record.Error = &schema.ProviderLoginError{Code: "auth_rejected", Message: singleLine(reason, 512)}
		return true
	})
	if err != nil {
		s.log.Warn("could not record an expired provider login", "account", accountID, "error", err)
		return
	}
	s.scheduleCheck(accountID, time.Minute)
	s.audit(accountID, "auth_rejected", "expired")
}
