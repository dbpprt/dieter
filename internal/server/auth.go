package server

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/envfile"
	"github.com/dbpprt/dieter/internal/store"
)

const (
	sessionCookie = "__Host-board_session"
	csrfCookie    = "__Host-board_csrf"
	oauthCookie   = "__Host-board_oauth"
)

type authConfig struct {
	Enabled         bool
	PublicURL       *url.URL
	ClientID        string
	ClientSecret    string
	AllowedUserID   int64
	AllowedLogin    string
	Secret          []byte
	SessionTTL      time.Duration
	GitHubBaseURL   string
	GitHubAPIURL    string
	NativeRedirects map[string]struct{}
}

// LoadEnvFile loads Board's private deployment environment without replacing
// values explicitly supplied by the process environment.
func LoadEnvFile(root, explicit string) error {
	return envfile.Load(root, explicit)
}

func authConfigFromEnv() (authConfig, error) {
	mode := strings.ToLower(strings.TrimSpace(os.Getenv("DIETER_AUTH_MODE")))
	if mode == "" || mode == "none" || mode == "disabled" {
		return authConfig{}, nil
	}
	if mode != "github" {
		return authConfig{}, fmt.Errorf("unsupported DIETER_AUTH_MODE %q", mode)
	}
	publicURL, err := url.Parse(strings.TrimSpace(os.Getenv("DIETER_PUBLIC_URL")))
	if err != nil || publicURL.Scheme != "https" || publicURL.Host == "" || publicURL.Path != "" || publicURL.RawQuery != "" || publicURL.Fragment != "" {
		return authConfig{}, errors.New("DIETER_PUBLIC_URL must be an https origin without a path, query, or fragment")
	}
	clientID := strings.TrimSpace(os.Getenv("DIETER_GITHUB_CLIENT_ID"))
	clientSecret := strings.TrimSpace(os.Getenv("DIETER_GITHUB_CLIENT_SECRET"))
	if clientID == "" || clientSecret == "" {
		return authConfig{}, errors.New("DIETER_GITHUB_CLIENT_ID and DIETER_GITHUB_CLIENT_SECRET are required")
	}
	allowedID, err := strconv.ParseInt(strings.TrimSpace(os.Getenv("DIETER_GITHUB_ALLOWED_USER_ID")), 10, 64)
	if err != nil || allowedID <= 0 {
		return authConfig{}, errors.New("DIETER_GITHUB_ALLOWED_USER_ID must be the allowed account's positive numeric GitHub ID")
	}
	secret, err := hex.DecodeString(strings.TrimSpace(os.Getenv("DIETER_AUTH_SECRET")))
	if err != nil || len(secret) < 32 {
		return authConfig{}, errors.New("DIETER_AUTH_SECRET must be at least 32 random bytes encoded as hexadecimal")
	}
	ttl := 7 * 24 * time.Hour
	if raw := strings.TrimSpace(os.Getenv("DIETER_WEB_SESSION_TTL")); raw != "" {
		ttl, err = time.ParseDuration(raw)
		if err != nil || ttl < time.Hour || ttl > 31*24*time.Hour {
			return authConfig{}, errors.New("DIETER_WEB_SESSION_TTL must be between 1h and 744h")
		}
	}
	nativeRedirects := map[string]struct{}{}
	for _, value := range strings.Split(os.Getenv("DIETER_NATIVE_REDIRECT_URIS"), ",") {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		parsed, parseErr := url.Parse(value)
		if parseErr != nil || parsed.Scheme == "" || parsed.IsAbs() == false || parsed.Fragment != "" || (parsed.Scheme == "https" && parsed.Host == "") {
			return authConfig{}, fmt.Errorf("invalid DIETER_NATIVE_REDIRECT_URIS entry %q", value)
		}
		nativeRedirects[value] = struct{}{}
	}
	return authConfig{
		Enabled: true, PublicURL: publicURL, ClientID: clientID, ClientSecret: clientSecret,
		AllowedUserID: allowedID, AllowedLogin: strings.TrimSpace(os.Getenv("DIETER_GITHUB_ALLOWED_LOGIN")),
		Secret: secret, SessionTTL: ttl, GitHubBaseURL: "https://github.com", GitHubAPIURL: "https://api.github.com", NativeRedirects: nativeRedirects,
	}, nil
}

