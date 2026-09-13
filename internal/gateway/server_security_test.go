package gateway

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

type repeatedBody struct{ read int64 }

func (b *repeatedBody) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'x'
	}
	b.read += int64(len(p))
	return len(p), nil
}

func TestGatewayRejectsUnauthenticatedRPCBeforeReadingBody(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	server, err := NewServer(Config{}, store, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer server.APIGRPC.Stop()
	defer server.RelayGRPC.Stop()
	for _, headers := range [][]string{nil, {"Bearer invalid"}, {"Bearer one", "Bearer two"}} {
		body := &repeatedBody{}
		request := httptest.NewRequest(http.MethodPost, "https://gateway.example/dieter.gateway.v1.GatewayService/GetAccount", body)
		request.ProtoMajor = 2
		request.Header.Set("Content-Type", "application/grpc")
		for _, value := range headers {
			request.Header.Add("Authorization", value)
		}
		response := httptest.NewRecorder()
		server.HTTPHandler.ServeHTTP(response, request)
		if response.Header().Get("Grpc-Status") != "16" || body.read != 0 {
			t.Fatalf("unauthenticated response=%v body bytes read=%d", response.Header(), body.read)
		}
	}
}

func TestGatewayBoundsHTTP1BodiesBeforeRouting(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	server, err := NewServer(Config{DevInsecure: true}, store, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer server.APIGRPC.Stop()
	defer server.RelayGRPC.Stop()
	for _, upgrade := range []string{"h2c", "other, h2c"} {
		t.Run(upgrade, func(t *testing.T) {
			body := &repeatedBody{}
			request := httptest.NewRequest(http.MethodPost, "http://localhost/healthz", body)
			request.Header.Set("Connection", "Upgrade, HTTP2-Settings")
			request.Header.Set("Upgrade", upgrade)
			request.Header.Set("HTTP2-Settings", "")
			response := httptest.NewRecorder()
			server.HTTPHandler.ServeHTTP(response, request)
			if response.Code < 400 || body.read > maxRelayPayload+1 {
				t.Fatalf("status=%d read=%d; unbounded upgrade body", response.Code, body.read)
			}
		})
	}
	request := httptest.NewRequest(http.MethodPost, "http://localhost/healthz", io.LimitReader(&repeatedBody{}, maxRelayPayload+1))
	request.ContentLength = maxRelayPayload + 1
	response := httptest.NewRecorder()
	server.HTTPHandler.ServeHTTP(response, request)
	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized declared body status=%d", response.Code)
	}
}

func TestGatewayClosesIncompleteHTTP2Preface(t *testing.T) {
	gateway := &Server{Config: Config{DevInsecure: true}, HTTPHandler: http.NotFoundHandler()}
	server, err := gateway.httpServer()
	if err != nil {
		t.Fatal(err)
	}
	server.ReadHeaderTimeout = 100 * time.Millisecond
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	go func() { _ = server.Serve(listener) }()
	connection, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if _, err := io.WriteString(connection, "PRI * HTTP/2.0\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	if err := connection.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadAll(connection); err != nil {
		if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
			t.Fatal("incomplete prior-knowledge HTTP/2 preface outlived the header deadline")
		}
	}
}

func TestGatewayTimesOutPublicUnaryHTTP2Bodies(t *testing.T) {
	for _, method := range []string{"BeginDaemonEnrollment", "CompleteDaemonEnrollment", "UnenrollDaemon"} {
		t.Run(method, func(t *testing.T) {
			bodyResult := make(chan error, 1)
			handler := limitGatewayRequestBodies(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, err := io.ReadAll(r.Body)
				bodyResult <- err
				http.Error(w, "body deadline", http.StatusRequestTimeout)
			}), 100*time.Millisecond)
			gateway := &Server{Config: Config{DevInsecure: true}, HTTPHandler: handler}
			server, err := gateway.httpServer()
			if err != nil {
				t.Fatal(err)
			}
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			go func() { _ = server.Serve(listener) }()
			transport := &http2.Transport{AllowHTTP: true, DialTLSContext: func(ctx context.Context, network, address string, _ *tls.Config) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, address)
			}}
			defer transport.CloseIdleConnections()
			reader, writer := io.Pipe()
			defer reader.Close()
			defer writer.Close()
			request, err := http.NewRequest(http.MethodPost, "http://"+listener.Addr().String()+"/dieter.gateway.v1.GatewayService/"+method, reader)
			if err != nil {
				t.Fatal(err)
			}
			go func() { _, _ = writer.Write([]byte{0}) }()
			client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
			response, err := client.Do(request)
			if err != nil {
				t.Fatalf("timed-out body did not produce a bounded response: %v", err)
			}
			defer response.Body.Close()
			if response.StatusCode != http.StatusRequestTimeout {
				t.Fatalf("slow body status=%d", response.StatusCode)
			}
			select {
			case err := <-bodyResult:
				if !errors.Is(err, os.ErrDeadlineExceeded) {
					t.Fatalf("slow body ended for a reason other than the read deadline: %v", err)
				}
			case <-time.After(time.Second):
				t.Fatal("public unary body reader did not return")
			}
		})
	}
}

func TestGatewayCapsPublicUnaryBodiesWithoutCappingDaemonFrames(t *testing.T) {
	for _, path := range []string{
		"/dieter.gateway.v1.GatewayService/BeginDaemonEnrollment",
		"/dieter.gateway.v1.GatewayService/CompleteDaemonEnrollment",
		"/dieter.gateway.v1.GatewayService/UnenrollDaemon",
		"/dieter.gateway.v1.DaemonLinkService/Connect",
	} {
		t.Run(path, func(t *testing.T) {
			var read int
			var readErr error
			handler := limitGatewayRequestBodies(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				data, err := io.ReadAll(r.Body)
				read, readErr = len(data), err
			}), time.Second)
			request := httptest.NewRequest(http.MethodPost, "http://localhost"+path, io.LimitReader(&repeatedBody{}, 9<<10))
			request.ProtoMajor = 2
			handler.ServeHTTP(httptest.NewRecorder(), request)
			if publicGatewayUnaryMethod(path) {
				var limitError *http.MaxBytesError
				if read != 8<<10 || !errors.As(readErr, &limitError) {
					t.Fatalf("public unary body was not bounded: read=%d err=%v", read, readErr)
				}
			} else if read != 9<<10 || readErr != nil {
				t.Fatalf("daemon frame stream was incorrectly capped: read=%d err=%v", read, readErr)
			}
		})
	}
}

func TestGatewaySecurityHeaders(t *testing.T) {
	for _, insecure := range []bool{false, true} {
		store, err := OpenStore(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		origin, _ := url.Parse("https://gateway.example")
		server, err := NewServer(Config{DevInsecure: insecure, PublicURL: origin}, store, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer server.APIGRPC.Stop()
		defer server.RelayGRPC.Stop()
		for _, path := range []string{"/", "/healthz", "/auth/github/callback?state=invalid"} {
			response := httptest.NewRecorder()
			server.HTTPHandler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, origin.String()+path, nil))
			if response.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("cacheable response at %s", path)
			}
			if got := response.Header().Get("Strict-Transport-Security"); (got != "") == insecure {
				t.Fatalf("HSTS=%q insecure=%v", got, insecure)
			}
		}
	}
}
