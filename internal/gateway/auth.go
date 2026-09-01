package gateway

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const oauthCookie = "__Host-board_gateway_oauth"

type principalKey struct{}

type Principal struct {
	GitHubID int64
	Login    string
}

type Auth struct {
	config Config
	store  *Store
	client *http.Client
	log    *slog.Logger
	rateMu sync.Mutex
	rates  map[string][]time.Time
}

func NewAuth(config Config, store *Store, logger *slog.Logger) *Auth {
	if logger == nil {
		logger = slog.Default()
	}
	return &Auth{config: config, store: store, client: &http.Client{Timeout: 12 * time.Second}, log: logger, rates: map[string][]time.Time{}}
}

func (a *Auth) RegisterHTTP(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", a.health)
	mux.HandleFunc("GET /auth/github/start", a.start)
	mux.HandleFunc("GET /auth/github/callback", a.callback)
	mux.HandleFunc("POST /auth/native/exchange", a.nativeExchange)
	mux.HandleFunc("POST /auth/native/revoke", a.nativeRevoke)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
}

func (a *Auth) UnaryInterceptor(ctx context.Context, request any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
	if info.FullMethod == "/dieter.gateway.v1.GatewayService/BeginDaemonEnrollment" ||
		info.FullMethod == "/dieter.gateway.v1.GatewayService/CompleteDaemonEnrollment" ||
		info.FullMethod == "/dieter.gateway.v1.GatewayService/UnenrollDaemon" {
		return handler(ctx, request)
	}
	principal, err := a.grpcPrincipal(ctx)
	if err != nil {
		return nil, err
	}
	return handler(context.WithValue(ctx, principalKey{}, principal), request)
}

func (a *Auth) StreamInterceptor(service any, stream grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
	if info.FullMethod == "/dieter.gateway.v1.DaemonLinkService/Connect" {
		return handler(service, stream)
	}
	principal, err := a.grpcPrincipal(stream.Context())
	if err != nil {
		return err
	}
	return handler(service, &contextServerStream{ServerStream: stream, ctx: context.WithValue(stream.Context(), principalKey{}, principal)})
}

type contextServerStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s *contextServerStream) Context() context.Context { return s.ctx }

func PrincipalFromContext(ctx context.Context) (Principal, bool) {
	value, ok := ctx.Value(principalKey{}).(Principal)
	return value, ok
}

func (a *Auth) AuthenticateBearer(raw string) (Principal, bool) {
	raw = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(raw), "Bearer "))
	if raw == "" {
		return Principal{}, false
	}
	digest := a.digest(raw)
	state, err := a.store.AuthState()
	if err != nil {
		return Principal{}, false
	}
	now := time.Now().UTC()
	for _, session := range state.Sessions {
		if session.ExpiresAt.After(now) && hmac.Equal([]byte(session.TokenHash), []byte(digest)) {
			return Principal{GitHubID: session.GitHubID, Login: session.Login}, true
		}
	}
	return Principal{}, false
}

func (a *Auth) grpcPrincipal(ctx context.Context) (Principal, error) {
	values, _ := metadata.FromIncomingContext(ctx)
	headers := values.Get("authorization")
	if len(headers) != 1 {
		return Principal{}, status.Error(codes.Unauthenticated, "authentication required")
	}
	principal, ok := a.AuthenticateBearer(headers[0])
	if !ok {
		return Principal{}, status.Error(codes.Unauthenticated, "authentication required")
	}
	return principal, nil
}

func (a *Auth) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_, _ = io.WriteString(w, `{"status":"ok","service":"dieter-gateway"}`)
}

