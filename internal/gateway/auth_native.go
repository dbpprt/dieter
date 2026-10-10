package gateway

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"html/template"
	"net/http"
	"net/url"
	"time"
)

const signInCookie = "__Host-dieter_gateway_sign_in"

// oauthPending is one sign-in attempt between /auth/github/start and the
// GitHub callback. It lives only in the browser, sealed with a key derived from
// the auth secret, so unauthenticated callers cannot fill gateway storage.
type oauthPending struct {
	State           string    `json:"state"`
	Verifier        string    `json:"verifier"`
	NativeRedirect  string    `json:"nativeRedirect,omitempty"`
	NativeChallenge string    `json:"nativeChallenge,omitempty"`
	EnrollmentID    string    `json:"enrollmentId,omitempty"`
	EnrollmentCode  string    `json:"enrollmentCode,omitempty"`
	ExpiresAt       time.Time `json:"expiresAt"`
}

func (a *Auth) pendingAEAD() (cipher.AEAD, error) {
	mac := hmac.New(sha256.New, a.config.AuthSecret)
	_, _ = mac.Write([]byte("dieter-gateway-oauth-pending-v1"))
	block, err := aes.NewCipher(mac.Sum(nil))
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func (a *Auth) sealPending(pending oauthPending) (string, error) {
	raw, err := json.Marshal(pending)
	if err != nil {
		return "", err
	}
	aead, err := a.pendingAEAD()
	if err != nil {
		return "", err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(aead.Seal(nonce, nonce, raw, []byte(oauthCookie))), nil
}

func (a *Auth) openPending(value string) (oauthPending, bool) {
	sealed, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return oauthPending{}, false
	}
	aead, err := a.pendingAEAD()
	if err != nil || len(sealed) < aead.NonceSize() {
		return oauthPending{}, false
	}
	raw, err := aead.Open(nil, sealed[:aead.NonceSize()], sealed[aead.NonceSize():], []byte(oauthCookie))
	if err != nil {
		return oauthPending{}, false
	}
	var pending oauthPending
	if json.Unmarshal(raw, &pending) != nil || pending.State == "" || pending.Verifier == "" {
		return oauthPending{}, false
	}
	return pending, true
}

// confirmNativeSignIn asks before handing an app a session. Any local app can
// open the start URL with its own callback and challenge, and GitHub may skip
// its own consent for an app the user authorized before.
func (a *Auth) confirmNativeSignIn(w http.ResponseWriter, pending oauthPending, githubID int64, login string) {
	redirect, err := url.Parse(pending.NativeRedirect)
	if err != nil || !a.nativeRedirectAllowed(pending.NativeRedirect) {
		a.completion(w, false, "This app callback is not allowed.")
		return
	}
	token, err := randomToken(32)
	if err != nil {
		a.completion(w, false, "Authentication unavailable.")
		return
	}
	expires := time.Now().UTC().Add(2 * time.Minute)
	err = a.store.UpdateAuthState(func(state *AuthState) error {
		pruneAuthState(state, time.Now().UTC())
		if len(state.SignIns) >= maxAuthRecords {
			return errAuthCapacity
		}
		state.SignIns = append(state.SignIns, NativeSignInApproval{TokenHash: a.digest(token), Redirect: pending.NativeRedirect, Challenge: pending.NativeChallenge, GitHubID: githubID, Login: login, ExpiresAt: expires})
		return nil
	})
	if err != nil {
		a.completion(w, false, "Authentication unavailable.")
		return
	}
	cookie := secureCookie(signInCookie, token, time.Until(expires))
	cookie.SameSite = http.SameSiteStrictMode
	http.SetCookie(w, cookie)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// form-action also governs the redirect after submission, so it must allow
	// the configured app scheme.
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'self' "+redirect.Scheme+":")
	_ = nativeSignInConfirmation.Execute(w, map[string]string{"Token": token, "Login": login, "Callback": pending.NativeRedirect})
}

var nativeSignInConfirmation = template.Must(template.New("sign-in").Parse(`<!doctype html><html lang="en"><meta name="viewport" content="width=device-width"><title>Sign in to Dieter</title><style>:root{color-scheme:light dark}body{font:16px system-ui,sans-serif;max-width:38rem;margin:10vh auto;padding:24px;line-height:1.5}dt{font-weight:700}dd{margin:0 0 1rem;overflow-wrap:anywhere}button{font:inherit;padding:.75rem 1rem;cursor:pointer}</style><main><h1>Sign in to Dieter?</h1><p>Only continue if you just started signing in from a Dieter app on this device. Another app may have opened this page to get access to your machines.</p><dl><dt>GitHub account</dt><dd>@{{.Login}}</dd><dt>App callback</dt><dd>{{.Callback}}</dd></dl><p>Signing in gives this app full access to every machine in your Dieter account.</p><form method="post" action="/auth/native/approve"><input type="hidden" name="token" value="{{.Token}}"><button type="submit">Sign in</button></form><p>To cancel, close this window. This confirmation expires within two minutes.</p></main></html>`))

func (a *Auth) approveNativeSignIn(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := r.ParseForm(); err != nil {
		a.completion(w, false, "Invalid sign-in confirmation.")
		return
	}
	token := r.PostForm.Get("token")
	cookie, err := r.Cookie(signInCookie)
	if err != nil || token == "" || !hmac.Equal([]byte(token), []byte(cookie.Value)) {
		a.completion(w, false, "Sign-in confirmation state is invalid.")
		return
	}
	var approval NativeSignInApproval
	err = a.store.UpdateAuthState(func(state *AuthState) error {
		pruneAuthState(state, time.Now().UTC())
		next := state.SignIns[:0]
		for _, item := range state.SignIns {
			if approval.TokenHash == "" && hmac.Equal([]byte(item.TokenHash), []byte(a.digest(token))) {
				approval = item
			} else {
				next = append(next, item)
			}
		}
		state.SignIns = next
		return nil
	})
	http.SetCookie(w, secureCookie(signInCookie, "", -time.Hour))
	if err != nil || approval.TokenHash == "" || !a.config.AllowsGitHubUser(approval.GitHubID) || !a.nativeRedirectAllowed(approval.Redirect) {
		a.completion(w, false, "Sign-in confirmation is invalid or expired.")
		return
	}
	code, err := a.createNativeCode(approval.GitHubID, approval.Login, approval.Challenge)
	if err != nil {
		a.completion(w, false, "Authentication unavailable.")
		return
	}
	redirect, _ := url.Parse(approval.Redirect)
	query := redirect.Query()
	query.Set("code", code)
	redirect.RawQuery = query.Encode()
	http.Redirect(w, r, redirect.String(), http.StatusSeeOther)
}
