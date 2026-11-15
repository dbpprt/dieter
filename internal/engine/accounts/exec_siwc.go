package accounts

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// Sign in with ChatGPT (plan §10, proposal P0.5).
const (
	siwcDynamicClient = "dynamic_agent_client"
	siwcScope         = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
	siwcResource      = "https://api.openai.com/v1"
	siwcCallbackPath  = "/auth/callback"
)

// siwcLogin is an OAuth authorization-code login with PKCE whose redirect
// lands on a loopback listener of this daemon (or is pasted from another
// device).
type siwcLogin struct {
	backend   *execBackend
	request   SIWCLoginRequest
	listener  net.Listener
	server    *http.Server
	redirect  string
	verifier  string
	state     string
	nonce     string
	port      int
	callbacks chan url.Values
	updates   chan LoginUpdate
	cancel    context.CancelFunc
	once      sync.Once
}

func randomToken(bytes int) string {
	buffer := make([]byte, bytes)
	_, _ = rand.Read(buffer)
	return base64.RawURLEncoding.EncodeToString(buffer)
}

func (b *execBackend) SIWCLogin(ctx context.Context, request SIWCLoginRequest) (LoginDriver, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	ctx, cancel := context.WithCancel(ctx)
	login := &siwcLogin{
		backend: b, request: request, listener: listener, port: port,
		redirect: fmt.Sprintf("http://127.0.0.1:%d%s", port, siwcCallbackPath),
		verifier: randomToken(32), state: randomToken(16), nonce: randomToken(16),
		callbacks: make(chan url.Values, 1), updates: make(chan LoginUpdate, 8), cancel: cancel,
	}
	mux := http.NewServeMux()
	mux.HandleFunc(siwcCallbackPath, func(w http.ResponseWriter, r *http.Request) {
		if !login.deliver(r.URL.Query()) {
			http.Error(w, "This sign-in already finished.", http.StatusConflict)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "Signed in to Dieter. You can close this tab.\n")
	})
	login.server = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = login.server.Serve(listener) }()
	go login.run(ctx)
	return login, nil
}

func (l *siwcLogin) Updates() <-chan LoginUpdate { return l.updates }

func (l *siwcLogin) Cancel() { l.cancel() }

func (l *siwcLogin) send(ctx context.Context, update LoginUpdate) {
	select {
	case l.updates <- update:
	case <-ctx.Done():
	}
}

// deliver hands the first callback to the login.
func (l *siwcLogin) deliver(query url.Values) bool {
	delivered := false
	l.once.Do(func() {
		l.callbacks <- query
		delivered = true
	})
	return delivered
}

func (l *siwcLogin) authorizeURL() string {
	params := url.Values{
		"response_type":         {"code"},
		"redirect_uri":          {l.redirect},
		"scope":                 {siwcScope},
		"resource":              {siwcResource},
		"state":                 {l.state},
		"nonce":                 {l.nonce},
		"code_challenge_method": {"S256"},
		"code_challenge":        {pkceChallenge(l.verifier)},
		"ext_agent_host_id":     {l.request.HostID},
	}
	if l.request.ClientID == "" {
		params.Set("client_id", siwcDynamicClient)
		params.Set("agent_name_hint", "Dieter")
	} else {
		params.Set("client_id", l.request.ClientID)
		if l.request.IDTokenHint != "" {
			params.Set("id_token_hint", l.request.IDTokenHint)
		}
	}
	return l.backend.issuer + "/api/accounts/authorize?" + params.Encode()
}

func pkceChallenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func (l *siwcLogin) run(ctx context.Context) {
	defer close(l.updates)
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = l.server.Shutdown(shutdownCtx)
		cancel()
	}()
	authorize := l.authorizeURL()
	l.send(ctx, LoginUpdate{Phase: PhaseWaiting, Challenge: Challenge{OpenURL: authorize, LocalURL: authorize, CallbackPort: l.port, Expects: ExpectsCallback}})
	var query url.Values
	select {
	case query = <-l.callbacks:
	case <-ctx.Done():
		return
	}
	l.send(ctx, LoginUpdate{Phase: PhaseCompleting})
	tokens, identity, err := l.complete(ctx, query)
	if err != nil {
		code := "login_failed"
		var classified interface{ Code() string }
		if errors.As(err, &classified) {
			code = classified.Code()
		}
		l.send(ctx, LoginUpdate{Phase: PhaseFailed, ErrorCode: code, ErrorMessage: err.Error()})
		return
	}
	l.send(ctx, LoginUpdate{Phase: PhaseSucceeded, Identity: identity, SIWC: &tokens})
}

// complete checks the callback, exchanges the code and verifies the ID
// token's nonce and audience.
func (l *siwcLogin) complete(ctx context.Context, query url.Values) (SIWCTokens, Identity, error) {
	if query.Get("state") != l.state {
		return SIWCTokens{}, Identity{}, errors.New("the sign-in answer does not belong to this sign-in")
	}
	if failure := query.Get("error"); failure != "" {
		description := query.Get("error_description")
		if description == "" {
			description = failure
		}
		return SIWCTokens{}, Identity{}, fmt.Errorf("OpenAI declined the sign-in: %s", description)
	}
	code := query.Get("code")
	if code == "" {
		return SIWCTokens{}, Identity{}, errors.New("the sign-in answer carries no code")
	}
	clientID := query.Get("client_id")
	if clientID == "" {
		clientID = l.request.ClientID
	}
	if clientID == "" || clientID == siwcDynamicClient {
		return SIWCTokens{}, Identity{}, errors.New("OpenAI issued no client for Dieter")
	}
	form := url.Values{
		"grant_type": {"authorization_code"}, "client_id": {clientID}, "code": {code},
		"code_verifier": {l.verifier}, "redirect_uri": {l.redirect}, "resource": {siwcResource},
	}
	tokens, err := l.backend.tokenRequest(ctx, form, SIWCTokens{ClientID: clientID, HostID: l.request.HostID})
	if err != nil {
		return SIWCTokens{}, Identity{}, err
	}
	claims := jwtClaims(tokens.IDToken)
	if claims == nil {
		return SIWCTokens{}, Identity{}, errors.New("OpenAI returned no ID token")
	}
	if nonce, _ := claims["nonce"].(string); nonce != l.nonce {
		return SIWCTokens{}, Identity{}, errors.New("the ID token does not belong to this sign-in")
	}
	if !audienceIncludes(claims["aud"], clientID) {
		return SIWCTokens{}, Identity{}, errors.New("the ID token was issued to another client")
	}
	return tokens, siwcIdentity(claims), nil
}

func audienceIncludes(audience any, clientID string) bool {
	switch value := audience.(type) {
	case string:
		return value == clientID
	case []any:
		for _, item := range value {
			if item == clientID {
				return true
			}
		}
	}
	return false
}

func siwcIdentity(claims map[string]any) Identity {
	identity := Identity{WorkspaceID: openAIClaim(claims, "chatgpt_account_id"), Plan: openAIClaim(claims, "chatgpt_plan_type")}
	identity.Subject, _ = claims["sub"].(string)
	identity.Email, _ = claims["email"].(string)
	return identity
}

