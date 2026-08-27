package server

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/dbpprt/dieter/internal/app"
	"github.com/dbpprt/dieter/internal/attachments"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/machine"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/scheduler"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/terminal"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

type Server struct {
	store         *store.Store
	app           *app.Service
	schedules     *scheduler.Manager
	log           *slog.Logger
	mux           *http.ServeMux
	filesMu       sync.RWMutex
	auth          *authManager
	terminals     *terminal.Manager
	remoteDesktop *remotedesktop.Manager
	machine       *machine.Collector
	machineAction func(context.Context, machine.Operation) error
	machineDelay  time.Duration
}

func New(data *store.Store, logger *slog.Logger) *Server {
	return NewWithRunner(data, logger, nil)
}

func NewWithRunner(data *store.Store, logger *slog.Logger, runner harness.Runner) *Server {
	manager, _ := newAuthManager(authConfig{}, data)
	return newWithAuth(data, logger, runner, manager)
}

func NewWithRemoteDesktop(data *store.Store, logger *slog.Logger, runner harness.Runner, remoteDesktop *remotedesktop.Manager) *Server {
	application := NewWithRunner(data, logger, runner)
	if remoteDesktop != nil {
		application.remoteDesktop = remoteDesktop
	}
	return application
}

func newWithAuth(data *store.Store, logger *slog.Logger, runner harness.Runner, manager *authManager) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	manager.log = logger
	service := app.New(data, runner)
	s := &Server{
		store: data, app: service, schedules: scheduler.New(data, service), log: logger,
		mux: http.NewServeMux(), auth: manager, terminals: terminal.New(),
		remoteDesktop: remotedesktop.New(remotedesktop.Options{Logger: logger}),
		machine:       machine.NewCollector(data.Root), machineAction: machine.ExecuteOperation,
		machineDelay: 750 * time.Millisecond,
	}
	manager.register(s.mux)
	path, handler := dieterv1connect.NewDieterServiceHandler(&connectAPI{core: &grpcAPI{server: s}})
	s.mux.Handle(path, handler)
	s.mux.HandleFunc("/", http.NotFound)
	return s
}

func (s *Server) Handler() http.Handler {
	return h2c.NewHandler(securityHeaders(s.auth.config.Enabled, s.requestLog(s.auth.middleware(s.mux))), &http2.Server{})
}

const (
	maxMessageAttachments     = attachments.MaxCount
	maxMessageAttachmentBytes = attachments.MaxFileBytes
	maxMessageTotalBytes      = attachments.MaxTotalBytes
)

func validateUserMessageParts[T interface {
	~struct{ Type, Text, MediaType, Filename, URL string }
}](wire []T) ([]model.UIMessagePart, error) {
	parts := make([]model.UIMessagePart, 0, len(wire))
	for _, value := range wire {
		part := struct{ Type, Text, MediaType, Filename, URL string }(value)
		parts = append(parts, model.UIMessagePart{
			Type: part.Type, Text: part.Text, MediaType: part.MediaType,
			Filename: part.Filename, URL: part.URL,
		})
	}
	return attachments.NormalizeMessageParts(parts)
}

func drainUpdates(updates <-chan app.TurnUpdate) {
	for range updates {
	}
}

func (s *Server) requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		next.ServeHTTP(w, r)
		s.log.Debug("request", "method", r.Method, "path", r.URL.Path, "duration", time.Since(started))
	})
}

func securityHeaders(public bool, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; font-src 'self'; connect-src 'self'")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
		if public {
			w.Header().Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		}
		next.ServeHTTP(w, r)
	})
}

func Listen(addr string, data *store.Store, runner harness.Runner, logger *slog.Logger) error {
	config, err := authConfigFromEnv()
	if err != nil {
		return fmt.Errorf("configure authentication: %w", err)
	}
	manager, err := newAuthManager(config, data)
	if err != nil {
		return fmt.Errorf("configure authentication: %w", err)
	}
	application := newWithAuth(data, logger, runner, manager)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return run(ctx, addr, data, application, logger)
}

// ListenDaemon runs Board's machine-local data plane without public OAuth.
// Authentication for remote clients is enforced by the gateway or the
// daemon's direct TLS listener, never by this loopback-only endpoint.
func ListenDaemon(ctx context.Context, addr string, data *store.Store, runner harness.Runner, logger *slog.Logger, remoteDesktop ...*remotedesktop.Manager) error {
	manager, err := newAuthManager(authConfig{}, data)
	if err != nil {
		return err
	}
	application := newWithAuth(data, logger, runner, manager)
	if len(remoteDesktop) > 0 && remoteDesktop[0] != nil {
		application.remoteDesktop = remoteDesktop[0]
	}
	return run(ctx, addr, data, application, logger)
}

func run(ctx context.Context, addr string, data *store.Store, application *Server, logger *slog.Logger) error {
	reconcile := func() {
		recovered, recoveryErr := application.app.ReconcileOrphanedTurns()
		if recoveryErr != nil {
			logger.Warn("some orphaned agent turns could not be fully reconciled", "error", recoveryErr)
		}
		if len(recovered) > 0 {
			logger.Info("reconciled orphaned agent turns", "cards", recovered)
		}
	}
	reconcile()
	// During a launchd/systemd replacement the previous owner PID can remain
	// alive for a fraction of a second after the new process starts. Recheck
	// once after handoff so that transiently-valid leases cannot strand a turn.
	go func() {
		timer := time.NewTimer(time.Second)
		defer timer.Stop()
		select {
		case <-ctx.Done():
		case <-timer.C:
			reconcile()
		}
	}()
	application.schedules.Start(ctx)
	httpServer := &http.Server{Addr: addr, Handler: application.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 1 << 20}
	logger.Info("board is ready", "url", fmt.Sprintf("http://%s", addr), "store", data.Root)
	serveErr := make(chan error, 1)
	go func() { serveErr <- httpServer.ListenAndServe() }()
	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer shutdownCancel()
	if err := application.app.SuspendActiveTurns(shutdownCtx); err != nil {
		logger.Warn("some active agent turns could not be suspended for restart", "error", err)
	}
	application.terminals.Shutdown(shutdownCtx)
	application.remoteDesktop.Shutdown(shutdownCtx)
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		_ = httpServer.Close()
	}
	return <-serveErr
}
