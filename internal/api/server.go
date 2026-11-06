package api

import (
	"context"
	"log/slog"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/engine"
	"github.com/dbpprt/dieter/internal/engine/scheduler"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/git/changeset"
	"github.com/dbpprt/dieter/internal/git/operations"
	"github.com/dbpprt/dieter/internal/git/workspace"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/host/machine"
	"github.com/dbpprt/dieter/internal/host/remoteexec"
	"github.com/dbpprt/dieter/internal/host/terminal"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/daemonstate"
	"github.com/dbpprt/dieter/internal/store/vaults"
	"github.com/dbpprt/dieter/internal/transport/controlrtc"
)

type Server struct {
	privacyMu       sync.Mutex
	privacyDriver   remotedesktop.PrivacyDriver
	privacyBootID   func(context.Context) (string, error)
	privacySnapshot *dieterv1.MachinePrivacy
	privacyReadAt   time.Time
	kvWatches       atomic.Int32
	channelWatches  atomic.Int32
	changeStreams   atomic.Int32
	local           *localChanges
	previews        *payloadPreviewCache
	// commandMu serializes idempotent create/send/start commands.
	commandMu sync.Mutex
	// Recent conversation snapshots per card for delta watches.
	snapshotMu              sync.Mutex
	snapshotCache           map[string]snapshotHistory
	snapshotTick            uint64
	controlRTC              *controlrtc.Manager
	trust                   DeviceTrust
	store                   *store.Store
	vaults                  *vaults.Store
	daemonState             *daemonstate.Store
	app                     *engine.Service
	workspaces              *workspace.Manager
	changesets              *changeset.Service
	gitOperations           *operations.Manager
	schedules               *scheduler.Manager
	log                     *slog.Logger
	mux                     *http.ServeMux
	localToken              string
	filesMu                 sync.RWMutex
	terminals               *terminal.Manager
	executions              *remoteexec.Manager
	remoteDesktop           *remotedesktop.Manager
	machine                 *machine.Collector
	machineAction           func(context.Context, machine.Operation) error
	machineCapabilities     func(context.Context) []machine.OperationCapability
	machineDelay            time.Duration
	machineOperationMu      sync.Mutex
	machineOperations       map[string]acceptedMachineOperation
	machineOperationOrder   []string
	pendingMachineOperation string
}

// Options provides explicit seams for the daemon composition root and native
// end-to-end fixtures. The daemon wires every collaborator explicitly; a nil
// collaborator receives an isolated default so tests can construct a handler
// directly. Production callers leave machine operations unset and receive the
// platform collector, capability probe, and executor. Tests can substitute a
// no-op executor without weakening the authenticated RPC or its validation.
// A static catalog retains release choices without running provider
// discovery.
type Options struct {
	PrivacyDriver remotedesktop.PrivacyDriver
	PrivacyBootID func(context.Context) (string, error)
	ControlRTC    *controlrtc.Manager
	// Trust is the enrolled daemon's device roster; leave it nil (not a typed
	// nil) for an unenrolled daemon.
	Trust  DeviceTrust
	Runner harness.Runner
	// Catalog and MinimumFreeBytes configure a default App; see app.Options.
	Catalog             *harness.Catalog
	MinimumFreeBytes    *uint64
	RemoteDesktop       *remotedesktop.Manager
	MachineAction       func(context.Context, machine.Operation) error
	MachineCapabilities func(context.Context) []machine.OperationCapability
	MachineDelay        time.Duration

	// DaemonState is shared with the gateway link, which records the
	// compatibility policy this server enforces.
	DaemonState *daemonstate.Store
	App         *engine.Service
	Schedules   *scheduler.Manager
	Terminals   *terminal.Manager
	Executions  *remoteexec.Manager
	Machine     *machine.Collector
}

func New(data *store.Store, logger *slog.Logger) *Server {
	return NewWithOptions(data, logger, Options{})
}

