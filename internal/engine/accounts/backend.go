package accounts

import (
	"context"
	"strings"
	"time"
)

// Backend runs the provider tools: every external effect of the engine. The
// exec backend runs the harness runtime's Claude Code and Codex and talks to
// OpenAI for Sign in with ChatGPT; FixtureBackend is deterministic and
// in-process for tests and the fixture gateway.
type Backend interface {
	// ClaudeLogin starts `claude auth login` in a config directory.
	ClaudeLogin(ctx context.Context, request ClaudeLoginRequest) (LoginDriver, error)
	// CodexLogin starts a Codex ChatGPT login in an auth home.
	CodexLogin(ctx context.Context, request CodexLoginRequest) (LoginDriver, error)
	// SIWCLogin starts a Sign in with ChatGPT authorization.
	SIWCLogin(ctx context.Context, request SIWCLoginRequest) (LoginDriver, error)

	// CheckClaude reports the login of a Claude config directory; "" is the
	// host's default (~/.claude).
	CheckClaude(ctx context.Context, configDir string) (ClaudeStatus, error)
	// CheckCodex reports the ChatGPT login of a Codex auth home.
	CheckCodex(ctx context.Context, home CodexAuthHome) (CodexStatus, error)
	// SignOutClaude runs `claude auth logout`, removing the credential.
	SignOutClaude(ctx context.Context, configDir string) error
	// SignOutCodex runs account/logout, removing auth.json.
	SignOutCodex(ctx context.Context, home CodexAuthHome) error
	// RefreshCodex asks Codex to rotate the home's tokens now.
	RefreshCodex(ctx context.Context, home CodexAuthHome) error

	// ProbeClaudeUsage reads plan usage through the Agent SDK. Claude Code
	// renews a due login before the request, so it also refreshes.
	ProbeClaudeUsage(ctx context.Context, configDir string) (ClaudeProbe, error)
	// ReadClaudeToken reads the access token and its expiry from Claude
	// Code's own store for a config directory ("" is the host default).
	// Only Oh My Pi turns with the account's opt-in use it (ADR 0007).
	ReadClaudeToken(ctx context.Context, configDir string) (ClaudeToken, error)
	// ProbeCodexUsage reads rate limits through account/rateLimits/read.
	ProbeCodexUsage(ctx context.Context, home CodexAuthHome) (Usage, error)
	// ConsumeCodexReset spends a rate-limit reset credit and returns the
	// outcome: reset, nothingToReset, noCredit or alreadyRedeemed.
	ConsumeCodexReset(ctx context.Context, home CodexAuthHome, idempotencyKey, creditID string) (string, error)

	// RefreshSIWC exchanges a Sign in with ChatGPT refresh token.
	RefreshSIWC(ctx context.Context, tokens SIWCTokens) (SIWCTokens, error)
	// RevokeSIWC revokes a Sign in with ChatGPT session.
	RevokeSIWC(ctx context.Context, tokens SIWCTokens) error
}

// ClaudeLoginRequest starts a Claude Code login.
type ClaudeLoginRequest struct {
	// ConfigDir is the account's CLAUDE_CONFIG_DIR, as a canonical string.
	ConfigDir string
	// SessionDir is private scratch space for the browser hook.
	SessionDir string
	// Email pre-fills the login once the account has a bound identity.
	Email string
}

// CodexLoginRequest starts a Codex login.
type CodexLoginRequest struct {
	Home CodexAuthHome
	// Flow is device_code or browser.
	Flow string
}

// SIWCLoginRequest starts a Sign in with ChatGPT authorization.
type SIWCLoginRequest struct {
	// ClientID is the account's issued client; empty registers one.
	ClientID string
	// IDTokenHint is this host's last ID token of the account, which skips the
	// account picker and consent on re-authorization.
	IDTokenHint string
	// HostID is ext_agent_host_id.
	HostID string
}

// CodexAuthHome is a CODEX_HOME holding a ChatGPT login.
type CodexAuthHome struct {
	Dir string
	// Managed homes are Dieter's per-account homes, which use Codex's file
	// credential store; a host home keeps the operator's configuration.
	Managed bool
}

// LoginDriver is one running provider login.
type LoginDriver interface {
	// Updates delivers the login's progress and is closed after a terminal
	// update or after Cancel.
	Updates() <-chan LoginUpdate
	// Submit hands a pasted code or a loopback callback URL to the login.
	Submit(ctx context.Context, code, callbackURL string) error
	// Cancel stops the login and its processes.
	Cancel()
}

// LoginUpdate is a driver's progress: waiting (with a challenge),
// completing, succeeded (with the verified identity) or failed.
type LoginUpdate struct {
	Phase     string
	Challenge Challenge
	Identity  Identity
	// SIWC carries the tokens of a successful Sign in with ChatGPT.
	SIWC                    *SIWCTokens
	ErrorCode, ErrorMessage string
}

// ClaudeStatus is `claude auth status --json`.
type ClaudeStatus struct {
	LoggedIn                bool
	AuthMethod, APIProvider string
	Identity                Identity
}

// Subscription reports a claude.ai login, the only kind a managed or host
// account represents.
func (c ClaudeStatus) Subscription() bool {
	return c.LoggedIn && (c.AuthMethod == "" || c.AuthMethod == "claude.ai") && (c.APIProvider == "" || c.APIProvider == "firstParty")
}

// CodexStatus is account/read of a Codex auth home.
type CodexStatus struct {
	LoggedIn bool
	Identity Identity
}

// ClaudeProbe is usage-claude.mjs's output.
type ClaudeProbe struct {
	LoggedIn bool     `json:"loggedIn"`
	Identity Identity `json:"identity"`
	Usage    Usage    `json:"usage"`
}

// ClaudeToken is a Claude login's current access token. Never a refresh
// token.
type ClaudeToken struct {
	AccessToken string
	ExpiresAt   time.Time
}

// SIWCTokens is one host's Sign in with ChatGPT session (siwc.json, 0600).
type SIWCTokens struct {
	ClientID          string    `json:"client_id"`
	HostID            string    `json:"ext_agent_host_id"`
	AccessToken       string    `json:"access_token"`
	RefreshToken      string    `json:"refresh_token"`
	IDToken           string    `json:"id_token"`
	Scope             string    `json:"scope"`
	ExpiresAt         time.Time `json:"expires_at"`
	EarliestRefreshAt time.Time `json:"earliest_refresh_at,omitzero"`
	SavedAt           time.Time `json:"saved_at"`
}

// SIWCPlanScope grants turns on the ChatGPT plan.
const SIWCPlanScope = "chatgpt.tokens.use.direct"

// PlanUsageGranted reports whether the session may use the ChatGPT plan.
func (t SIWCTokens) PlanUsageGranted() bool {
	for _, scope := range strings.Fields(t.Scope) {
		if scope == SIWCPlanScope {
			return true
		}
	}
	return false
}
