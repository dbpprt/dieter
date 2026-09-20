package server

import (
	"net"
	"net/http"
	"strings"
)

func localDaemonOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !localDaemonRequest(r) {
			http.Error(w, "local daemon requests require a numeric or localhost host and no browser origin", http.StatusForbidden)
			return
		}
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