func NewWithRunner(data *store.Store, logger *slog.Logger, runner harness.Runner) *Server {
	return NewWithOptions(data, logger, Options{Runner: runner})
}

func NewWithRemoteDesktop(data *store.Store, logger *slog.Logger, runner harness.Runner, remoteDesktop *remotedesktop.Manager) *Server {
	return NewWithOptions(data, logger, Options{Runner: runner, RemoteDesktop: remoteDesktop})
}

// NewWithOptions builds the API server over explicitly provided collaborators,
// constructing isolated defaults only for those left nil.
func NewWithOptions(data *store.Store, logger *slog.Logger, options Options) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	service := options.App
	if service == nil {
		service = engine.NewWithOptions(data, engine.Options{Runner: options.Runner, Catalog: options.Catalog, MinimumFreeBytes: options.MinimumFreeBytes})
	}
	s := &Server{
		store: data, vaults: vaults.New(data), daemonState: options.DaemonState, app: service, workspaces: service.Workspaces, schedules: options.Schedules, log: logger,
		mux: http.NewServeMux(), terminals: options.Terminals, executions: options.Executions, previews: &payloadPreviewCache{},
		remoteDesktop: options.RemoteDesktop, machine: options.Machine, controlRTC: options.ControlRTC, trust: options.Trust,
		machineAction:       options.MachineAction,
		machineCapabilities: options.MachineCapabilities, machineDelay: options.MachineDelay,
		machineOperations: map[string]acceptedMachineOperation{},
	}
	if s.daemonState == nil {
		s.daemonState = daemonstate.New(data)
	}
	if s.schedules == nil {
		s.schedules = scheduler.New(data, service)
	}
	if s.terminals == nil {
		s.terminals = terminal.NewPersistent(data.Root, terminal.Options{})
	}
	if s.executions == nil {
		s.executions = remoteexec.New()
	}
	if s.remoteDesktop == nil {
		s.remoteDesktop = remotedesktop.New(remotedesktop.Options{Logger: logger, Source: remotedesktop.SourceOptions{StateRoot: data.Root, ClipboardDirectory: filepath.Join(data.Root, "clipboard")}})
	}
	if s.machine == nil {
		s.machine = machine.NewCollector(data.Root)
	}
	hostOperations := machine.NewOperations(data.Root)
	if s.machineAction == nil {
		s.machineAction = hostOperations.Execute
	}
	if s.machineCapabilities == nil {
		s.machineCapabilities = hostOperations.Capabilities
	}
	if s.machineDelay <= 0 {
		s.machineDelay = 750 * time.Millisecond
	}
	if token, err := localauth.Ensure(data.Root); err != nil {
		logger.Error("local API token is unavailable; the raw API rejects every request", "error", err)
	} else {
		s.localToken = token
	}
	if options.PrivacyDriver != nil {
		s.privacyDriver = options.PrivacyDriver
	} else {
		privacy := remotedesktop.NewNativePrivacy(data.Root, "", false)
		s.privacyDriver, s.privacyBootID = privacy, privacy.BootID
	}
	if options.PrivacyBootID != nil {
		s.privacyBootID = options.PrivacyBootID
	}
	s.changesets = changeset.New(s.workspaces)
	s.local = newLocalChanges(s)
	service.BackgroundProcesses = s.backgroundProcess
	if err := data.Workspaces.InterruptRunningGitOperations(); err != nil {
		logger.Warn("could not reconcile interrupted Git operations", "error", err)
	}
	s.gitOperations = operations.New(data, s.workspaces, logger)
	s.gitOperations.Changesets = s.changesets
	s.gitOperations.Busy = func(cardID string) bool {
		workspacePath := ""
		if value, err := data.Workspaces.Get(cardID); err == nil {
			workspacePath = value.Path
			if resolved, resolveErr := filepath.EvalSymlinks(workspacePath); resolveErr == nil {
				workspacePath = resolved
			}
		}
		for _, session := range s.terminals.List("") {
			insideWorkspace := false
			if workspacePath != "" {
				workingDirectory := session.WorkingDirectory
				if resolved, resolveErr := filepath.EvalSymlinks(workingDirectory); resolveErr == nil {
					workingDirectory = resolved
				}
				if relative, err := filepath.Rel(workspacePath, workingDirectory); err == nil {
					insideWorkspace = relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
				}
			}
			if session.Status == terminal.StatusRunning && (session.CardID == cardID || insideWorkspace) {
				return true
			}
		}
		for _, execution := range s.executions.List("", "", remoteexec.StatusRunning) {
			if execution.CardID == cardID {
				return true
			}
			workingDirectory := execution.WorkingDirectory
			if resolved, resolveErr := filepath.EvalSymlinks(workingDirectory); resolveErr == nil {
				workingDirectory = resolved
			}
			if workspacePath != "" {
				if relative, err := filepath.Rel(workspacePath, workingDirectory); err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
					return true
				}
			}
		}
		return false
	}
	s.gitOperations.BusyPath = func(workspacePath string) bool {
		if resolved, resolveErr := filepath.EvalSymlinks(workspacePath); resolveErr == nil {
			workspacePath = resolved
		}
		contains := func(workingDirectory string) bool {
			if resolved, resolveErr := filepath.EvalSymlinks(workingDirectory); resolveErr == nil {
				workingDirectory = resolved
			}
			relative, relErr := filepath.Rel(workspacePath, workingDirectory)
			return relErr == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
		}
		for _, session := range s.terminals.List("") {
			if session.Status == terminal.StatusRunning && contains(session.WorkingDirectory) {
				return true
			}
		}
		for _, execution := range s.executions.List("", "", remoteexec.StatusRunning) {
			if contains(execution.WorkingDirectory) {
				return true
			}
		}
		return false
	}
	for path, handler := range newService(s).handlers(
		connect.WithInterceptors(&clientCompatibilityInterceptor{state: s.daemonState}, errorInterceptor{}),
	) {
		s.mux.Handle(path, handler)
	}
	s.mux.HandleFunc("/", http.NotFound)
	return s
}

