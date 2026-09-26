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

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"golang.org/x/net/http2"
	"google.golang.org/grpc"
)

type Server struct {
	Config      Config
	Store       *Store
	Keys        *Keys
	Auth        *Auth
	Hub         *Hub
	Quota       *QuotaManager
	Service     *Service
	APIGRPC     *grpc.Server
	RelayGRPC   *grpc.Server
	HTTPHandler http.Handler
}

func NewServer(config Config, store *Store, logger *slog.Logger) (*Server, error) {
	if _, err := compatibilityPolicy(config); err != nil {
		return nil, fmt.Errorf("gateway compatibility policy: %w", err)
	}
	keys, err := LoadOrCreateKeys(store.Root)
	if err != nil {
		return nil, err
	}
	auth := NewAuth(config, store, logger)
	hub := NewHub(store, config)
	service := NewService(store, auth, keys, hub, config)
	quota := NewQuotaManager(store, hub, logger)
	hub.SetQuotaManager(quota)
	service.SetQuotaManager(quota)
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
		w.Header().Set("Cache-Control", "no-store")
		if !config.DevInsecure {
			w.Header().Set("Strict-Transport-Security", "max-age=31536000")
		}
		if strings.HasPrefix(r.URL.Path, "/dieter.gateway.v1.") {
			// Unary gRPC interceptors run after request decoding. Reject missing
			// sessions here as well, before an unauthenticated caller can make
			// the server read and decode a large or stalled protobuf body.
			if gatewayMethodRequiresSession(r.URL.Path) {
				headers := r.Header.Values("Authorization")
				if len(headers) != 1 {
					gatewayAuthenticationRequired(w)
					return
				}
				if _, ok := auth.AuthenticateBearer(headers[0]); !ok {
					gatewayAuthenticationRequired(w)
					return
				}
			}
			api.ServeHTTP(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/dieter.v1.DieterService/") {
			relay.ServeHTTP(w, r)
			return
		}
		httpMux.ServeHTTP(w, r)
	})
	handler = limitGatewayRequestBodies(handler, 15*time.Second)
	return &Server{Config: config, Store: store, Keys: keys, Auth: auth, Hub: hub, Quota: quota, Service: service, APIGRPC: api, RelayGRPC: relay, HTTPHandler: handler}, nil
}

func gatewayMethodRequiresSession(path string) bool {
	switch path {
	case "/dieter.gateway.v1.GatewayService/GetCompatibility",
		"/dieter.gateway.v1.GatewayService/BeginDaemonEnrollment",
		"/dieter.gateway.v1.GatewayService/CompleteDaemonEnrollment",
		"/dieter.gateway.v1.GatewayService/UnenrollDaemon",
		"/dieter.gateway.v1.DaemonLinkService/Connect":
		return false // These methods verify enrollment secrets or daemon proofs.
	default:
		return true
	}
}

func gatewayAuthenticationRequired(w http.ResponseWriter) {
	// A trailers-only gRPC error; native clients receive Unauthenticated.
	w.Header().Set("Content-Type", "application/grpc")
	w.Header().Set("Grpc-Status", "16")
	w.Header().Set("Grpc-Message", "authentication required")
	w.WriteHeader(http.StatusOK)
}

func gatewayHTTP2Config() *http2.Server {
	return &http2.Server{
		MaxConcurrentStreams: 128, IdleTimeout: 2 * time.Minute,
		ReadIdleTimeout: 30 * time.Second, PingTimeout: 15 * time.Second,
		WriteByteTimeout: 15 * time.Second,
	}
}

func publicGatewayUnaryMethod(path string) bool {
	switch path {
	case "/dieter.gateway.v1.GatewayService/GetCompatibility",
		"/dieter.gateway.v1.GatewayService/BeginDaemonEnrollment",
		"/dieter.gateway.v1.GatewayService/CompleteDaemonEnrollment",
		"/dieter.gateway.v1.GatewayService/UnenrollDaemon":
		return true
	default:
		return false
	}
}

func limitGatewayRequestBodies(next http.Handler, timeout time.Duration) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		isRPC := strings.HasPrefix(r.URL.Path, "/dieter.gateway.v1.") || strings.HasPrefix(r.URL.Path, "/dieter.v1.DieterService/")
		if r.ProtoMajor == 1 || publicGatewayUnaryMethod(r.URL.Path) || !isRPC {
			controller := http.NewResponseController(w)
			_ = controller.SetReadDeadline(time.Now().Add(timeout))
			if r.ProtoMajor >= 2 {
				defer controller.SetReadDeadline(time.Time{})
			}
			// HTTP/1 may drain a request body after ServeHTTP returns. Leave its
			// deadline in place; net/http resets it before the next request.
		}
		limit := int64(0)
		if r.ProtoMajor == 1 {
			limit = maxRelayPayload
		}
		if publicGatewayUnaryMethod(r.URL.Path) {
			// Public enrollment RPCs carry short names, Ed25519 keys, secrets,
			// and signatures, never relay payloads. Bound them before decoding.
			limit = 8 << 10
		}
		if limit > 0 {
			if r.ContentLength > limit {
				http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, limit)
		}
		next.ServeHTTP(w, r)
	})
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
	quotaContext, cancelQuota := context.WithCancel(context.Background())
	defer cancelQuota()
	if s.Quota != nil {
		s.Quota.Start(quotaContext)
	}
	httpServer, err := s.httpServer()
	if err != nil {
		return err
	}
	if s.Config.DevInsecure || s.Config.ProxyMode {
		return httpServer.Serve(listener)
	}
	return httpServer.Serve(tls.NewListener(listener, httpServer.TLSConfig))
}

func (s *Server) httpServer() (*http.Server, error) {
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	plaintext := s.Config.DevInsecure || s.Config.ProxyMode
	protocols.SetHTTP2(!plaintext)
	protocols.SetUnencryptedHTTP2(plaintext)
	// Native unencrypted HTTP/2 parses the complete client preface under the
	// header deadline. The old h2c handler hijacked before reading its tail,
	// which cleared deadlines and allowed an incomplete preface to wait forever.
	httpServer := &http.Server{Handler: s.HTTPHandler, Protocols: protocols, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 2 * time.Minute, MaxHeaderBytes: 1 << 20}
	if !plaintext {
		tlsConfig, err := s.TLSConfig()
		if err != nil {
			return nil, err
		}
		httpServer.TLSConfig = tlsConfig
	}
	if err := http2.ConfigureServer(httpServer, gatewayHTTP2Config()); err != nil {
		return nil, err
	}
	return httpServer, nil
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
	logger.Info("Dieter gateway is ready", "address", config.Address, "public_url", config.PublicURL.String(), "store", store.Root)
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