func (a *Auth) start(w http.ResponseWriter, r *http.Request) {
	if !a.allow(r) {
		http.Error(w, "too many authentication attempts", http.StatusTooManyRequests)
		return
	}
	state, _ := randomToken(32)
	verifier, _ := randomToken(48)
	pending := OAuthPending{StateHash: a.digest(state), Verifier: verifier, CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(10 * time.Minute)}
	nativeRedirect := strings.TrimSpace(r.URL.Query().Get("native_redirect_uri"))
	nativeChallenge := strings.TrimSpace(r.URL.Query().Get("native_code_challenge"))
	if nativeRedirect != "" || nativeChallenge != "" {
		if !a.nativeRedirectAllowed(nativeRedirect) || !validPKCEChallenge(nativeChallenge) {
			http.Error(w, "native callback is not allowed", http.StatusBadRequest)
			return
		}
		pending.NativeRedirect, pending.NativeChallenge = nativeRedirect, nativeChallenge
	}
	if enrollmentID := strings.TrimSpace(r.URL.Query().Get("enrollment_id")); enrollmentID != "" {
		code := strings.ToUpper(strings.TrimSpace(r.URL.Query().Get("user_code")))
		record, err := a.store.Enrollment(enrollmentID)
		if err != nil || record.UserCode != code || record.ExpiresAt.Before(time.Now().UTC()) || record.ConsumedAt != nil {
			http.Error(w, "daemon enrollment is invalid or expired", http.StatusBadRequest)
			return
		}
		pending.EnrollmentID, pending.EnrollmentCode = enrollmentID, code
	}
	if pending.NativeRedirect == "" && pending.EnrollmentID == "" {
		http.Error(w, "a native callback or daemon enrollment is required", http.StatusBadRequest)
		return
	}
	if err := a.store.UpdateAuthState(func(value *AuthState) error {
		pruneAuthState(value, time.Now().UTC())
		value.Pending = append(value.Pending, pending)
		return nil
	}); err != nil {
		http.Error(w, "authentication unavailable", http.StatusInternalServerError)
		return
	}
	http.SetCookie(w, secureCookie(oauthCookie, state, 10*time.Minute))
	digest := sha256.Sum256([]byte(verifier))
	query := url.Values{
		"client_id": {a.config.GitHubClientID}, "redirect_uri": {a.callbackURL()}, "state": {state},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(digest[:])}, "code_challenge_method": {"S256"},
	}
	http.Redirect(w, r, strings.TrimRight(a.config.GitHubBaseURL, "/")+"/login/oauth/authorize?"+query.Encode(), http.StatusFound)
}