// Handler is the authenticated loopback API. Serve it with LoopbackProtocols
// so gRPC clients can use HTTP/2 with prior knowledge.
func (s *Server) Handler() http.Handler {
	return securityHeaders(s.requestLog(localDaemonOnly(s.localToken, s.mux)))
}

// LoopbackProtocols serves HTTP/1.1 and HTTP/2 with prior knowledge on the
// plaintext loopback listener. Native unencrypted HTTP/2 parses the complete
// client preface under the server's header deadline.
func LoopbackProtocols() *http.Protocols {
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
	return protocols
}

// CloseTerminalSessionsForTesting explicitly destroys every terminal owned by
// an isolated fixture. Production shutdown must use Shutdown so durable shells
// detach and survive daemon replacement.
func (s *Server) CloseTerminalSessionsForTesting(ctx context.Context) {
	for _, session := range s.terminals.List("") {
		_ = s.terminals.Close(session.ID)
	}
	s.terminals.Shutdown(ctx)
}

// ShutdownTerminalSessions detaches durable terminal observers while leaving
// their host shells alive for a replacement Server to restore. It mirrors the
// terminal portion of production daemon shutdown for isolated restart tests.
func (s *Server) ShutdownTerminalSessions(ctx context.Context) {
	s.terminals.Shutdown(ctx)
}

const (
	maxMessageAttachments     = model.MaxAttachments
	maxMessageAttachmentBytes = model.MaxAttachmentBytes
	maxMessageTotalBytes      = model.MaxAttachmentTotalBytes
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
	return model.NormalizeMessageParts(parts)
}

func drainUpdates(updates <-chan engine.TurnUpdate) {
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

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; font-src 'self'; connect-src 'self'")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
		next.ServeHTTP(w, r)
	})
}
