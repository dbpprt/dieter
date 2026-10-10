package gateway

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func newNativeSignInTestAuth(t *testing.T) *Auth {
	t.Helper()
	auth := newSecurityTestAuth(t)
	github := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/login/oauth/access_token":
			_, _ = io.WriteString(w, `{"access_token":"test-token"}`)
		case "/user":
			_, _ = io.WriteString(w, `{"id":42,"login":"owner"}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(github.Close)
	auth.config.GitHubBaseURL, auth.config.GitHubAPIURL = github.URL, github.URL
	return auth
}

func startNativeSignIn(t *testing.T, auth *Auth, redirect, verifier string) *httptest.ResponseRecorder {
	t.Helper()
	digest := sha256.Sum256([]byte(verifier))
	query := url.Values{"native_redirect_uri": {redirect}, "native_code_challenge": {base64.RawURLEncoding.EncodeToString(digest[:])}}
	recorder := httptest.NewRecorder()
	auth.start(recorder, httptest.NewRequest(http.MethodGet, auth.config.PublicURL.String()+"/auth/github/start?"+query.Encode(), nil))
	return recorder
}

func cookieNamed(response *httptest.ResponseRecorder, name string) *http.Cookie {
	for _, cookie := range response.Result().Cookies() {
		if cookie.Name == name && cookie.MaxAge >= 0 {
			return cookie
		}
	}
	return nil
}

func githubCallback(t *testing.T, auth *Auth, start *httptest.ResponseRecorder) *httptest.ResponseRecorder {
	t.Helper()
	location, err := url.Parse(start.Header().Get("Location"))
	if err != nil {
		t.Fatal(err)
	}
	callback := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=github-code&state="+location.Query().Get("state"), nil)
	if cookie := cookieNamed(start, oauthCookie); cookie != nil {
		callback.AddCookie(cookie)
	}
	response := httptest.NewRecorder()
	auth.callback(response, callback)
	return response
}

// GitHub may skip its own consent for an app the user authorized before, so
// the gateway asks before any app receives a session.
func TestNativeSignInRequiresExplicitBrowserBoundConfirmation(t *testing.T) {
	auth := newNativeSignInTestAuth(t)
	verifier := strings.Repeat("v", 64)
	start := startNativeSignIn(t, auth, "dieter://auth/callback", verifier)
	if start.Code != http.StatusFound {
		t.Fatalf("start: %d %s", start.Code, start.Body.String())
	}
	page := githubCallback(t, auth, start)
	if page.Code != http.StatusOK || page.Header().Get("Location") != "" || !strings.Contains(page.Body.String(), "Sign in to Dieter?") || !strings.Contains(page.Body.String(), "@owner") {
		t.Fatalf("callback did not ask for confirmation: %d %v %s", page.Code, page.Header(), page.Body.String())
	}
	if policy := page.Header().Get("Content-Security-Policy"); !strings.Contains(policy, "form-action 'self' dieter:") || !strings.Contains(policy, "frame-ancestors 'none'") {
		t.Fatalf("confirmation policy = %q", policy)
	}
	if state, err := auth.store.AuthState(); err != nil || len(state.Codes) != 0 {
		t.Fatalf("a code was issued before confirmation: %v", err)
	}
	confirmation := cookieNamed(page, signInCookie)
	if confirmation == nil || !confirmation.Secure || !confirmation.HttpOnly || confirmation.SameSite != http.SameSiteStrictMode {
		t.Fatal("confirmation did not set a secure browser-bound cookie")
	}
	approve := func(cookie *http.Cookie, token string) *httptest.ResponseRecorder {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, "/auth/native/approve", strings.NewReader(url.Values{"token": {token}}.Encode()))
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if cookie != nil {
			request.AddCookie(cookie)
		}
		response := httptest.NewRecorder()
		auth.approveNativeSignIn(response, request)
		return response
	}
	for _, cookie := range []*http.Cookie{nil, {Name: signInCookie, Value: "another-browser"}} {
		if response := approve(cookie, confirmation.Value); response.Code != http.StatusBadRequest {
			t.Fatalf("confirmation accepted invalid browser state: %d", response.Code)
		}
	}
	approved := approve(confirmation, confirmation.Value)
	if approved.Code != http.StatusSeeOther {
		t.Fatalf("confirmation failed: %d %s", approved.Code, approved.Body.String())
	}
	callback, err := url.Parse(approved.Header().Get("Location"))
	if err != nil || callback.Scheme != "dieter" || callback.Host != "auth" || callback.Path != "/callback" || callback.Query().Get("code") == "" {
		t.Fatalf("app callback = %q", approved.Header().Get("Location"))
	}
	if response := approve(confirmation, confirmation.Value); response.Code != http.StatusBadRequest {
		t.Fatal("sign-in confirmation was replayable")
	}
	request, _ := json.Marshal(map[string]string{"code": callback.Query().Get("code"), "verifier": verifier})
	exchange := httptest.NewRecorder()
	auth.nativeExchange(exchange, httptest.NewRequest(http.MethodPost, "/auth/native/exchange", strings.NewReader(string(request))))
	if exchange.Code != http.StatusOK || !strings.Contains(exchange.Body.String(), "accessToken") {
		t.Fatalf("exchange after confirmation: %d %s", exchange.Code, exchange.Body.String())
	}
}

func TestNativeSignInConfirmationExpiresAndRechecksAccount(t *testing.T) {
	for _, mode := range []string{"expired", "removed account"} {
		t.Run(mode, func(t *testing.T) {
			auth := newNativeSignInTestAuth(t)
			page := httptest.NewRecorder()
			auth.confirmNativeSignIn(page, oauthPending{NativeRedirect: "dieter://auth/callback", NativeChallenge: "challenge"}, 42, "owner")
			cookie := cookieNamed(page, signInCookie)
			if cookie == nil {
				t.Fatal("no confirmation cookie")
			}
			switch mode {
			case "expired":
				if err := auth.store.UpdateAuthState(func(state *AuthState) error { state.SignIns[0].ExpiresAt = time.Now().Add(-time.Second); return nil }); err != nil {
					t.Fatal(err)
				}
			case "removed account":
				auth.config.AllowedUserIDs = map[int64]struct{}{99: {}}
			}
			request := httptest.NewRequest(http.MethodPost, "/auth/native/approve", strings.NewReader(url.Values{"token": {cookie.Value}}.Encode()))
			request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			request.AddCookie(cookie)
			response := httptest.NewRecorder()
			auth.approveNativeSignIn(response, request)
			if response.Code != http.StatusBadRequest || response.Header().Get("Location") != "" {
				t.Fatalf("confirmation accepted: %d %v", response.Code, response.Header())
			}
		})
	}
}

func TestOAuthStartRejectsLoopbackCallbacks(t *testing.T) {
	auth := newNativeSignInTestAuth(t)
	for _, redirect := range []string{"http://127.0.0.1:49152/auth/callback", "http://localhost:49152/auth/callback", "dieter-compose://oauth/callback"} {
		if response := startNativeSignIn(t, auth, redirect, "verifier"); response.Code != http.StatusBadRequest || cookieNamed(response, oauthCookie) != nil {
			t.Fatalf("start accepted %q: %d", redirect, response.Code)
		}
	}
}

// The attempt lives sealed in the browser: the gateway stores nothing until
// GitHub returns, and only an intact, unexpired cookie from this gateway
// completes the callback, once.
func TestOAuthAttemptIsSealedSingleUseAndStoresNothing(t *testing.T) {
	auth := newNativeSignInTestAuth(t)
	for range 20 {
		if response := startNativeSignIn(t, auth, "dieter://auth/callback", "verifier"); response.Code != http.StatusFound {
			t.Fatalf("start: %d", response.Code)
		}
	}
	if state, err := auth.store.AuthState(); err != nil || len(state.Sessions)+len(state.Codes)+len(state.Approvals)+len(state.SignIns) != 0 {
		t.Fatalf("OAuth start wrote gateway state: %#v %v", state, err)
	}
	start := startNativeSignIn(t, auth, "dieter://auth/callback", "verifier")
	sealed := cookieNamed(start, oauthCookie)
	if sealed == nil || strings.Contains(sealed.Value, "dieter://") || strings.Contains(sealed.Value, "verifier") {
		t.Fatalf("pending cookie is not sealed: %v", sealed)
	}
	pending, ok := auth.openPending(sealed.Value)
	if !ok || pending.NativeRedirect != "dieter://auth/callback" {
		t.Fatal("pending cookie did not round-trip")
	}

	tampered := []byte(sealed.Value)
	tampered[len(tampered)/2] ^= 1
	other := newNativeSignInTestAuth(t)
	other.config.AuthSecret = []byte("another-auth-secret")
	foreign, _ := other.sealPending(pending)
	expired := pending
	expired.ExpiresAt = time.Now().Add(-time.Second)
	stale, _ := auth.sealPending(expired)
	for name, value := range map[string]string{"tampered": string(tampered), "other gateway": foreign, "expired": stale} {
		t.Run(name, func(t *testing.T) {
			response := httptest.NewRecorder()
			request := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=github-code&state="+url.QueryEscape(pending.State), nil)
			request.AddCookie(&http.Cookie{Name: oauthCookie, Value: value})
			auth.callback(response, request)
			if response.Code != http.StatusBadRequest || cookieNamed(response, signInCookie) != nil {
				t.Fatalf("callback accepted %s attempt: %d", name, response.Code)
			}
		})
	}

	wrongState := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=github-code&state=forged", nil)
	request.AddCookie(sealed)
	auth.callback(wrongState, request)
	if wrongState.Code != http.StatusBadRequest {
		t.Fatalf("callback accepted a mismatched state: %d", wrongState.Code)
	}
	first := githubCallback(t, auth, start)
	if first.Code != http.StatusOK || cookieNamed(first, signInCookie) == nil {
		t.Fatalf("callback failed: %d %s", first.Code, first.Body.String())
	}
	cleared := false
	for _, cookie := range first.Result().Cookies() {
		cleared = cleared || (cookie.Name == oauthCookie && cookie.MaxAge < 0)
	}
	if !cleared {
		t.Fatal("callback did not clear the single-use attempt")
	}
}
