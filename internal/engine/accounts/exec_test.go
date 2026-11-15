//go:build unix

package accounts

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// execHarness runs the real exec backend against fake provider tools.
func execHarness(t *testing.T, scenario string, options ...option) *harness {
	t.Helper()
	runtime := fakeRuntime(t, scenario)
	options = append([]option{withRuntime(runtime), withBackend(nil), withEnvironment(map[string]string{"PATH": os.Getenv("PATH")})}, options...)
	return newHarness(t, "d_one", options...)
}

func TestExecClaudePasteCode(t *testing.T) {
	t.Parallel()
	h := execHarness(t, "")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	login, err := h.svc.StartLogin(ctx, work.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if login.Phase != PhaseWaiting || !strings.Contains(login.Challenge.OpenURL, url.QueryEscape("https://platform.claude.com/oauth/code/callback")) {
		t.Fatalf("challenge = %+v", login)
	}
	if !strings.Contains(login.Challenge.LocalURL, "localhost%3A") || login.Challenge.CallbackPort == 0 {
		t.Fatalf("local URL from the browser hook = %+v", login.Challenge)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "FIXTURE-CODE#S1", ""); err != nil {
		t.Fatal(err)
	}
	final := waitLogin(t, h.svc, login.ID)
	want := Identity{Email: "alice@example.com", OrganizationID: "org_1", Organization: "Org One", Plan: "max"}
	if final.Phase != PhaseSucceeded || final.Identity != want {
		t.Fatalf("final = %+v", final)
	}
	if _, err := os.Stat(filepath.Join(h.svc.claudeDir(work.ID), ".fake-login.json")); err != nil {
		t.Fatalf("Claude Code did not sign in in the account directory: %v", err)
	}
	// A status check asks Claude Code in the same directory.
	if account, err := h.svc.Check(ctx, work.ID); err != nil || account.Logins[0].State != StateSignedIn {
		t.Fatalf("check = %+v, %v", account, err)
	}
	// Sign-out runs `claude auth logout` there.
	if _, err := h.svc.SignOut(ctx, work.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(h.svc.claudeDir(work.ID), ".logged-out")); err != nil {
		t.Fatalf("claude auth logout did not run: %v", err)
	}
}

func TestExecClaudeForwardedCallbackAndEmailHint(t *testing.T) {
	t.Parallel()
	h := execHarness(t, "")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	if _, err := h.svc.bindIdentity(work.ID, Identity{Email: "alice@example.com", OrganizationID: "org_1"}); err != nil {
		t.Fatal(err)
	}
	login, err := h.svc.StartLogin(ctx, work.ID, FlowBrowser)
	if err != nil {
		t.Fatal(err)
	}
	port := login.Challenge.CallbackPort
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "", fmt.Sprintf("http://localhost:%d/callback?code=good&state=S1", port+1)); kindOf(err) != fault.Invalid {
		t.Fatalf("wrong port = %v", err)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "", fmt.Sprintf("http://localhost:%d/callback?code=good&state=other", port)); kindOf(err) != fault.Invalid || !strings.Contains(err.Error(), "HTTP 400") {
		t.Fatalf("rejected callback = %v", err)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "", fmt.Sprintf("http://localhost:%d/callback?code=good&state=S1", port)); err != nil {
		t.Fatal(err)
	}
	if final := waitLogin(t, h.svc, login.ID); final.Phase != PhaseSucceeded {
		t.Fatalf("final = %+v", final)
	}
	email, err := os.ReadFile(filepath.Join(h.svc.claudeDir(work.ID), ".login-email"))
	if err != nil || string(email) != "alice@example.com" {
		t.Fatalf("--email = %q, %v", email, err)
	}
}

func TestExecClaudeRejectedCode(t *testing.T) {
	t.Parallel()
	h := execHarness(t, "")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	login, err := h.svc.StartLogin(ctx, work.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "nope", ""); err != nil {
		t.Fatal(err)
	}
	final := waitLogin(t, h.svc, login.ID)
	if final.Phase != PhaseFailed || !strings.Contains(final.ErrorMessage, "Invalid code") {
		t.Fatalf("final = %+v", final)
	}
	if _, ok := h.login(t, work.ID); ok {
		t.Fatal("a failed sign-in wrote a login record")
	}
}

