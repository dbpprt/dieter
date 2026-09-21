package gateway

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/linkauth"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestHealthReportsGatewayBuildIdentity(t *testing.T) {
	auth := NewAuth(Config{}, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	recorder := httptest.NewRecorder()
	auth.health(recorder, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	body := recorder.Body.String()
	if recorder.Code != http.StatusOK || !strings.Contains(body, `"service":"dieter-gateway"`) || !strings.Contains(body, `"apiVersion":"`+GatewayAPIVersion+`"`) || !strings.Contains(body, `"version":`) {
		t.Fatalf("status=%d body=%q", recorder.Code, body)
	}
}

func TestExchangeDecodesGitHubAccessToken(t *testing.T) {
	github := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/login/oauth/access_token" {
			t.Fatalf("unexpected GitHub path %q", r.URL.Path)
		}
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		if r.Form.Get("code") != "authorization-code" || r.Form.Get("code_verifier") != "verifier" {
			t.Fatalf("unexpected token form: %#v", r.Form)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"access_token":"github-token","token_type":"bearer"}`)
	}))
	defer github.Close()

	publicURL, _ := url.Parse("https://dieter.example.com")
	auth := NewAuth(Config{
		PublicURL: publicURL, GitHubClientID: "client", GitHubSecret: "secret",
		GitHubBaseURL: github.URL, SessionTTL: time.Hour,
	}, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	token, err := auth.exchange(context.Background(), "authorization-code", "verifier")
	if err != nil {
		t.Fatal(err)
	}
	if token != "github-token" {
		t.Fatalf("unexpected token %q", token)
	}
}

func TestNativeRedirectAllowsOnlyConfiguredOrRFC8252LoopbackCallback(t *testing.T) {
	auth := NewAuth(Config{NativeRedirects: map[string]struct{}{"dieter://auth/callback": {}}}, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	for _, test := range []struct {
		value string
		want  bool
	}{
		{"dieter://auth/callback", true},
		{"http://127.0.0.1:49152/auth/callback", true},
		{"http://127.0.0.1:1/auth/callback", true},
		{"http://localhost:49152/auth/callback", false},
		{"http://[::1]:49152/auth/callback", false},
		{"https://127.0.0.1:49152/auth/callback", false},
		{"http://127.0.0.1/auth/callback", false},
		{"http://127.0.0.1:49152/other", false},
		{"http://127.0.0.1:49152/auth/callback?code=preloaded", false},
		{"http://user@127.0.0.1:49152/auth/callback", false},
		{"http://127.0.0.1:70000/auth/callback", false},
	} {
		t.Run(test.value, func(t *testing.T) {
			if got := auth.nativeRedirectAllowed(test.value); got != test.want {
				t.Fatalf("nativeRedirectAllowed(%q)=%v want %v", test.value, got, test.want)
			}
		})
	}
}

func TestAuthenticationRejectsSessionForRemovedGitHubUser(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	auth := NewAuth(Config{AllowedUserIDs: map[int64]struct{}{42: {}}, AuthSecret: []byte("test-auth-secret"), SessionTTL: time.Hour}, store, nil)
	token, _, err := auth.createSession(42, "former-owner")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := auth.AuthenticateBearer("Bearer " + token); !ok {
		t.Fatal("allowed account session was rejected")
	}
	auth.config.AllowedUserIDs = map[int64]struct{}{99: {}}
	if _, ok := auth.AuthenticateBearer("Bearer " + token); ok {
		t.Fatal("removed GitHub account retained gateway access")
	}
}

func newSecurityTestAuth(t *testing.T) *Auth {
	t.Helper()
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	public, _ := url.Parse("https://dieter.example.com")
	return NewAuth(Config{PublicURL: public, AllowedUserIDs: map[int64]struct{}{42: {}}, AuthSecret: []byte("test-auth-secret"), SessionTTL: time.Hour, GitHubBaseURL: "https://github.com", NativeRedirects: map[string]struct{}{"dieter://auth/callback": {}}}, store, nil)
}

func TestOAuthEnrollmentRequiresBrowserBoundExplicitConfirmation(t *testing.T) {
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
	defer github.Close()
	auth.config.GitHubBaseURL, auth.config.GitHubAPIURL = github.URL, github.URL
	err := auth.store.CreateEnrollment(EnrollmentRecord{ID: "enroll-test", SecretHash: "hash", UserCode: "ABCD", Name: "<script>untrusted machine</script>", PublicKey: []byte("machine-public-key"), ExpiresAt: time.Now().UTC().Add(time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	start := httptest.NewRecorder()
	auth.start(start, httptest.NewRequest(http.MethodGet, "/auth/github/start?enrollment_id=enroll-test&user_code=ABCD", nil))
	if start.Code != http.StatusFound {
		t.Fatalf("OAuth start failed: %d %s", start.Code, start.Body.String())
	}
	redirect, _ := url.Parse(start.Header().Get("Location"))
	callback := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=github-code&state="+redirect.Query().Get("state"), nil)
	callback.AddCookie(start.Result().Cookies()[0])
	confirmation := httptest.NewRecorder()
	auth.callback(confirmation, callback)
	if confirmation.Code != http.StatusOK || !strings.Contains(confirmation.Body.String(), "Approve this machine") || strings.Contains(confirmation.Body.String(), "<script>") {
		t.Fatalf("invalid confirmation page: %d %s", confirmation.Code, confirmation.Body.String())
	}
	assertApproved := func(want bool) {
		t.Helper()
		record, err := auth.store.Enrollment("enroll-test")
		if err != nil || record.Approved != want {
			t.Fatalf("approved=%v want=%v err=%v", record.Approved, want, err)
		}
	}
	assertApproved(false)
	var approvalCookie *http.Cookie
	for _, cookie := range confirmation.Result().Cookies() {
		if cookie.Name == enrollmentCookie {
			approvalCookie = cookie
		}
	}
	if approvalCookie == nil || !approvalCookie.Secure || !approvalCookie.HttpOnly || approvalCookie.SameSite != http.SameSiteStrictMode {
		t.Fatal("confirmation did not set a secure browser-bound cookie")
	}
	approve := func(cookie *http.Cookie, token string) *httptest.ResponseRecorder {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, "/auth/enrollment/approve", strings.NewReader(url.Values{"token": {token}}.Encode()))
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if cookie != nil {
			request.AddCookie(cookie)
		}
		recorder := httptest.NewRecorder()
		auth.approveEnrollment(recorder, request)
		return recorder
	}
	for _, cookie := range []*http.Cookie{nil, {Name: enrollmentCookie, Value: "wrong-browser"}} {
		if response := approve(cookie, approvalCookie.Value); response.Code != http.StatusBadRequest {
			t.Fatalf("confirmation accepted invalid browser state: %d", response.Code)
		}
		assertApproved(false)
	}
	if response := approve(approvalCookie, approvalCookie.Value); response.Code != http.StatusOK {
		t.Fatalf("confirmation failed: %d %s", response.Code, response.Body.String())
	}
	assertApproved(true)
	if response := approve(approvalCookie, approvalCookie.Value); response.Code != http.StatusBadRequest {
		t.Fatal("enrollment confirmation was replayable")
	}
}

func TestNativeCodeRequiresPKCEAndCannotBeReplayed(t *testing.T) {
	auth := newSecurityTestAuth(t)
	verifier := strings.Repeat("v", 64)
	digest := sha256.Sum256([]byte(verifier))
	code, err := auth.createNativeCode(42, "owner", base64.RawURLEncoding.EncodeToString(digest[:]))
	if err != nil {
		t.Fatal(err)
	}
	exchange := func(verifier string) *httptest.ResponseRecorder {
		request, _ := json.Marshal(map[string]string{"code": code, "verifier": verifier})
		recorder := httptest.NewRecorder()
		auth.nativeExchange(recorder, httptest.NewRequest(http.MethodPost, "/auth/native/exchange", strings.NewReader(string(request))))
		return recorder
	}
	if response := exchange("attacker-verifier"); response.Code != http.StatusBadRequest {
		t.Fatal("code accepted without matching PKCE")
	}
	if response := exchange(verifier); response.Code != http.StatusOK {
		t.Fatalf("valid exchange failed: %d %s", response.Code, response.Body.String())
	}
	if response := exchange(verifier); response.Code != http.StatusBadRequest {
		t.Fatal("native authorization code was replayable")
	}
}

func TestEnrollmentConfirmationExpiresRechecksAccountAndIsSingleUse(t *testing.T) {
	for _, mode := range []string{"concurrent approval", "expired confirmation", "expired enrollment", "removed account"} {
		t.Run(mode, func(t *testing.T) {
			auth := newSecurityTestAuth(t)
			record := EnrollmentRecord{ID: "enrollment", SecretHash: "hash", UserCode: "ABCD", Name: "test", PublicKey: []byte("key"), ExpiresAt: time.Now().Add(time.Minute)}
			if err := auth.store.CreateEnrollment(record); err != nil {
				t.Fatal(err)
			}
			page := httptest.NewRecorder()
			auth.confirmEnrollment(page, OAuthPending{EnrollmentID: record.ID, EnrollmentCode: record.UserCode}, 42, "owner")
			cookies := page.Result().Cookies()
			if len(cookies) != 1 {
				t.Fatalf("confirmation cookies: %v", cookies)
			}
			cookie := cookies[0]
			switch mode {
			case "expired confirmation":
				if err := auth.store.UpdateAuthState(func(state *AuthState) error { state.Approvals[0].ExpiresAt = time.Now().Add(-time.Second); return nil }); err != nil {
					t.Fatal(err)
				}
			case "expired enrollment":
				if _, err := auth.store.DB.Exec("UPDATE enrollments SET expires_at=? WHERE id=?", time.Now().Add(-time.Second).UTC().Format(time.RFC3339Nano), record.ID); err != nil {
					t.Fatal(err)
				}
			case "removed account":
				auth.config.AllowedUserIDs = map[int64]struct{}{99: {}}
			}
			var accepted atomic.Int32
			var group sync.WaitGroup
			for range 8 {
				group.Go(func() {
					request := httptest.NewRequest(http.MethodPost, "/auth/enrollment/approve", strings.NewReader(url.Values{"token": {cookie.Value}}.Encode()))
					request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
					request.AddCookie(cookie)
					response := httptest.NewRecorder()
					auth.approveEnrollment(response, request)
					if response.Code == http.StatusOK {
						accepted.Add(1)
					} else if response.Code != http.StatusBadRequest {
						t.Errorf("unexpected confirmation status: %d", response.Code)
					}
				})
			}
			group.Wait()
			want := int32(0)
			if mode == "concurrent approval" {
				want = 1
			}
			if accepted.Load() != want {
				t.Fatalf("accepted=%d want=%d", accepted.Load(), want)
			}
			stored, err := auth.store.Enrollment(record.ID)
			if err != nil || stored.Approved != (want == 1) {
				t.Fatalf("approved=%v err=%v", stored.Approved, err)
			}
		})
	}
}

func TestNativeExchangeRejectsRemovedGitHubAccount(t *testing.T) {
	auth := newSecurityTestAuth(t)
	verifier := "test-verifier"
	digest := sha256.Sum256([]byte(verifier))
	code, err := auth.createNativeCode(99, "removed-owner", base64.RawURLEncoding.EncodeToString(digest[:]))
	if err != nil {
		t.Fatal(err)
	}
	request, _ := json.Marshal(map[string]string{"code": code, "verifier": verifier})
	recorder := httptest.NewRecorder()
	auth.nativeExchange(recorder, httptest.NewRequest(http.MethodPost, "/auth/native/exchange", strings.NewReader(string(request))))
	if recorder.Code != http.StatusBadRequest {
		t.Fatal("removed user redeemed a pending native authorization code")
	}
	state, err := auth.store.AuthState()
	if err != nil || len(state.Sessions) != 0 {
		t.Fatalf("exchange created session for removed account: %v", err)
	}
}

func TestAuthenticationStateAndRatePeersAreBounded(t *testing.T) {
	auth := newSecurityTestAuth(t)
	for index := 0; index < maxAuthRatePeers; index++ {
		auth.rates[fmt.Sprint(index)] = []time.Time{time.Now()}
	}
	request := httptest.NewRequest(http.MethodGet, "/auth/github/start", nil)
	if auth.allow(request) || len(auth.rates) != maxAuthRatePeers {
		t.Fatal("authentication rate map grew past its bound")
	}
	auth.rates["0"] = []time.Time{time.Now().Add(-11 * time.Minute)}
	if !auth.allow(request) || len(auth.rates) != maxAuthRatePeers {
		t.Fatal("authentication rate map did not reclaim expired peers")
	}
	if err := auth.store.UpdateAuthState(func(state *AuthState) error {
		for index := 0; index < maxAuthRecords; index++ {
			state.Pending = append(state.Pending, OAuthPending{ExpiresAt: time.Now().Add(time.Hour)})
			state.Sessions = append(state.Sessions, Session{ExpiresAt: time.Now().Add(time.Hour)})
			state.Codes = append(state.Codes, NativeCode{ExpiresAt: time.Now().Add(time.Hour)})
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := auth.createSession(42, "owner"); err != errAuthCapacity {
		t.Fatalf("session cap not enforced: %v", err)
	}
	if _, err := auth.createNativeCode(42, "owner", "challenge"); err != errAuthCapacity {
		t.Fatalf("code cap not enforced: %v", err)
	}
	recorder := httptest.NewRecorder()
	digest := sha256.Sum256([]byte("verifier"))
	auth.start(recorder, httptest.NewRequest(http.MethodGet, "/auth/github/start?"+url.Values{"native_redirect_uri": {"dieter://auth/callback"}, "native_code_challenge": {base64.RawURLEncoding.EncodeToString(digest[:])}}.Encode(), nil))
	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("OAuth pending cap not enforced: %d", recorder.Code)
	}
	state, err := auth.store.AuthState()
	if err != nil || len(state.Pending) != maxAuthRecords {
		t.Fatalf("OAuth pending state grew past cap: %v", err)
	}
}

func TestAuthenticatedStreamsCloseAfterRevocation(t *testing.T) {
	auth := newSecurityTestAuth(t)
	token, _, err := auth.createSession(42, "owner")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel, err := auth.AuthenticateSession(context.Background(), "Bearer "+token)
	if err != nil {
		t.Fatal(err)
	}
	defer cancel()
	request := httptest.NewRequest(http.MethodPost, "/auth/native/revoke", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	auth.nativeRevoke(recorder, request)
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("sign-out failed: %d", recorder.Code)
	}
	select {
	case <-ctx.Done():
		if status.Code(context.Cause(ctx)) != codes.Unauthenticated {
			t.Fatalf("incorrect revocation status: %v", context.Cause(ctx))
		}
	case <-time.After(sessionCheckInterval + 2*time.Second):
		t.Fatal("revoked session retained streaming access")
	}
}

func TestDaemonStreamAuthorizationFollowsEnrollmentAfterOpeningProof(t *testing.T) {
	service, private, credential := newEnrolledSecurityService(t)
	proof := linkauth.SignPeer(private, credential.GetDaemonId(), service.config.PublicURL.String(), credential.GetGeneration(), time.Now())
	if _, ok := service.auth.AuthenticateBearer("Bearer " + proof); !ok {
		t.Fatal("fresh daemon proof was rejected")
	}
	claims, _, _, err := linkauth.ParsePeer(proof)
	if err != nil {
		t.Fatal(err)
	}
	// The opening proof may expire during a long watch. Once verified, the
	// stream remains authorized by the live enrollment rather than the proof's
	// timestamp.
	claims.Expires = 1
	if !service.auth.daemonEnrollmentCurrent(claims) {
		t.Fatal("current daemon enrollment did not retain stream authorization")
	}
	if _, err := service.store.RevokeDaemon(credential.GetDaemonId(), 1234); err != nil {
		t.Fatal(err)
	}
	if service.auth.daemonEnrollmentCurrent(claims) {
		t.Fatal("revoked daemon enrollment retained stream authorization")
	}
}

func TestOAuthExchangeDoesNotForwardSecretsToRedirects(t *testing.T) {
	redirected := make(chan struct{}, 1)
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirected <- struct{}{}
		_, _ = io.WriteString(w, `{"access_token":"unexpected"}`)
	}))
	defer sink.Close()
	github := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, sink.URL, http.StatusTemporaryRedirect)
	}))
	defer github.Close()
	auth := newSecurityTestAuth(t)
	auth.config.GitHubBaseURL = github.URL
	if _, err := auth.exchange(context.Background(), "code", "verifier"); err == nil {
		t.Fatal("OAuth exchange followed a redirect")
	}
	select {
	case <-redirected:
		t.Fatal("OAuth client credentials were sent to a redirect target")
	default:
	}
}
