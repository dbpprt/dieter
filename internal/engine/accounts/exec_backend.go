package accounts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/harness/agentexec"
	"github.com/dbpprt/dieter/internal/harness/codexrpc"
	"github.com/dbpprt/dieter/internal/platform/fault"
)

// execOptions configures the real backend.
type execOptions struct {
	RuntimeDir  func(context.Context) (string, error)
	HostHome    string
	Environment map[string]string
	Clock       func() time.Time
}

// execBackend runs the harness runtime's Claude Code and Codex and talks to
// OpenAI's authorization server for Sign in with ChatGPT.
type execBackend struct {
	runtimeDir func(context.Context) (string, error)
	hostHome   string
	env        map[string]string
	now        func() time.Time
	// issuer is OpenAI's authorization server; tests replace it.
	issuer string
	http   *http.Client
	// codexArgs precede Codex's subcommand for managed homes.
	host agentexec.Host
}

const openAIIssuer = "https://auth.openai.com"

func newExecBackend(options execOptions) *execBackend {
	return &execBackend{
		runtimeDir: options.RuntimeDir, hostHome: options.HostHome, env: options.Environment, now: options.Clock,
		issuer: openAIIssuer, http: &http.Client{Timeout: 30 * time.Second}, host: agentexec.CurrentHost(),
	}
}

func (b *execBackend) runtime(ctx context.Context) (string, error) {
	if b.runtimeDir == nil {
		return "", fault.New(fault.Unavailable, "the harness runtime is not available")
	}
	return b.runtimeDir(ctx)
}

func (b *execBackend) claudePath(ctx context.Context) (string, error) {
	runtime, err := b.runtime(ctx)
	if err != nil {
		return "", err
	}
	return agentexec.ClaudeFor(runtime, b.host)
}

func (b *execBackend) codexPath(ctx context.Context) (string, error) {
	runtime, err := b.runtime(ctx)
	if err != nil {
		return "", err
	}
	return agentexec.CodexFor(runtime, b.host)
}

// baseEnv is the minimal environment provider tools run with: never the
// daemon's API keys or Dieter's own variables.
func (b *execBackend) baseEnv() []string {
	env := []string{"HOME=" + b.hostHome}
	if b.env["PATH"] == "" {
		env = append(env, "PATH=/usr/bin:/bin:/usr/sbin:/sbin")
	}
	for _, key := range []string{"PATH", "USER", "LOGNAME", "LANG", "TMPDIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE"} {
		if value := b.env[key]; value != "" {
			env = append(env, key+"="+value)
		}
	}
	return env
}

func (b *execBackend) claudeEnv(configDir string) []string {
	env := b.baseEnv()
	if configDir != "" {
		env = append(env, "CLAUDE_CONFIG_DIR="+configDir)
	}
	return env
}

// runCapped runs a short command and returns its stdout, bounded to 64 KiB.
func runCapped(ctx context.Context, path string, args, env []string, dir string) ([]byte, error) {
	command := exec.CommandContext(ctx, path, args...)
	agentexec.PrepareCommand(command, true)
	command.Env, command.Dir = env, dir
	command.WaitDelay = 2 * time.Second
	stdout := &capped{limit: 64 << 10}
	stderr := &capped{limit: 4 << 10}
	command.Stdout, command.Stderr = stdout, stderr
	err := command.Run()
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = strings.TrimSpace(stdout.String())
		}
		if index := strings.LastIndexByte(detail, '\n'); index >= 0 {
			detail = detail[index+1:]
		}
		if detail != "" {
			return stdout.Bytes(), fmt.Errorf("%s %s failed: %w: %s", filepath.Base(path), strings.Join(args, " "), err, singleLine(detail, 300))
		}
		return stdout.Bytes(), fmt.Errorf("%s %s failed: %w", filepath.Base(path), strings.Join(args, " "), err)
	}
	if stdout.exceeded {
		return nil, fmt.Errorf("%s %s wrote more than 64 KiB", filepath.Base(path), strings.Join(args, " "))
	}
	return stdout.Bytes(), nil
}