func TestExecCodexDeviceCodeRestartsAfterExpiry(t *testing.T) {
	t.Parallel()
	h := execHarness(t, "device-timeout")
	ctx := context.Background()
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	login, err := h.svc.StartLogin(ctx, chat.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if login.Challenge.OpenURL != "https://auth.openai.com/codex/device" || !strings.HasPrefix(login.Challenge.UserCode, "CODE-") {
		t.Fatalf("challenge = %+v", login.Challenge)
	}
	final := waitLogin(t, h.svc, login.ID)
	if final.Phase != PhaseSucceeded || final.Challenge.UserCode != "CODE-2" {
		t.Fatalf("final = %+v", final)
	}
	if final.Identity.Email != "carol@example.com" || final.Identity.WorkspaceID != "acct-carol" || final.Identity.Plan != "pro" {
		t.Fatalf("identity = %+v", final.Identity)
	}
	args, _ := os.ReadFile(filepath.Join(h.svc.codexAuthDir(chat.ID), "args.log"))
	if string(args) != `-c cli_auth_credentials_store="file" app-server` {
		t.Fatalf("codex args = %q", args)
	}
}

func TestExecCodexBrowserCallbackFollowsLoopbackRedirect(t *testing.T) {
	t.Parallel()
	h := execHarness(t, "")
	ctx := context.Background()
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	login, err := h.svc.StartLogin(ctx, chat.ID, FlowBrowser)
	if err != nil {
		t.Fatal(err)
	}
	port := login.Challenge.CallbackPort
	if port == 0 || port == 1455 || login.Challenge.Expects != ExpectsCallback {
		t.Fatalf("challenge = %+v", login.Challenge)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "", fmt.Sprintf("http://localhost:%d/auth/callback?code=good&state=S", port)); err != nil {
		t.Fatal(err)
	}
	if final := waitLogin(t, h.svc, login.ID); final.Phase != PhaseSucceeded || final.Identity.WorkspaceID != "acct-carol" {
		t.Fatalf("final = %+v", final)
	}
}

func TestExecCodexTokenRefreshUsageResetAndSignOut(t *testing.T) {
	t.Parallel()
	h := execHarness(t, "expiring")
	ctx := context.Background()
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	login, _ := h.svc.StartLogin(ctx, chat.ID, "")
	if final := waitLogin(t, h.svc, login.ID); final.Phase != PhaseSucceeded {
		t.Fatalf("final = %+v", final)
	}
	home := h.svc.codexAuthDir(chat.ID)
	before, _ := readCodexAuth(home)
	// The fake's token expires within the hour: due for a refresh. The harness
	// clock is in the past, so use the real time for this check.
	h.clock.Advance(time.Until(h.clock.Now()) * -1)
	auth, err := h.svc.ResolveTurn(ctx, "codex", "")
	if err != nil {
		t.Fatal(err)
	}
	count, _ := os.ReadFile(filepath.Join(home, "refresh-count"))
	if string(count) != "1" || auth.Auth["CODEX_API_KEY"] == before.AccessToken || auth.Auth["OPENAI_BASE_URL"] != chatGPTCodexBaseURL {
		t.Fatalf("refresh count %q, auth %+v", count, auth)
	}
	// Fresh now: no second refresh.
	if _, err := h.svc.ResolveTurn(ctx, "codex", ""); err != nil {
		t.Fatal(err)
	}
	if count, _ := os.ReadFile(filepath.Join(home, "refresh-count")); string(count) != "1" {
		t.Fatalf("refreshed again: %q", count)
	}
	account, err := h.svc.RefreshUsage(ctx, chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	usage := account.Usage
	if usage == nil || usage.Plan != "pro" || usage.Source != "probe" || len(usage.Windows) != 3 || usage.ResetCredits.Available != 2 || usage.Credits.Balance != "12.50" {
		t.Fatalf("usage = %+v", usage)
	}
	if w := usage.Windows; w[0].Kind != "five_hour" || w[0].UsedPercent != 42 || w[1].Kind != "weekly" || w[1].UsedPercent != 7 || w[2].Kind != "model" || w[2].Label != "Spark 5h" {
		t.Fatalf("windows = %+v", w)
	}
	outcome, _, err := h.svc.ConsumeReset(ctx, chat.ID, "00000000-0000-4000-8000-000000000002", "credit-1")
	if err != nil || outcome != "reset" {
		t.Fatalf("reset = %q, %v", outcome, err)
	}
	raw, _ := os.ReadFile(filepath.Join(home, "consume.json"))
	if !strings.Contains(string(raw), `"idempotencyKey":"00000000-0000-4000-8000-000000000002"`) || !strings.Contains(string(raw), `"creditId":"credit-1"`) {
		t.Fatalf("consume params = %s", raw)
	}
	if _, err := h.svc.SignOut(ctx, chat.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home, "auth.json")); !os.IsNotExist(err) {
		t.Fatalf("account/logout left auth.json: %v", err)
	}
}

// fakeOpenAI is an authorization server for Sign in with ChatGPT.
type fakeOpenAI struct {
	mu        sync.Mutex
	nonce     string
	challenge string
	noPlan    bool
	refreshes int
	revoked   []string
	grants    []url.Values
	server    *httptest.Server
}

func newFakeOpenAI(t *testing.T) *fakeOpenAI {
	f := &fakeOpenAI{}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/accounts/oauth/token", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		f.mu.Lock()
		defer f.mu.Unlock()
		f.grants = append(f.grants, r.PostForm)
		w.Header().Set("Content-Type", "application/json")
		switch r.PostForm.Get("grant_type") {
		case "authorization_code":
			sum := sha256.Sum256([]byte(r.PostForm.Get("code_verifier")))
			if base64.RawURLEncoding.EncodeToString(sum[:]) != f.challenge || r.PostForm.Get("client_id") != "oaiapp_test" || r.PostForm.Get("resource") != siwcResource {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"error":"invalid_request"}`))
				return
			}
			scope := siwcScope
			if f.noPlan {
				scope = "openid profile email offline_access resource.invoke"
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"access_token": testJWT(map[string]any{"exp": 1}), "refresh_token": "refresh-1", "expires_in": 3600, "scope": scope,
				"id_token": testJWT(map[string]any{"nonce": f.nonce, "aud": []string{"oaiapp_test"}, "sub": "user-1", "email": "dave@example.com",
					"https://api.openai.com/auth": map[string]any{"chatgpt_account_id": "ws-1", "chatgpt_plan_type": "pro"}}),
			})
		case "refresh_token":
			f.refreshes++
			_ = json.NewEncoder(w).Encode(map[string]any{"access_token": fmt.Sprintf("access-%d", f.refreshes+1), "refresh_token": fmt.Sprintf("refresh-%d", f.refreshes+1), "expires_in": 3600})
		}
	})
	mux.HandleFunc("/api/accounts/oauth/revoke", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		f.mu.Lock()
		f.revoked = append(f.revoked, r.PostForm.Get("token"))
		f.mu.Unlock()
	})
	f.server = httptest.NewServer(mux)
	t.Cleanup(f.server.Close)
	return f
}

// authorize reads the authorize URL like a browser would and returns where
// OpenAI redirects to.
func (f *fakeOpenAI) authorize(t *testing.T, open string, code string) (*url.URL, url.Values) {
	t.Helper()
	address, err := url.Parse(open)
	if err != nil || !strings.HasPrefix(open, f.server.URL+"/api/accounts/authorize?") {
		t.Fatalf("authorize URL = %q", open)
	}
	query := address.Query()
	f.mu.Lock()
	f.nonce, f.challenge = query.Get("nonce"), query.Get("code_challenge")
	f.mu.Unlock()
	redirect, _ := url.Parse(query.Get("redirect_uri"))
	callback := url.Values{"code": {code}, "state": {query.Get("state")}}
	if query.Get("client_id") == siwcDynamicClient {
		callback.Set("client_id", "oaiapp_test")
	}
	redirect.RawQuery = callback.Encode()
	return redirect, query
}

func TestExecSignInWithChatGPT(t *testing.T) {
	t.Parallel()
	h := execHarness(t, "")
	openai := newFakeOpenAI(t)
	h.svc.backend.(*execBackend).issuer = openai.server.URL
	ctx := context.Background()
	plan := h.create(t, ProviderChatGPT, "Plan", MethodSIWC)
	login, err := h.svc.StartLogin(ctx, plan.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	redirect, query := openai.authorize(t, login.Challenge.OpenURL, "abc")
	for key, want := range map[string]string{
		"client_id": siwcDynamicClient, "agent_name_hint": "Dieter", "scope": siwcScope, "resource": siwcResource,
		"ext_agent_host_id": "urn:uuid:00000000-0000-4000-8000-000000000000", "code_challenge_method": "S256", "response_type": "code",
	} {
		if query.Get(key) != want {
			t.Errorf("%s = %q", key, query.Get(key))
		}
	}
	if redirect.Hostname() != "127.0.0.1" || redirect.Path != "/auth/callback" || login.Challenge.CallbackPort == 0 {
		t.Fatalf("redirect = %s", redirect)
	}
	// The browser on this machine reaches the loopback listener directly.
	response, err := http.Get(redirect.String())
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	final := waitLogin(t, h.svc, login.ID)
	if final.Phase != PhaseSucceeded || final.Identity.Subject != "user-1" || final.Identity.WorkspaceID != "ws-1" || final.Identity.Email != "dave@example.com" {
		t.Fatalf("final = %+v", final)
	}
	r, _ := h.svc.load()
	if record, _ := r.live(plan.ID); record.SIWC == nil || record.SIWC.ClientID != "oaiapp_test" {
		t.Fatalf("client not bound: %+v", record.SIWC)
	}
	info, err := os.Stat(h.svc.siwcPath(plan.ID))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("siwc.json = %v, %v", info, err)
	}
	if record, _ := h.login(t, plan.ID); record.State != StateSignedIn || record.Usage != nil {
		t.Fatalf("login = %+v", record)
	}
	// Turns use the public API base with the session's token.
	auth, err := h.svc.ResolveTurn(ctx, "codex", plan.ID)
	if err != nil || auth.Auth["OPENAI_BASE_URL"] != openAIAPIBaseURL || auth.Auth["CODEX_API_KEY"] == "" {
		t.Fatalf("auth = %+v, %v", auth, err)
	}
	// Near expiry, the turn token refreshes under the account lock.
	h.clock.Advance(55 * time.Minute)
	token, expires, err := h.svc.TurnToken(ctx, plan.ID)
	if err != nil || token != "access-2" || !expires.Equal(h.clock.Now().Add(time.Hour).UTC()) {
		t.Fatalf("turn token = %q %v, %v", token, expires, err)
	}
	// Re-authorization reuses the issued client and this host's ID token.
	second, err := h.svc.StartLogin(ctx, plan.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	redirect, query = openai.authorize(t, second.Challenge.OpenURL, "def")
	if query.Get("client_id") != "oaiapp_test" || query.Get("id_token_hint") == "" || query.Has("agent_name_hint") {
		t.Fatalf("re-authorization = %v", query)
	}
	// Pasted from another device.
	if _, err := h.svc.SubmitLoginInput(ctx, second.ID, "", redirect.String()); err != nil {
		t.Fatal(err)
	}
	if final := waitLogin(t, h.svc, second.ID); final.Phase != PhaseSucceeded {
		t.Fatalf("second = %+v", final)
	}
	if _, err := h.svc.SignOut(ctx, plan.ID); err != nil {
		t.Fatal(err)
	}
	openai.mu.Lock()
	revoked := openai.revoked
	openai.mu.Unlock()
	if len(revoked) != 1 || revoked[0] != "refresh-1" {
		t.Fatalf("revoked = %v", revoked)
	}
	if _, err := os.Stat(h.svc.siwcPath(plan.ID)); !os.IsNotExist(err) {
		t.Fatalf("siwc.json kept: %v", err)
	}
}

func TestExecSignInWithChatGPTWithoutPlanScopeOrWrongNonce(t *testing.T) {
	t.Parallel()
	h := execHarness(t, "")
	openai := newFakeOpenAI(t)
	openai.noPlan = true
	h.svc.backend.(*execBackend).issuer = openai.server.URL
	ctx := context.Background()
	plan := h.create(t, ProviderChatGPT, "Plan", MethodSIWC)
	login, _ := h.svc.StartLogin(ctx, plan.ID, "")
	redirect, _ := openai.authorize(t, login.Challenge.OpenURL, "abc")
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "", redirect.String()); err != nil {
		t.Fatal(err)
	}
	if final := waitLogin(t, h.svc, login.ID); final.Phase != PhaseSucceeded {
		t.Fatalf("final = %+v", final)
	}
	if record, _ := h.login(t, plan.ID); record.Usage == nil || record.Usage.Unavailable != "plan_usage_not_granted" {
		t.Fatalf("login = %+v", record)
	}
	// An ID token minted for another sign-in fails.
	second, _ := h.svc.StartLogin(ctx, plan.ID, "")
	redirect, _ = openai.authorize(t, second.Challenge.OpenURL, "def")
	openai.mu.Lock()
	openai.nonce = "other"
	openai.mu.Unlock()
	if _, err := h.svc.SubmitLoginInput(ctx, second.ID, "", redirect.String()); err != nil {
		t.Fatal(err)
	}
	if final := waitLogin(t, h.svc, second.ID); final.Phase != PhaseFailed || !strings.Contains(final.ErrorMessage, "does not belong") {
		t.Fatalf("final = %+v", final)
	}
}
