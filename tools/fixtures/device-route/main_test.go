package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

func TestFixtureTLSRoutePreservesBidirectionalHTTP2AndGRPCTrailers(t *testing.T) {
	upstream := httptest.NewServer(h2c.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Error("upstream must retain HTTP/2")
		}
		w.Header().Set("Content-Type", "application/grpc")
		w.Header().Set("Trailer", "Grpc-Status")
		first := make([]byte, 5)
		if _, err := io.ReadFull(r.Body, first); err != nil {
			t.Error(err)
			return
		}
		w.Write(first)
		w.(http.Flusher).Flush()
		io.Copy(w, r.Body)
		w.Header().Set("Grpc-Status", "0")
	}), &http2.Server{}))
	defer upstream.Close()
	c := configuration{Upstream: upstream.URL, Token: strings.Repeat("a", 48), ControlToken: strings.Repeat("b", 48), OfflineFile: filepath.Join(t.TempDir(), "offline")}
	h, err := handler(c)
	if err != nil {
		t.Fatal(err)
	}
	route := httptest.NewUnstartedServer(h)
	route.EnableHTTP2 = true
	route.StartTLS()
	defer route.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	request, err := http.NewRequestWithContext(ctx, "POST", route.URL+"/dieter.v1.DieterService/Stream", reader)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/grpc")
	request.Header.Set("Authorization", "Bearer "+c.Token)
	go func() { _, _ = writer.Write([]byte("first")) }()
	response, err := route.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	first := make([]byte, 5)
	if _, err := io.ReadFull(response.Body, first); err != nil || string(first) != "first" || response.ProtoMajor != 2 {
		t.Fatalf("stream did not deliver before request EOF: %q, HTTP/%d, %v", first, response.ProtoMajor, err)
	}
	go func() { _, _ = writer.Write([]byte("second")); _ = writer.Close() }()
	tail, err := io.ReadAll(response.Body)
	if err != nil || string(tail) != "second" || response.Trailer.Get("Grpc-Status") != "0" {
		t.Fatalf("stream/trailer lost: %q, %v, %v", tail, response.Trailer, err)
	}
}

func TestAuthenticatedFixtureRouteAndIsolatedControl(t *testing.T) {
	upstream := httptest.NewServer(h2c.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Error("fixture RPC lost HTTP/2")
		}
		w.Write([]byte(r.Header.Get("Authorization")))
	}), &http2.Server{}))
	defer upstream.Close()
	c := configuration{Upstream: upstream.URL, Token: strings.Repeat("a", 48), ControlToken: strings.Repeat("b", 48), OfflineFile: filepath.Join(t.TempDir(), "offline")}
	h, err := handler(c)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		method, path, token string
		status              int
	}{
		{"POST", "/rpc", "", 401}, {"POST", "/rpc", c.ControlToken, 401}, {"POST", "/rpc", c.Token, 200},
		{"POST", "/_fixture/offline", c.Token, 401}, {"GET", "/_fixture/offline", c.ControlToken, 405},
		{"POST", "/_fixture/offline", c.ControlToken, 204}, {"DELETE", "/_fixture/offline", c.ControlToken, 204},
	} {
		r := httptest.NewRequest(tc.method, tc.path, nil)
		r.Header.Set("Authorization", "Bearer "+tc.token)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Fatalf("%s %s: %d, want %d", tc.method, tc.path, w.Code, tc.status)
		}
		if tc.path == "/rpc" && w.Code == 200 && w.Body.String() != "Bearer "+c.Token {
			t.Fatal("fixture authentication was not forwarded")
		}
		if tc.path == "/_fixture/offline" && w.Code == 204 {
			_, statErr := os.Stat(c.OfflineFile)
			if tc.method == "POST" && statErr != nil || tc.method == "DELETE" && !os.IsNotExist(statErr) {
				t.Fatal("control did not change only the isolated trigger", statErr)
			}
		}
	}
}

func TestFixtureRouteRejectsNonLoopbackTargetsAndOversizeRequests(t *testing.T) {
	c := configuration{Token: strings.Repeat("a", 48), ControlToken: strings.Repeat("b", 48), OfflineFile: filepath.Join(t.TempDir(), "offline")}
	for _, endpoint := range []string{"http://example.com:4242", "http://127.0.0.1:4242/private", "http://token@127.0.0.1:4242", "http://localhost:4242", "https://127.0.0.1:4242"} {
		c.Upstream = endpoint
		if _, err := handler(c); err == nil {
			t.Fatal("accepted", endpoint)
		}
	}
	c.Upstream = "http://127.0.0.1:1"
	h, err := handler(c)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("POST", "/rpc", io.NopCloser(strings.NewReader("body")))
	r.Header.Set("Authorization", "Bearer "+c.Token)
	r.ContentLength = 5 << 20
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 400 {
		t.Fatal("accepted oversized request", w.Code)
	}
}