type authManager struct {
	config authConfig
	store  *store.Store
	client *http.Client
	mu     sync.Mutex
	state  store.AuthState
	rateMu sync.Mutex
	rates  map[string][]time.Time
	log    *slog.Logger
}

func newAuthManager(config authConfig, data *store.Store) (*authManager, error) {
	manager := &authManager{config: config, store: data, client: &http.Client{Timeout: 12 * time.Second}, rates: map[string][]time.Time{}}
	if !config.Enabled {
		return manager, nil
	}
	state, err := data.LoadAuthState()
	if err != nil {
		return nil, fmt.Errorf("load auth state: %w", err)
	}
	manager.state = state
	manager.pruneLocked(time.Now().UTC())
	if err := data.SaveAuthState(manager.state); err != nil {
		return nil, fmt.Errorf("initialize auth state: %w", err)
	}
	return manager, nil
}

func (a *authManager) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", a.health)
	mux.HandleFunc("GET /auth/session", a.session)
	mux.HandleFunc("GET /auth/github/start", a.start)
	mux.HandleFunc("GET /auth/github/callback", a.callback)
	mux.HandleFunc("POST /auth/logout", a.logout)
	mux.HandleFunc("POST /auth/native/exchange", a.nativeExchange)
	mux.HandleFunc("POST /auth/native/revoke", a.nativeRevoke)
}

func (a *authManager) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_, _ = io.WriteString(w, `{"status":"ok"}`)
}

func (a *authManager) session(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if !a.config.Enabled {
		_ = json.NewEncoder(w).Encode(map[string]any{"enabled": false, "authenticated": true})
		return
	}
	session, csrf, ok := a.browserSession(r)
	response := map[string]any{"enabled": true, "authenticated": ok}
	if ok {
		response["login"] = session.Login
		response["csrfToken"] = csrf
	}
	_ = json.NewEncoder(w).Encode(response)
}

func (a *authManager) start(w http.ResponseWriter, r *http.Request) {
	if !a.config.Enabled {
		http.NotFound(w, r)
		return
	}
	if !a.allow(r) {
		http.Error(w, "too many authentication attempts", http.StatusTooManyRequests)
		return
	}
	state, err := randomToken(32)
	if err != nil {
		http.Error(w, "authentication unavailable", http.StatusInternalServerError)
		return
	}
	verifier, err := randomToken(48)
	if err != nil {
		http.Error(w, "authentication unavailable", http.StatusInternalServerError)
		return
	}
	now := time.Now().UTC()
	nativeRedirect := strings.TrimSpace(r.URL.Query().Get("native_redirect_uri"))
	nativeChallenge := strings.TrimSpace(r.URL.Query().Get("native_code_challenge"))
	if nativeRedirect != "" || nativeChallenge != "" {
		if _, ok := a.config.NativeRedirects[nativeRedirect]; !ok || !validPKCEChallenge(nativeChallenge) {
			http.Error(w, "native callback is not allowed", http.StatusBadRequest)
			return
		}
	}
	pending := store.AuthPending{StateHash: a.digest(state), Verifier: verifier, ReturnTo: safeReturnTo(r.URL.Query().Get("return_to")), CreatedAt: now, ExpiresAt: now.Add(10 * time.Minute), NativeRedirect: nativeRedirect, NativeChallenge: nativeChallenge}
	a.mu.Lock()
	a.pruneLocked(now)
	a.state.Pending = append(a.state.Pending, pending)
	err = a.store.SaveAuthState(a.state)
	a.mu.Unlock()
	if err != nil {
		http.Error(w, "authentication unavailable", http.StatusInternalServerError)
		return
	}
	http.SetCookie(w, secureCookie(oauthCookie, state, 10*time.Minute, true))
	challenge := sha256.Sum256([]byte(verifier))
	query := url.Values{
		"client_id": {a.config.ClientID}, "redirect_uri": {a.callbackURL()}, "state": {state},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(challenge[:])}, "code_challenge_method": {"S256"},
	}
	http.Redirect(w, r, strings.TrimRight(a.config.GitHubBaseURL, "/")+"/login/oauth/authorize?"+query.Encode(), http.StatusFound)
}