// nativeRedirectAllowed accepts configured app schemes and RFC 8252 loopback
// callbacks used by the CLI. The CLI binds the port before starting OAuth and
// protects the one-time code with PKCE, so an unprivileged local process cannot
// redeem a callback intended for another login attempt.
func (a *Auth) nativeRedirectAllowed(raw string) bool {
	if _, ok := a.config.NativeRedirects[raw]; ok {
		return true
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "http" || parsed.User != nil || parsed.Fragment != "" || parsed.RawQuery != "" {
		return false
	}
	if parsed.Hostname() != "127.0.0.1" || parsed.Port() == "" || parsed.Path != "/auth/callback" {
		return false
	}
	port, err := strconv.ParseUint(parsed.Port(), 10, 16)
	return err == nil && port > 0
}

func (a *Auth) callback(w http.ResponseWriter, r *http.Request) {
	state := r.URL.Query().Get("state")
	cookie, err := r.Cookie(oauthCookie)
	if err != nil || state == "" || !hmac.Equal([]byte(state), []byte(cookie.Value)) {
		a.completion(w, false, "Authentication state is invalid.")
		return
	}
	pending, ok, err := a.consumePending(state)
	if err != nil || !ok || r.URL.Query().Get("code") == "" || r.URL.Query().Get("error") != "" {
		a.completion(w, false, "Authentication expired or was rejected.")
		return
	}
	githubToken, err := a.exchange(r.Context(), r.URL.Query().Get("code"), pending.Verifier)
	if err != nil {
		a.log.Warn("GitHub OAuth exchange failed", "error", err)
		a.completion(w, false, "GitHub authentication failed.")
		return
	}
	user, err := a.githubUser(r.Context(), githubToken)
	githubToken = ""
	if err != nil || !a.config.AllowsGitHubUser(user.ID) {
		a.completion(w, false, "This GitHub account is not allowed.")
		return
	}
	if pending.EnrollmentID != "" {
		record, _ := a.store.Enrollment(pending.EnrollmentID)
		if err := a.store.ApproveEnrollment(pending.EnrollmentID, pending.EnrollmentCode, user.ID, user.Login); err != nil {
			a.completion(w, false, err.Error())
			return
		}
		http.SetCookie(w, secureCookie(oauthCookie, "", -time.Hour))
		a.completion(w, true, fmt.Sprintf("%s is connected through GitHub as @%s. Return to the terminal; this window can be closed.", record.Name, user.Login))
		return
	}
	code, err := a.createNativeCode(user.ID, user.Login, pending.NativeChallenge)
	if err != nil {
		a.completion(w, false, "Authentication unavailable.")
		return
	}
	redirect, _ := url.Parse(pending.NativeRedirect)
	query := redirect.Query()
	query.Set("code", code)
	redirect.RawQuery = query.Encode()
	http.SetCookie(w, secureCookie(oauthCookie, "", -time.Hour))
	http.Redirect(w, r, redirect.String(), http.StatusFound)
}

func (a *Auth) completion(w http.ResponseWriter, success bool, message string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
	status := http.StatusOK
	if !success {
		status = http.StatusBadRequest
	}
	w.WriteHeader(status)
	_ = template.Must(template.New("done").Parse(`<!doctype html><meta name="viewport" content="width=device-width"><title>Dieter</title><style>:root{color-scheme:dark}*{box-sizing:border-box}body{font:16px ui-rounded,system-ui,sans-serif;background:radial-gradient(circle at 50% 20%,#27304c,#0a0c12 58%);color:#f7f8ff;display:grid;place-items:center;min-height:100vh;margin:0;padding:24px}main{width:min(100%,34rem);padding:36px;border:1px solid #ffffff1f;border-radius:24px;background:#11141dcc;box-shadow:0 24px 80px #0008}.mark{display:grid;place-items:center;width:52px;height:52px;border-radius:16px;background:#8ca3ff;color:#0a0c12;font-weight:850;font-size:24px}h1{font-size:1.55rem;margin:24px 0 10px}p{color:#c8cede;line-height:1.6;margin:0}.state{margin-top:24px;color:{{if .Success}}#8ee6b1{{else}}#ff9b9b{{end}};font-size:.85rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase}</style><main><div class="mark">N</div><div class="state">{{if .Success}}Authorization complete{{else}}Authorization failed{{end}}</div><h1>{{if .Success}}Dieter is connected{{else}}Dieter could not connect{{end}}</h1><p>{{.Message}}</p></main>`)).Execute(w, map[string]any{"Success": success, "Message": message})
}

func (a *Auth) nativeExchange(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request struct{ Code, Verifier string }
	if json.NewDecoder(r.Body).Decode(&request) != nil || request.Code == "" || request.Verifier == "" {
		http.Error(w, "invalid exchange request", http.StatusBadRequest)
		return
	}
	digest := sha256.Sum256([]byte(request.Verifier))
	code, ok, err := a.consumeNativeCode(request.Code, base64.RawURLEncoding.EncodeToString(digest[:]))
	if err != nil || !ok {
		http.Error(w, "authorization code is invalid or expired", http.StatusBadRequest)
		return
	}
	token, expires, err := a.createSession(code.GitHubID, code.Login)
	if err != nil {
		http.Error(w, "authentication unavailable", http.StatusInternalServerError)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"accessToken": token, "expiresAt": expires, "login": code.Login})
}