// claudeAuthStatus is `claude auth status --json`.
type claudeAuthStatus struct {
	LoggedIn         bool   `json:"loggedIn"`
	AuthMethod       string `json:"authMethod"`
	APIProvider      string `json:"apiProvider"`
	Email            string `json:"email"`
	OrgID            string `json:"orgId"`
	OrgName          string `json:"orgName"`
	SubscriptionType string `json:"subscriptionType"`
}

func (b *execBackend) CheckClaude(ctx context.Context, configDir string) (ClaudeStatus, error) {
	claude, err := b.claudePath(ctx)
	if err != nil {
		return ClaudeStatus{}, err
	}
	output, err := runCapped(ctx, claude, []string{"auth", "status", "--json"}, b.claudeEnv(configDir), b.hostHome)
	var status claudeAuthStatus
	if parseErr := json.Unmarshal(bytes.TrimSpace(output), &status); parseErr != nil {
		if err != nil {
			return ClaudeStatus{}, err
		}
		return ClaudeStatus{}, fmt.Errorf("claude auth status returned unreadable output: %w", parseErr)
	}
	// A signed-out CLI may exit non-zero after printing its status.
	return ClaudeStatus{
		LoggedIn: status.LoggedIn, AuthMethod: status.AuthMethod, APIProvider: status.APIProvider,
		Identity: Identity{Email: status.Email, OrganizationID: status.OrgID, Organization: status.OrgName, Plan: status.SubscriptionType},
	}, nil
}

func (b *execBackend) SignOutClaude(ctx context.Context, configDir string) error {
	if configDir == "" {
		return errors.New("refusing to sign the host's Claude Code login out")
	}
	claude, err := b.claudePath(ctx)
	if err != nil {
		return err
	}
	_, err = runCapped(ctx, claude, []string{"auth", "logout"}, b.claudeEnv(configDir), b.hostHome)
	return err
}

func (b *execBackend) ProbeClaudeUsage(ctx context.Context, configDir string) (ClaudeProbe, error) {
	runtime, err := b.runtime(ctx)
	if err != nil {
		return ClaudeProbe{}, err
	}
	node, err := agentexec.Node(b.env["PATH"])
	if err != nil {
		return ClaudeProbe{}, err
	}
	output, err := runCapped(ctx, node, []string{filepath.Join(runtime, "usage-claude.mjs")}, b.claudeEnv(configDir), runtime)
	if err != nil {
		return ClaudeProbe{}, err
	}
	var probe ClaudeProbe
	if err := json.Unmarshal(bytes.TrimSpace(output), &probe); err != nil {
		return ClaudeProbe{}, fmt.Errorf("the Claude usage probe returned unreadable output: %w", err)
	}
	return probe, nil
}

// startCodex runs `codex app-server` on an auth home. Managed homes use
// Codex's file credential store, so the login lives in auth.json there.
func (b *execBackend) startCodex(ctx context.Context, home CodexAuthHome) (*codexrpc.Client, error) {
	codex, err := b.codexPath(ctx)
	if err != nil {
		return nil, err
	}
	args := []string{"app-server"}
	if home.Managed {
		args = []string{"-c", `cli_auth_credentials_store="file"`, "app-server"}
	}
	env := append(b.baseEnv(), "CODEX_HOME="+home.Dir)
	startCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return codexrpc.Start(startCtx, codexrpc.Options{Path: codex, Args: args, Env: env, Dir: home.Dir})
}

// withCodex runs one short exchange with an app-server on home.
func (b *execBackend) withCodex(ctx context.Context, home CodexAuthHome, use func(*codexrpc.Client) error) error {
	client, err := b.startCodex(ctx, home)
	if err != nil {
		return err
	}
	defer client.Close()
	return use(client)
}

// codexAccount is account/read's result.
type codexAccount struct {
	Account *struct {
		Type     string  `json:"type"`
		Email    *string `json:"email"`
		PlanType *string `json:"planType"`
	} `json:"account"`
}