func (a *authManager) callback(w http.ResponseWriter, r *http.Request) {
	if !a.config.Enabled || !a.allow(r) {
		http.Error(w, "authentication rejected", http.StatusForbidden)
		return
	}
	state := r.URL.Query().Get("state")
	cookie, err := r.Cookie(oauthCookie)
	if err != nil || state == "" || !hmac.Equal([]byte(state), []byte(cookie.Value)) {
		http.Error(w, "authentication state is invalid", http.StatusBadRequest)
		return
	}
	pending, ok, consumeErr := a.consumePending(state)
	if consumeErr != nil {
		http.Error(w, "authentication unavailable", http.StatusInternalServerError)
		return
	}
	if !ok || r.URL.Query().Get("code") == "" || r.URL.Query().Get("error") != "" {
		http.Error(w, "authentication state has expired", http.StatusBadRequest)
		return
	}
	githubToken, err := a.exchange(r.Context(), r.URL.Query().Get("code"), pending.Verifier)
	if err != nil {
		a.log.Warn("GitHub OAuth token exchange failed", "error", err)
		http.Error(w, "GitHub authentication failed", http.StatusBadGateway)
		return
	}
	user, err := a.githubUser(r.Context(), githubToken)
	githubToken = ""
	if err != nil {
		a.log.Warn("GitHub OAuth identity lookup failed", "error", err)
		http.Error(w, "GitHub identity verification failed", http.StatusBadGateway)
		return
	}
	if user.ID != a.config.AllowedUserID {
		http.Error(w, "this GitHub account is not allowed", http.StatusForbidden)
		return
	}
	if pending.NativeRedirect != "" {
		code, codeErr := a.createNativeCode(user.ID, user.Login, pending.NativeChallenge)
		if codeErr != nil {
			http.Error(w, "authentication unavailable", http.StatusInternalServerError)
			return
		}
		redirect, _ := url.Parse(pending.NativeRedirect)
		query := redirect.Query()
		query.Set("code", code)
		redirect.RawQuery = query.Encode()
		http.SetCookie(w, secureCookie(oauthCookie, "", -time.Hour, true))
		http.Redirect(w, r, redirect.String(), http.StatusFound)
		return
	}
	token, csrf, err := a.createSession(user.ID, user.Login)
	if err != nil {
		http.Error(w, "authentication unavailable", http.StatusInternalServerError)
		return
	}
	http.SetCookie(w, secureCookie(sessionCookie, token, a.config.SessionTTL, true))
	http.SetCookie(w, secureCookie(csrfCookie, csrf, a.config.SessionTTL, false))
	http.SetCookie(w, secureCookie(oauthCookie, "", -time.Hour, true))
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, pending.ReturnTo, http.StatusFound)
}

