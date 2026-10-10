package server

import (
	"net"
	"net/http"
	"strings"

	"github.com/dbpprt/dieter/internal/localauth"
)

// localDaemonOnly admits a raw request only with the local API token. The
// loopback listener keeps other hosts out; the token keeps out other users and
// processes on this host, which can reach loopback but not the user-only file.
func localDaemonOnly(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !localDaemonRequest(r) {
			http.Error(w, "local daemon requests require a numeric or localhost host and no browser origin", http.StatusForbidden)
			return
		}
		presented := r.Header.Values(localauth.Header)
		if len(presented) != 1 || !localauth.Valid(token, presented[0]) {
			http.Error(w, "local daemon requests require the local API token", http.StatusUnauthorized)
			return
		}
		r.Header.Del(localauth.Header)
		next.ServeHTTP(w, r)
	})
}

// A loopback listener alone does not prevent DNS rebinding: a browser can
// resolve an attacker-owned hostname to loopback and send same-origin RPCs.
// Native clients use literal addresses (including the Android emulator host
// alias) or localhost. The raw daemon has no browser UI or browser API clients.
func localDaemonRequest(r *http.Request) bool {
	if len(r.Header.Values("Origin")) != 0 {
		return false
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "none" {
		return false
	}
	host := r.Host
	if parsed, _, err := net.SplitHostPort(host); err == nil {
		host = parsed
	}
	host = strings.Trim(host, "[]")
	return strings.EqualFold(host, "localhost") || net.ParseIP(host) != nil
}
