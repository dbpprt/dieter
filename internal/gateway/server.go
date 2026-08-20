package gateway

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	gatewayv1 "github.com/dbpprt/nauclio/internal/gen/nauclio/gateway/v1"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
	"google.golang.org/grpc"
)

type Server struct {
	Config      Config
	Store       *Store
	Keys        *Keys
	Auth        *Auth
	Hub         *Hub
	Service     *Service
	APIGRPC     *grpc.Server
	RelayGRPC   *grpc.Server
	HTTPHandler http.Handler
}

func NewServer(config Config, store *Store, logger *slog.Logger) (*Server, error) {
	keys, err := LoadOrCreateKeys(store.Root)
	if err != nil {
		return nil, err
	}
	auth := NewAuth(config, store, logger)
	hub := NewHub(store, config)
	service := NewService(store, auth, keys, hub, config)
	api := grpc.NewServer(
		grpc.UnaryInterceptor(auth.UnaryInterceptor), grpc.StreamInterceptor(auth.StreamInterceptor),
		grpc.MaxRecvMsgSize(maxRelayPayload), grpc.MaxSendMsgSize(maxRelayPayload),
	)
	gatewayv1.RegisterGatewayServiceServer(api, service)
	gatewayv1.RegisterDaemonLinkServiceServer(api, hub)
	relay := newRelayServer(store, auth, keys, hub, config)
	httpMux := http.NewServeMux()
	auth.RegisterHTTP(httpMux)
	var handler http.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
		if strings.HasPrefix(r.URL.Path, "/nauclio.gateway.v1.") {
			api.ServeHTTP(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/nauclio.v1.NauclioService/") {
			relay.ServeHTTP(w, r)
			return
		}
		httpMux.ServeHTTP(w, r)
	})
	if config.DevInsecure || config.ProxyMode {
		handler = h2c.NewHandler(handler, &http2.Server{})
	}
	return &Server{Config: config, Store: store, Keys: keys, Auth: auth, Hub: hub, Service: service, APIGRPC: api, RelayGRPC: relay, HTTPHandler: handler}, nil
}

func (s *Server) TLSConfig() (*tls.Config, error) {
	if s.Config.DevInsecure || s.Config.ProxyMode {
		return nil, nil
	}
	certificate, err := tls.LoadX509KeyPair(s.Config.TLSCertFile, s.Config.TLSKeyFile)
	if err != nil {
		return nil, fmt.Errorf("load gateway TLS certificate: %w", err)
	}
	clientCAs := x509.NewCertPool()
	if !clientCAs.AppendCertsFromPEM(s.Keys.DaemonCAPEM) {
		return nil, errors.New("load daemon client CA")
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}, ClientCAs: clientCAs,
		ClientAuth: tls.VerifyClientCertIfGiven, NextProtos: []string{"h2", "http/1.1"},
	}, nil
}

func (s *Server) Serve(listener net.Listener) error {
	httpServer := &http.Server{Handler: s.HTTPHandler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 2 * time.Minute, MaxHeaderBytes: 1 << 20}
	if s.Config.DevInsecure || s.Config.ProxyMode {
		return httpServer.Serve(listener)
	}
	tlsConfig, err := s.TLSConfig()
	if err != nil {
		return err
	}
	httpServer.TLSConfig = tlsConfig
	return httpServer.Serve(tls.NewListener(listener, tlsConfig))
}

func Listen(config Config, store *Store, logger *slog.Logger) error {
	server, err := NewServer(config, store, logger)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", config.Address)
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	logger.Info("Nauclio gateway is ready", "address", config.Address, "public_url", config.PublicURL.String(), "store", store.Root)
	result := make(chan error, 1)
	go func() { result <- server.Serve(listener) }()
	select {
	case err := <-result:
		return err
	case <-ctx.Done():
		server.APIGRPC.GracefulStop()
		server.RelayGRPC.GracefulStop()
		_ = listener.Close()
		return nil
	}
}