func (a *authManager) nativeExchange(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if !a.config.Enabled || len(a.config.NativeRedirects) == 0 || !a.allow(r) {
		http.Error(w, "native authentication unavailable", http.StatusForbidden)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request struct {
		Code     string `json:"code"`
		Verifier string `json:"verifier"`
	}
	if json.NewDecoder(r.Body).Decode(&request) != nil || request.Code == "" || request.Verifier == "" {
		http.Error(w, "invalid exchange request", http.StatusBadRequest)
		return
	}
	challenge := sha256.Sum256([]byte(request.Verifier))
	code, ok, consumeErr := a.consumeNativeCode(request.Code, base64.RawURLEncoding.EncodeToString(challenge[:]))
	if consumeErr != nil {
		http.Error(w, "authentication unavailable", http.StatusInternalServerError)
		return
	}
	if !ok {
		http.Error(w, "authorization code is invalid or expired", http.StatusBadRequest)
		return
	}
	token, _, err := a.createSession(code.GitHubID, code.Login)
	if err != nil {
		http.Error(w, "authentication unavailable", http.StatusInternalServerError)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"accessToken": token, "expiresAt": time.Now().UTC().Add(a.config.SessionTTL), "login": code.Login})
}

func (a *authManager) nativeRevoke(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	header := strings.TrimSpace(r.Header.Get("Authorization"))
	if !a.config.Enabled || !strings.HasPrefix(header, "Bearer ") {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	raw := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
	session, ok := a.findSession(raw)
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	if err := a.removeSession(session.TokenHash); err != nil {
		http.Error(w, "sign out failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *authManager) createNativeCode(id int64, login, challenge string) (string, error) {
	raw, err := randomToken(32)
	if err != nil {
		return "", err
	}
	a.mu.Lock()
	a.pruneLocked(time.Now().UTC())
	a.state.Codes = append(a.state.Codes, store.AuthCode{CodeHash: a.digest(raw), Challenge: challenge, GitHubID: id, Login: login, ExpiresAt: time.Now().UTC().Add(2 * time.Minute)})
	err = a.store.SaveAuthState(a.state)
	a.mu.Unlock()
	return raw, err
}

func (a *authManager) consumeNativeCode(raw, challenge string) (store.AuthCode, bool, error) {
	digest := a.digest(raw)
	a.mu.Lock()
	defer a.mu.Unlock()
	a.pruneLocked(time.Now().UTC())
	var found store.AuthCode
	next := a.state.Codes[:0]
	for _, code := range a.state.Codes {
		if found.CodeHash == "" && hmac.Equal([]byte(code.CodeHash), []byte(digest)) && hmac.Equal([]byte(code.Challenge), []byte(challenge)) {
			found = code
			continue
		}
		next = append(next, code)
	}
	a.state.Codes = next
	err := a.store.SaveAuthState(a.state)
	return found, found.CodeHash != "", err
}

func (a *authManager) logout(w http.ResponseWriter, r *http.Request) {
	if !a.config.Enabled {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	session, csrf, ok := a.browserSession(r)
	if !ok || !a.validBrowserRequest(r, csrf) {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	if err := a.removeSession(session.TokenHash); err != nil {
		http.Error(w, "logout failed", http.StatusInternalServerError)
		return
	}
	http.SetCookie(w, secureCookie(sessionCookie, "", -time.Hour, true))
	http.SetCookie(w, secureCookie(csrfCookie, "", -time.Hour, false))
	w.WriteHeader(http.StatusNoContent)
}

func (a *authManager) removeSession(tokenHash string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	next := a.state.Sessions[:0]
	for _, candidate := range a.state.Sessions {
		if candidate.TokenHash != tokenHash {
			next = append(next, candidate)
		}
	}
	a.state.Sessions = next
	return a.store.SaveAuthState(a.state)
}

func (a *authManager) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		protected := strings.HasPrefix(r.URL.Path, "/dieter.v1.DieterService/") || strings.HasPrefix(r.URL.Path, "/assets/agents/")
		if !a.config.Enabled || !protected {
			next.ServeHTTP(w, r)
			return
		}
		_, csrf, cookieAuth, ok := a.authenticate(r)
		if !ok {
			connectAuthError(w, "authentication required")
			return
		}
		if cookieAuth && !a.validBrowserRequest(r, csrf) {
			connectAuthError(w, "invalid request origin or CSRF token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *authManager) authenticate(r *http.Request) (store.AuthSession, string, bool, bool) {
	if header := strings.TrimSpace(r.Header.Get("Authorization")); strings.HasPrefix(header, "Bearer ") {
		session, ok := a.findSession(strings.TrimSpace(strings.TrimPrefix(header, "Bearer ")))
		return session, "", false, ok
	}
	session, csrf, ok := a.browserSession(r)
	return session, csrf, true, ok
}

func (a *authManager) browserSession(r *http.Request) (store.AuthSession, string, bool) {
	tokenCookie, err := r.Cookie(sessionCookie)
	if err != nil {
		return store.AuthSession{}, "", false
	}
	session, ok := a.findSession(tokenCookie.Value)
	if !ok {
		return store.AuthSession{}, "", false
	}
	csrfValue := ""
	if cookie, cookieErr := r.Cookie(csrfCookie); cookieErr == nil && hmac.Equal([]byte(session.CSRFHash), []byte(a.digest(cookie.Value))) {
		csrfValue = cookie.Value
	}
	if csrfValue == "" {
		return store.AuthSession{}, "", false
	}
	return session, csrfValue, true
}

func (a *authManager) findSession(raw string) (store.AuthSession, bool) {
	if raw == "" {
		return store.AuthSession{}, false
	}
	digest := a.digest(raw)
	now := time.Now().UTC()
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, session := range a.state.Sessions {
		if session.ExpiresAt.After(now) && hmac.Equal([]byte(session.TokenHash), []byte(digest)) {
			return session, true
		}
	}
	return store.AuthSession{}, false
}

func (a *authManager) validBrowserRequest(r *http.Request, csrf string) bool {
	return r.Header.Get("Origin") == strings.TrimRight(a.config.PublicURL.String(), "/") && csrf != "" && hmac.Equal([]byte(r.Header.Get("X-Board-CSRF")), []byte(csrf))
}

func (a *authManager) createSession(id int64, login string) (string, string, error) {
	token, err := randomToken(32)
	if err != nil {
		return "", "", err
	}
	csrf, err := randomToken(24)
	if err != nil {
		return "", "", err
	}
	now := time.Now().UTC()
	session := store.AuthSession{TokenHash: a.digest(token), CSRFHash: a.digest(csrf), GitHubID: id, Login: login, CreatedAt: now, LastSeen: now, ExpiresAt: now.Add(a.config.SessionTTL)}
	a.mu.Lock()
	a.pruneLocked(now)
	a.state.Sessions = append(a.state.Sessions, session)
	err = a.store.SaveAuthState(a.state)
	a.mu.Unlock()
	return token, csrf, err
}

func (a *authManager) consumePending(raw string) (store.AuthPending, bool, error) {
	digest := a.digest(raw)
	now := time.Now().UTC()
	a.mu.Lock()
	defer a.mu.Unlock()
	a.pruneLocked(now)
	var found store.AuthPending
	next := a.state.Pending[:0]
	for _, pending := range a.state.Pending {
		if found.StateHash == "" && hmac.Equal([]byte(pending.StateHash), []byte(digest)) {
			found = pending
			continue
		}
		next = append(next, pending)
	}
	a.state.Pending = next
	err := a.store.SaveAuthState(a.state)
	return found, found.StateHash != "", err
}

func (a *authManager) pruneLocked(now time.Time) {
	sessions := a.state.Sessions[:0]
	for _, session := range a.state.Sessions {
		if session.ExpiresAt.After(now) {
			sessions = append(sessions, session)
		}
	}
	a.state.Sessions = sessions
	pending := a.state.Pending[:0]
	for _, item := range a.state.Pending {
		if item.ExpiresAt.After(now) {
			pending = append(pending, item)
		}
	}
	a.state.Pending = pending
	codes := a.state.Codes[:0]
	for _, code := range a.state.Codes {
		if code.ExpiresAt.After(now) {
			codes = append(codes, code)
		}
	}
	a.state.Codes = codes
}

func (a *authManager) digest(value string) string {
	mac := hmac.New(sha256.New, a.config.Secret)
	_, _ = mac.Write([]byte(value))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (a *authManager) callbackURL() string {
	return strings.TrimRight(a.config.PublicURL.String(), "/") + "/auth/github/callback"
}

func (a *authManager) exchange(ctx context.Context, code, verifier string) (string, error) {
	form := url.Values{"client_id": {a.config.ClientID}, "client_secret": {a.config.ClientSecret}, "code": {code}, "redirect_uri": {a.callbackURL()}, "code_verifier": {verifier}}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(a.config.GitHubBaseURL, "/")+"/login/oauth/access_token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := a.client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	var payload struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	decodeErr := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&payload)
	if response.StatusCode != http.StatusOK || decodeErr != nil || payload.AccessToken == "" || payload.Error != "" {
		return "", fmt.Errorf("GitHub token exchange rejected (status=%d code=%q decode=%v)", response.StatusCode, payload.Error, decodeErr)
	}
	return payload.AccessToken, nil
}

func (a *authManager) githubUser(ctx context.Context, token string) (struct {
	ID    int64  `json:"id"`
	Login string `json:"login"`
}, error) {
	var user struct {
		ID    int64  `json:"id"`
		Login string `json:"login"`
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(a.config.GitHubAPIURL, "/")+"/user", nil)
	if err != nil {
		return user, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("User-Agent", "Dieter")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	response, err := a.client.Do(request)
	if err != nil {
		return user, err
	}
	defer response.Body.Close()
	decodeErr := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&user)
	if response.StatusCode != http.StatusOK || decodeErr != nil || user.ID <= 0 || user.Login == "" {
		return user, fmt.Errorf("GitHub user lookup rejected (status=%d decode=%v)", response.StatusCode, decodeErr)
	}
	return user, nil
}

func (a *authManager) allow(r *http.Request) bool {
	host := r.RemoteAddr
	if index := strings.LastIndex(host, ":"); index >= 0 {
		host = host[:index]
	}
	now := time.Now()
	cutoff := now.Add(-10 * time.Minute)
	a.rateMu.Lock()
	defer a.rateMu.Unlock()
	recent := a.rates[host][:0]
	for _, attempt := range a.rates[host] {
		if attempt.After(cutoff) {
			recent = append(recent, attempt)
		}
	}
	if len(recent) >= 30 {
		a.rates[host] = recent
		return false
	}
	a.rates[host] = append(recent, now)
	return true
}

func secureCookie(name, value string, ttl time.Duration, httpOnly bool) *http.Cookie {
	cookie := &http.Cookie{Name: name, Value: value, Path: "/", Secure: true, HttpOnly: httpOnly, SameSite: http.SameSiteLaxMode}
	if ttl < 0 {
		cookie.MaxAge = -1
		cookie.Expires = time.Unix(1, 0)
	} else {
		cookie.MaxAge = int(ttl.Seconds())
		cookie.Expires = time.Now().Add(ttl).UTC()
	}
	return cookie
}

func safeReturnTo(value string) string {
	if value == "" || !strings.HasPrefix(value, "/") || strings.HasPrefix(value, "//") || strings.Contains(value, "\\") || strings.ContainsAny(value, "\r\n") {
		return "/"
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.IsAbs() || parsed.Host != "" {
		return "/"
	}
	return value
}

func randomToken(size int) (string, error) {
	buffer := make([]byte, size)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}

func validPKCEChallenge(value string) bool {
	if len(value) != 43 {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}

func connectAuthError(w http.ResponseWriter, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusUnauthorized)
	_ = json.NewEncoder(w).Encode(map[string]string{"code": "unauthenticated", "message": message})
}
