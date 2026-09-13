package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/store"
)

func TestRawDaemonRejectsBrowserAndReboundOrigins(t *testing.T) {
	application := New(store.New(t.TempDir()), nil)
	for _, test := range []struct {
		name, host, origin, site string
		want                     int
	}{
		{"native IPv4", "127.0.0.1:4242", "", "", http.StatusOK},
		{"native IPv6", "[::1]:4242", "", "", http.StatusOK},
		{"native localhost", "localhost:4242", "", "", http.StatusOK},
		{"emulator host", "10.0.2.2:4242", "", "", http.StatusOK},
		{"rebound DNS", "attacker.example:4242", "", "", http.StatusForbidden},
		{"rebound same origin", "attacker.example:4242", "http://attacker.example:4242", "same-origin", http.StatusForbidden},
		{"cross origin", "127.0.0.1:4242", "https://attacker.example", "cross-site", http.StatusForbidden},
		{"opaque origin", "localhost:4242", "null", "", http.StatusForbidden},
		{"cross site without origin", "localhost:4242", "", "cross-site", http.StatusForbidden},
		{"hostname suffix", "localhost.attacker.example:4242", "", "", http.StatusForbidden},
	} {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "http://127.0.0.1/dieter.v1.DieterService/Health", strings.NewReader("{}"))
			request.Host = test.host
			request.Header.Set("Content-Type", "application/json")
			if test.origin != "" {
				request.Header.Set("Origin", test.origin)
			}
			if test.site != "" {
				request.Header.Set("Sec-Fetch-Site", test.site)
			}
			response := httptest.NewRecorder()
			application.Handler().ServeHTTP(response, request)
			if response.Code != test.want {
				t.Fatalf("status=%d body=%s; want %d", response.Code, response.Body.String(), test.want)
			}
		})
	}
}