func (a *Auth) nativeRevoke(w http.ResponseWriter, r *http.Request) {
	header := r.Header.Get("Authorization")
	principal, ok := a.AuthenticateBearer(header)
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	digest := a.digest(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(header), "Bearer ")))
	err := a.store.UpdateAuthState(func(state *AuthState) error {
		next := state.Sessions[:0]
		for _, session := range state.Sessions {
			if session.TokenHash != digest || session.GitHubID != principal.GitHubID {
				next = append(next, session)
			}
		}
		state.Sessions = next
		return nil
	})
	if err != nil {
		http.Error(w, "sign out failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *Auth) createSession(id int64, login string) (string, time.Time, error) {
	raw, _ := randomToken(32)
	now, expires := time.Now().UTC(), time.Now().UTC().Add(a.config.SessionTTL)
	err := a.store.UpdateAuthState(func(state *AuthState) error {
		pruneAuthState(state, now)
		state.Sessions = append(state.Sessions, Session{TokenHash: a.digest(raw), GitHubID: id, Login: login, CreatedAt: now, ExpiresAt: expires})
		return nil
	})
	return raw, expires, err
}

func (a *Auth) createNativeCode(id int64, login, challenge string) (string, error) {
	raw, _ := randomToken(32)
	err := a.store.UpdateAuthState(func(state *AuthState) error {
		pruneAuthState(state, time.Now().UTC())
		state.Codes = append(state.Codes, NativeCode{CodeHash: a.digest(raw), Challenge: challenge, GitHubID: id, Login: login, ExpiresAt: time.Now().UTC().Add(2 * time.Minute)})
		return nil
	})
	return raw, err
}

func (a *Auth) consumePending(raw string) (OAuthPending, bool, error) {
	var found OAuthPending
	err := a.store.UpdateAuthState(func(state *AuthState) error {
		pruneAuthState(state, time.Now().UTC())
		next := state.Pending[:0]
		for _, pending := range state.Pending {
			if found.StateHash == "" && hmac.Equal([]byte(pending.StateHash), []byte(a.digest(raw))) {
				found = pending
			} else {
				next = append(next, pending)
			}
		}
		state.Pending = next
		return nil
	})
	return found, found.StateHash != "", err
}

func (a *Auth) consumeNativeCode(raw, challenge string) (NativeCode, bool, error) {
	var found NativeCode
	err := a.store.UpdateAuthState(func(state *AuthState) error {
		pruneAuthState(state, time.Now().UTC())
		next := state.Codes[:0]
		for _, code := range state.Codes {
			if found.CodeHash == "" && hmac.Equal([]byte(code.CodeHash), []byte(a.digest(raw))) && hmac.Equal([]byte(code.Challenge), []byte(challenge)) {
				found = code
			} else {
				next = append(next, code)
			}
		}
		state.Codes = next
		return nil
	})
	return found, found.CodeHash != "", err
}

func pruneAuthState(state *AuthState, now time.Time) {
	sessions := state.Sessions[:0]
	for _, item := range state.Sessions {
		if item.ExpiresAt.After(now) {
			sessions = append(sessions, item)
		}
	}
	state.Sessions = sessions
	pending := state.Pending[:0]
	for _, item := range state.Pending {
		if item.ExpiresAt.After(now) {
			pending = append(pending, item)
		}
	}
	state.Pending = pending
	codes := state.Codes[:0]
	for _, item := range state.Codes {
		if item.ExpiresAt.After(now) {
			codes = append(codes, item)
		}
	}
	state.Codes = codes
}

func (a *Auth) digest(value string) string {
	mac := hmac.New(sha256.New, a.config.AuthSecret)
	_, _ = mac.Write([]byte(value))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (a *Auth) callbackURL() string {
	return strings.TrimRight(a.config.PublicURL.String(), "/") + "/auth/github/callback"
}

func (a *Auth) exchange(ctx context.Context, code, verifier string) (string, error) {
	form := url.Values{"client_id": {a.config.GitHubClientID}, "client_secret": {a.config.GitHubSecret}, "code": {code}, "redirect_uri": {a.callbackURL()}, "code_verifier": {verifier}}
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

func (a *Auth) githubUser(ctx context.Context, token string) (struct {
	ID    int64
	Login string
}, error) {
	var user struct {
		ID    int64
		Login string
	}
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(a.config.GitHubAPIURL, "/")+"/user", nil)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("User-Agent", "Dieter Gateway")
	response, err := a.client.Do(request)
	if err != nil {
		return user, err
	}
	defer response.Body.Close()
	err = json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&user)
	if response.StatusCode != http.StatusOK || err != nil || user.ID <= 0 || user.Login == "" {
		return user, fmt.Errorf("GitHub identity lookup rejected")
	}
	return user, nil
}

func (a *Auth) allow(r *http.Request) bool {
	host := r.RemoteAddr
	if index := strings.LastIndex(host, ":"); index >= 0 {
		host = host[:index]
	}
	now, cutoff := time.Now(), time.Now().Add(-10*time.Minute)
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

func randomToken(size int) (string, error) {
	raw := make([]byte, size)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func validPKCEChallenge(value string) bool {
	raw, err := base64.RawURLEncoding.DecodeString(value)
	return err == nil && len(value) == 43 && len(raw) == sha256.Size
}

func secureCookie(name, value string, ttl time.Duration) *http.Cookie {
	cookie := &http.Cookie{Name: name, Value: value, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode}
	if ttl < 0 {
		cookie.MaxAge, cookie.Expires = -1, time.Unix(1, 0)
	} else {
		cookie.MaxAge, cookie.Expires = int(ttl.Seconds()), time.Now().UTC().Add(ttl)
	}
	return cookie
}
