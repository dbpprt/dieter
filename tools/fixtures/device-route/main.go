// Command device-route exposes only an authenticated disposable fixture over
// TLS to a selected physical test device. The live Dieter daemon is never a target.
package main

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/net/http2"
)

type configuration struct {
	Address      string `json:"address"`
	Upstream     string `json:"upstream"`
	Certificate  string `json:"certificate"`
	Key          string `json:"key"`
	Token        string `json:"token"`
	ControlToken string `json:"control_token"`
	OfflineFile  string `json:"offline_file"`
}

func handler(c configuration) (http.Handler, error) {
	u, err := url.Parse(c.Upstream)
	if err != nil || u.Scheme != "http" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" || net.ParseIP(u.Hostname()) == nil || !net.ParseIP(u.Hostname()).IsLoopback() || u.Port() == "" {
		return nil, errors.New("upstream must be a credential-free literal loopback fixture endpoint")
	}
	if len(c.Token) < 32 || len(c.ControlToken) < 32 || c.Token == c.ControlToken || !filepath.IsAbs(c.OfflineFile) {
		return nil, errors.New("private fixture and control tokens plus an absolute offline trigger are required")
	}
	proxy := httputil.NewSingleHostReverseProxy(u)
	proxy.Transport = &http2.Transport{AllowHTTP: true, IdleConnTimeout: 30 * time.Second, ReadIdleTimeout: 30 * time.Second, PingTimeout: 10 * time.Second, DialTLSContext: func(ctx context.Context, network, address string, _ *tls.Config) (net.Conn, error) {
		return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, network, address)
	}}
	proxy.FlushInterval = -1
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
		http.Error(w, "fixture route unavailable", http.StatusBadGateway)
	}
	streams := make(chan struct{}, 32)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case streams <- struct{}{}:
			defer func() { <-streams }()
		default:
			http.Error(w, "fixture route busy", http.StatusServiceUnavailable)
			return
		}
		credential := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.URL.Path == "/_fixture/offline" {
			if subtle.ConstantTimeCompare([]byte(credential), []byte(c.ControlToken)) != 1 {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			if r.ContentLength > 0 || r.ContentLength == -1 {
				http.Error(w, "control requests have no body", http.StatusBadRequest)
				return
			}
			var operationErr error
			switch r.Method {
			case http.MethodPost:
				operationErr = os.WriteFile(c.OfflineFile, nil, 0o600)
			case http.MethodDelete:
				operationErr = os.Remove(c.OfflineFile)
				if errors.Is(operationErr, os.ErrNotExist) {
					operationErr = nil
				}
			default:
				w.Header().Set("Allow", "POST, DELETE")
				http.Error(w, "unsupported control method", http.StatusMethodNotAllowed)
				return
			}
			if operationErr != nil {
				http.Error(w, "fixture control failed", http.StatusInternalServerError)
				return
			}
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if subtle.ConstantTimeCompare([]byte(credential), []byte(c.Token)) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.ContentLength > 4<<20 || r.URL.RawQuery != "" {
			http.Error(w, "invalid fixture request", http.StatusBadRequest)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
		proxy.ServeHTTP(w, r)
	}), nil
}

func run(input io.Reader, output io.Writer) error {
	var c configuration
	decoder := json.NewDecoder(io.LimitReader(input, 64<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&c); err != nil {
		return errors.New("invalid private route configuration")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return errors.New("private route accepts one configuration object")
	}
	h, err := handler(c)
	if err != nil {
		return err
	}
	certificate, err := tls.LoadX509KeyPair(c.Certificate, c.Key)
	if err != nil {
		return errors.New("fixture TLS certificate/key unavailable")
	}
	listener, err := net.Listen("tcp", c.Address)
	if err != nil {
		return errors.New("fixture TLS address unavailable")
	}
	defer listener.Close()
	server := &http.Server{Handler: h, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 << 10, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{certificate}, NextProtos: []string{"h2", "http/1.1"}}}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	go func() {
		<-ctx.Done()
		closeCtx, closeCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer closeCancel()
		_ = server.Shutdown(closeCtx)
	}()
	if err := json.NewEncoder(output).Encode(map[string]string{"address": listener.Addr().String()}); err != nil {
		return err
	}
	err = server.ServeTLS(listener, "", "")
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