func codexIdentity(read codexAccount, home string) (CodexStatus, error) {
	if read.Account == nil || read.Account.Type != "chatgpt" {
		return CodexStatus{}, nil
	}
	status := CodexStatus{LoggedIn: true}
	if read.Account.Email != nil {
		status.Identity.Email = *read.Account.Email
	}
	if read.Account.PlanType != nil {
		status.Identity.Plan = *read.Account.PlanType
	}
	// account/read omits the ChatGPT account ID; auth.json records it.
	if auth, err := readCodexAuth(home); err == nil {
		status.Identity.WorkspaceID = auth.AccountID
		if status.Identity.Email == "" {
			status.Identity.Email = auth.identity().Email
		}
	}
	return status, nil
}

func (b *execBackend) CheckCodex(ctx context.Context, home CodexAuthHome) (CodexStatus, error) {
	var status CodexStatus
	err := b.withCodex(ctx, home, func(client *codexrpc.Client) error {
		var read codexAccount
		if err := client.Request(ctx, "account/read", map[string]any{}, &read); err != nil {
			return err
		}
		var err error
		status, err = codexIdentity(read, home.Dir)
		return err
	})
	return status, err
}

func (b *execBackend) SignOutCodex(ctx context.Context, home CodexAuthHome) error {
	if !home.Managed {
		return errors.New("refusing to sign the host's Codex login out")
	}
	return b.withCodex(ctx, home, func(client *codexrpc.Client) error {
		return client.Request(ctx, "account/logout", nil, nil)
	})
}

func (b *execBackend) RefreshCodex(ctx context.Context, home CodexAuthHome) error {
	return b.withCodex(ctx, home, func(client *codexrpc.Client) error {
		var read codexAccount
		if err := client.Request(ctx, "account/read", map[string]any{"refreshToken": true}, &read); err != nil {
			return err
		}
		if read.Account == nil {
			return errors.New("Codex reports no ChatGPT login")
		}
		return nil
	})
}

func (b *execBackend) ProbeCodexUsage(ctx context.Context, home CodexAuthHome) (Usage, error) {
	var usage Usage
	err := b.withCodex(ctx, home, func(client *codexrpc.Client) error {
		var limits codexRateLimits
		if err := client.Request(ctx, "account/rateLimits/read", map[string]any{"excludeResetCreditDetails": true}, &limits); err != nil {
			return err
		}
		usage = codexUsage(limits)
		return nil
	})
	return usage, err
}

func (b *execBackend) ConsumeCodexReset(ctx context.Context, home CodexAuthHome, idempotencyKey, creditID string) (string, error) {
	var outcome string
	err := b.withCodex(ctx, home, func(client *codexrpc.Client) error {
		params := map[string]any{"idempotencyKey": idempotencyKey}
		if creditID != "" {
			params["creditId"] = creditID
		}
		var result struct {
			Outcome string `json:"outcome"`
		}
		if err := client.Request(ctx, "account/rateLimitResetCredit/consume", params, &result); err != nil {
			return err
		}
		outcome = result.Outcome
		return nil
	})
	return outcome, err
}

// capped is a bounded output buffer.
type capped struct {
	mu       sync.Mutex
	limit    int
	buffer   bytes.Buffer
	exceeded bool
}

func (c *capped) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if room := c.limit - c.buffer.Len(); room < len(p) {
		c.exceeded = true
		if room > 0 {
			c.buffer.Write(p[:room])
		}
		return len(p), nil
	}
	c.buffer.Write(p)
	return len(p), nil
}

func (c *capped) Bytes() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]byte(nil), c.buffer.Bytes()...)
}

func (c *capped) String() string { return string(c.Bytes()) }

// drain reads and discards a bounded response body.
func drain(body io.ReadCloser) {
	_, _ = io.Copy(io.Discard, io.LimitReader(body, 64<<10))
	_ = body.Close()
}