// tokenRequest posts to OpenAI's token endpoint and merges the answer into
// base (a refresh keeps the refresh token when none is returned).
func (b *execBackend) tokenRequest(ctx context.Context, form url.Values, base SIWCTokens) (SIWCTokens, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, b.issuer+"/api/accounts/oauth/token", strings.NewReader(form.Encode()))
	if err != nil {
		return base, err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Accept", "application/json")
	response, err := b.http.Do(request)
	if err != nil {
		return base, fault.Errorf(fault.Unavailable, "OpenAI's sign-in server did not answer: %v", err)
	}
	defer drain(response.Body)
	var body struct {
		AccessToken       string      `json:"access_token"`
		RefreshToken      string      `json:"refresh_token"`
		IDToken           string      `json:"id_token"`
		Scope             string      `json:"scope"`
		ExpiresIn         json.Number `json:"expires_in"`
		EarliestRefreshAt json.Number `json:"earliest_refresh_at"`
		Error             string      `json:"error"`
		Description       string      `json:"error_description"`
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 1<<20))
	decoder.UseNumber()
	if err := decoder.Decode(&body); err != nil {
		return base, fmt.Errorf("OpenAI's sign-in server answered HTTP %d without JSON", response.StatusCode)
	}
	if response.StatusCode != http.StatusOK || body.AccessToken == "" {
		reason := body.Description
		if reason == "" {
			reason = body.Error
		}
		if reason == "" {
			reason = "HTTP " + strconv.Itoa(response.StatusCode)
		}
		if body.Error == "invalid_grant" {
			return base, &siwcError{code: "invalid_grant", message: "the Sign in with ChatGPT session ended: " + reason}
		}
		return base, fmt.Errorf("OpenAI refused the token request: %s", reason)
	}
	tokens := base
	tokens.AccessToken = body.AccessToken
	if body.RefreshToken != "" {
		tokens.RefreshToken = body.RefreshToken
	}
	if body.IDToken != "" {
		tokens.IDToken = body.IDToken
	}
	if body.Scope != "" {
		tokens.Scope = body.Scope
	}
	now := b.now()
	if seconds, err := body.ExpiresIn.Int64(); err == nil && seconds > 0 {
		tokens.ExpiresAt = now.Add(time.Duration(seconds) * time.Second).UTC()
	} else if expiry := claimTime(jwtClaims(body.AccessToken)["exp"]); !expiry.IsZero() {
		tokens.ExpiresAt = expiry.UTC()
	} else {
		tokens.ExpiresAt = now.Add(time.Hour).UTC()
	}
	if seconds, err := body.EarliestRefreshAt.Int64(); err == nil && seconds > 0 {
		tokens.EarliestRefreshAt = time.Unix(seconds, 0).UTC()
	}
	return tokens, nil
}

type siwcError struct{ code, message string }

func (e *siwcError) Error() string { return e.message }
func (e *siwcError) Code() string  { return e.code }

func (b *execBackend) RefreshSIWC(ctx context.Context, tokens SIWCTokens) (SIWCTokens, error) {
	if tokens.RefreshToken == "" || tokens.ClientID == "" {
		return tokens, errors.New("the Sign in with ChatGPT session has no refresh token")
	}
	form := url.Values{"grant_type": {"refresh_token"}, "client_id": {tokens.ClientID}, "refresh_token": {tokens.RefreshToken}, "resource": {siwcResource}}
	return b.tokenRequest(ctx, form, tokens)
}

func (b *execBackend) RevokeSIWC(ctx context.Context, tokens SIWCTokens) error {
	token, hint := tokens.RefreshToken, "refresh_token"
	if token == "" {
		token, hint = tokens.AccessToken, "access_token"
	}
	if token == "" {
		return nil
	}
	form := url.Values{"token": {token}, "token_type_hint": {hint}, "client_id": {tokens.ClientID}}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, b.issuer+"/api/accounts/oauth/revoke", strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := b.http.Do(request)
	if err != nil {
		return fault.Errorf(fault.Unavailable, "OpenAI's sign-in server did not answer: %v", err)
	}
	drain(response.Body)
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("OpenAI refused to revoke the session (HTTP %d)", response.StatusCode)
	}
	return nil
}

// Submit takes the browser's loopback redirect pasted from another device.
func (l *siwcLogin) Submit(_ context.Context, code, callbackURL string) error {
	if callbackURL == "" {
		return fault.New(fault.FailedPrecondition, "paste the address your browser was sent to after signing in")
	}
	address, err := parseCallback(callbackURL, l.port, siwcCallbackPath)
	if err != nil {
		return err
	}
	if !l.deliver(address.Query()) {
		return fault.New(fault.FailedPrecondition, "this sign-in already received an answer")
	}
	return nil
}
