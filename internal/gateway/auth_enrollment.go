package gateway

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"html/template"
	"net/http"
	"time"
)

// GitHub establishes the account identity. A separate, explicit action binds
// that identity to the daemon key: verification links can originate elsewhere.
func (a *Auth) confirmEnrollment(w http.ResponseWriter, pending OAuthPending, githubID int64, login string) {
	record, err := a.store.Enrollment(pending.EnrollmentID)
	if err != nil || record.Approved || record.ConsumedAt != nil || !record.ExpiresAt.After(time.Now().UTC()) || record.UserCode != pending.EnrollmentCode {
		a.completion(w, false, "Daemon enrollment is invalid or expired.")
		return
	}
	token, err := randomToken(32)
	if err != nil {
		a.completion(w, false, "Authentication unavailable.")
		return
	}
	expires := time.Now().UTC().Add(2 * time.Minute)
	if record.ExpiresAt.Before(expires) {
		expires = record.ExpiresAt
	}
	err = a.store.UpdateAuthState(func(state *AuthState) error {
		pruneAuthState(state, time.Now().UTC())
		if len(state.Approvals) >= maxAuthRecords {
			return errAuthCapacity
		}
		state.Approvals = append(state.Approvals, EnrollmentApproval{TokenHash: a.digest(token), EnrollmentID: record.ID, UserCode: record.UserCode, GitHubID: githubID, Login: login, ExpiresAt: expires})
		return nil
	})
	if err != nil {
		a.completion(w, false, "Authentication unavailable.")
		return
	}
	cookie := secureCookie(enrollmentCookie, token, time.Until(expires))
	cookie.SameSite = http.SameSiteStrictMode
	http.SetCookie(w, cookie)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
	fingerprint := sha256.Sum256(record.PublicKey)
	_ = enrollmentConfirmation.Execute(w, map[string]string{"Token": token, "Name": record.Name, "UserCode": record.UserCode, "Login": login, "Fingerprint": hex.EncodeToString(fingerprint[:])})
}

var enrollmentConfirmation = template.Must(template.New("enrollment").Parse(`<!doctype html><html lang="en"><meta name="viewport" content="width=device-width"><title>Approve Dieter machine</title><style>:root{color-scheme:light dark}body{font:16px system-ui,sans-serif;max-width:38rem;margin:10vh auto;padding:24px;line-height:1.5}dt{font-weight:700}dd{margin:0 0 1rem;overflow-wrap:anywhere}button{font:inherit;padding:.75rem 1rem;cursor:pointer}</style><main><h1>Connect this machine?</h1><p>Only approve if you started enrollment in Dieter on a machine you trust. Compare the code with the terminal or app where you started. Do not approve a link sent by someone else.</p><dl><dt>Machine</dt><dd>{{.Name}}</dd><dt>GitHub account</dt><dd>@{{.Login}}</dd><dt>Enrollment code</dt><dd>{{.UserCode}}</dd><dt>Machine key fingerprint (SHA-256)</dt><dd>{{.Fingerprint}}</dd></dl><p>This adds the machine to your Dieter account. Its projects and agent conversations will be accessible through your account.</p><form method="post" action="/auth/enrollment/approve"><input type="hidden" name="token" value="{{.Token}}"><button type="submit">Approve this machine</button></form><p>To cancel, close this window. This confirmation expires within two minutes.</p></main></html>`))

func (a *Auth) approveEnrollment(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := r.ParseForm(); err != nil {
		a.completion(w, false, "Invalid enrollment confirmation.")
		return
	}
	token := r.PostForm.Get("token")
	cookie, err := r.Cookie(enrollmentCookie)
	if err != nil || token == "" || !hmac.Equal([]byte(token), []byte(cookie.Value)) {
		a.completion(w, false, "Enrollment confirmation state is invalid.")
		return
	}
	var approval EnrollmentApproval
	err = a.store.UpdateAuthState(func(state *AuthState) error {
		pruneAuthState(state, time.Now().UTC())
		next := state.Approvals[:0]
		for _, item := range state.Approvals {
			if approval.TokenHash == "" && hmac.Equal([]byte(item.TokenHash), []byte(a.digest(token))) {
				approval = item
			} else {
				next = append(next, item)
			}
		}
		state.Approvals = next
		return nil
	})
	if err != nil || approval.TokenHash == "" || !a.config.AllowsGitHubUser(approval.GitHubID) {
		a.completion(w, false, "Enrollment confirmation is invalid or expired.")
		return
	}
	if err := a.store.ApproveEnrollment(approval.EnrollmentID, approval.UserCode, approval.GitHubID, approval.Login); err != nil {
		a.completion(w, false, "Daemon enrollment is invalid or expired.")
		return
	}
	http.SetCookie(w, secureCookie(enrollmentCookie, "", -time.Hour))
	a.completion(w, true, fmt.Sprintf("The machine is connected through GitHub as @%s. Return to Dieter; this window can be closed.", approval.Login))
}
