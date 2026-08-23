package gateway

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
)

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
