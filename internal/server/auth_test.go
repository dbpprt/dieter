package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/dbpprt/nauclio/internal/gen/nauclio/v1/naucliov1connect"
	"github.com/dbpprt/nauclio/internal/store"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestGitHubAuthenticationEndToEnd(t *testing.T) {
	var expectedChallenge string
	github := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/login/oauth/access_token":
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			challenge := sha256.Sum256([]byte(r.Form.Get("code_verifier")))
			if got := base64.RawURLEncoding.EncodeToString(challenge[:]); got != expectedChallenge {
				t.Errorf("PKCE challenge=%q want=%q", got, expectedChallenge)
			}
			if r.Form.Get("client_secret") != "client-secret" || r.Form.Get("code") != "github-code" {
				t.Error("token exchange omitted required credentials")
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"access_token": "ephemeral-github-token"})
		case "/user":
			if r.Header.Get("Authorization") != "Bearer ephemeral-github-token" {
				t.Error("GitHub user request omitted bearer token")
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 42, "login": "owner"})
		default:
			http.NotFound(w, r)
		}
	}))
	defer github.Close()

	data := store.New(t.TempDir())
	config := authConfig{
		Enabled: true, PublicURL: &url.URL{Scheme: "https", Host: "board.invalid"}, ClientID: "client-id", ClientSecret: "client-secret",
		AllowedUserID: 42, AllowedLogin: "owner", Secret: []byte("01234567890123456789012345678901"), SessionTTL: time.Hour,
		GitHubBaseURL: github.URL, GitHubAPIURL: github.URL,
		NativeRedirects: map[string]struct{}{"nauclio-mac://oauth/callback": {}},
	}
	manager, err := newAuthManager(config, data)
	if err != nil {
		t.Fatal(err)
	}
	manager.client = github.Client()
	manager.client.Timeout = 5 * time.Second
	application := newWithAuth(data, slog.New(slog.NewTextHandler(io.Discard, nil)), nil, manager)
	board := httptest.NewTLSServer(application.Handler())
	defer board.Close()
	manager.config.PublicURL, _ = url.Parse(board.URL)

	jar, _ := cookiejar.New(nil)
	client := board.Client()
	client.Jar = jar
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	start, err := client.Get(board.URL + "/auth/github/start?return_to=%2Fchats%3Fstatus%3Dactive")
	if err != nil {
		t.Fatal(err)
	}
	if start.StatusCode != http.StatusFound {
		t.Fatalf("start status=%d", start.StatusCode)
	}
	authorize, err := url.Parse(start.Header.Get("Location"))
	if err != nil {
		t.Fatal(err)
	}
	if authorize.Host != strings.TrimPrefix(github.URL, "https://") || authorize.Query().Get("redirect_uri") != board.URL+"/auth/github/callback" || authorize.Query().Get("code_challenge_method") != "S256" {
		t.Fatalf("unsafe authorize URL %q", authorize.String())
	}
	expectedChallenge = authorize.Query().Get("code_challenge")
	callback, err := client.Get(board.URL + "/auth/github/callback?state=" + url.QueryEscape(authorize.Query().Get("state")) + "&code=github-code")
	if err != nil {
		t.Fatal(err)
	}
	if callback.StatusCode != http.StatusFound || callback.Header.Get("Location") != "/chats?status=active" {
		t.Fatalf("callback status=%d location=%q", callback.StatusCode, callback.Header.Get("Location"))
	}

	response, err := client.Get(board.URL + "/auth/session")
	if err != nil {
		t.Fatal(err)
	}
	var session struct {
		Enabled       bool   `json:"enabled"`
		Authenticated bool   `json:"authenticated"`
		Login         string `json:"login"`
		CSRFToken     string `json:"csrfToken"`
	}
	if err := json.NewDecoder(response.Body).Decode(&session); err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if !session.Enabled || !session.Authenticated || session.Login != "owner" || session.CSRFToken == "" {
		t.Fatalf("session=%#v", session)
	}

	connectClient := naucliov1connect.NewNauclioServiceClient(client, board.URL)
	if _, err := connectClient.Health(context.Background(), connect.NewRequest(&emptypb.Empty{})); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("missing CSRF accepted: %v", err)
	}
	request := connect.NewRequest(&emptypb.Empty{})
	request.Header().Set("Origin", board.URL)
	request.Header().Set("X-Board-CSRF", session.CSRFToken)
	if _, err := connectClient.Health(context.Background(), request); err != nil {
		t.Fatalf("authenticated Connect request failed: %v", err)
	}

	stateBytes, err := os.ReadFile(filepath.Join(data.Root, "auth", "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(stateBytes), "ephemeral-github-token") || strings.Contains(string(stateBytes), session.CSRFToken) {
		t.Fatal("raw credentials were persisted")
	}
	if info, err := os.Stat(filepath.Join(data.Root, "auth", "state.json")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("auth state mode=%v err=%v", info.Mode().Perm(), err)
	}
	if info, err := os.Stat(filepath.Join(data.Root, "auth")); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("auth directory mode=%v err=%v", info.Mode().Perm(), err)
	}

	logoutRequest, _ := http.NewRequest(http.MethodPost, board.URL+"/auth/logout", nil)
	logoutRequest.Header.Set("Origin", board.URL)
	logoutRequest.Header.Set("X-Board-CSRF", session.CSRFToken)
	logout, err := client.Do(logoutRequest)
	if err != nil || logout.StatusCode != http.StatusNoContent {
		t.Fatalf("logout=%v err=%v", logout, err)
	}

	verifier := "native-verifier-with-enough-random-material-for-pkce"
	nativeDigest := sha256.Sum256([]byte(verifier))
	nativeChallenge := base64.RawURLEncoding.EncodeToString(nativeDigest[:])
	nativeStartURL := board.URL + "/auth/github/start?native_redirect_uri=" + url.QueryEscape("nauclio-mac://oauth/callback") + "&native_code_challenge=" + url.QueryEscape(nativeChallenge)
	nativeStart, err := client.Get(nativeStartURL)
	if err != nil || nativeStart.StatusCode != http.StatusFound {
		t.Fatalf("native start=%v err=%v", nativeStart, err)
	}
	nativeAuthorize, _ := url.Parse(nativeStart.Header.Get("Location"))
	expectedChallenge = nativeAuthorize.Query().Get("code_challenge")
	nativeCallback, err := client.Get(board.URL + "/auth/github/callback?state=" + url.QueryEscape(nativeAuthorize.Query().Get("state")) + "&code=github-code")
	if err != nil || nativeCallback.StatusCode != http.StatusFound {
		t.Fatalf("native callback=%v err=%v", nativeCallback, err)
	}
	appRedirect, err := url.Parse(nativeCallback.Header.Get("Location"))
	if err != nil || appRedirect.Scheme != "nauclio-mac" || appRedirect.Query().Get("code") == "" {
		t.Fatalf("native app redirect=%q err=%v", nativeCallback.Header.Get("Location"), err)
	}
	exchangeBody, _ := json.Marshal(map[string]string{"code": appRedirect.Query().Get("code"), "verifier": verifier})
	wrongVerifierBody, _ := json.Marshal(map[string]string{"code": appRedirect.Query().Get("code"), "verifier": verifier + "-wrong"})
	wrongVerifier, err := client.Post(board.URL+"/auth/native/exchange", "application/json", bytes.NewReader(wrongVerifierBody))
	if err != nil || wrongVerifier.StatusCode != http.StatusBadRequest {
		t.Fatalf("native wrong verifier accepted: response=%v err=%v", wrongVerifier, err)
	}
	exchange, err := client.Post(board.URL+"/auth/native/exchange", "application/json", bytes.NewReader(exchangeBody))
	if err != nil || exchange.StatusCode != http.StatusOK {
		t.Fatalf("native exchange=%v err=%v", exchange, err)
	}
	var nativeSession struct {
		AccessToken string `json:"accessToken"`
	}
	if err := json.NewDecoder(exchange.Body).Decode(&nativeSession); err != nil || nativeSession.AccessToken == "" {
		t.Fatalf("native token missing: %v", err)
	}
	_ = exchange.Body.Close()
	bearerRequest := connect.NewRequest(&emptypb.Empty{})
	bearerRequest.Header().Set("Authorization", "Bearer "+nativeSession.AccessToken)
	if _, err := connectClient.Health(context.Background(), bearerRequest); err != nil {
		t.Fatalf("native bearer request failed: %v", err)
	}
	reused, err := client.Post(board.URL+"/auth/native/exchange", "application/json", bytes.NewReader(exchangeBody))
	if err != nil || reused.StatusCode != http.StatusBadRequest {
		t.Fatalf("native code reuse accepted: response=%v err=%v", reused, err)
	}
	revokeRequest, _ := http.NewRequest(http.MethodPost, board.URL+"/auth/native/revoke", nil)
	revokeRequest.Header.Set("Authorization", "Bearer "+nativeSession.AccessToken)
	revoke, err := client.Do(revokeRequest)
	if err != nil || revoke.StatusCode != http.StatusNoContent {
		t.Fatalf("native revoke=%v err=%v", revoke, err)
	}
	if _, err := connectClient.Health(context.Background(), bearerRequest); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("revoked native bearer accepted: %v", err)
	}
}

func TestAuthConfigurationRejectsUnsafeValues(t *testing.T) {
	t.Setenv("NAUCLIO_AUTH_MODE", "github")
	t.Setenv("NAUCLIO_PUBLIC_URL", "http://nauclio.example")
	if _, err := authConfigFromEnv(); err == nil {
		t.Fatal("insecure public URL accepted")
	}
	root := t.TempDir()
	path := filepath.Join(root, ".env")
	if err := os.WriteFile(path, []byte("NAUCLIO_AUTH_MODE=none\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := LoadEnvFile(root, ""); err == nil {
		t.Fatal("group-readable environment file accepted")
	}
}
