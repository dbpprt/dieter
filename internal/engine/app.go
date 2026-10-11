package engine

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/git/workspace"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

type Service struct {
	Store               *store.Store
	Runner              harness.Runner
	Catalog             *harness.Catalog
	Workspaces          *workspace.Manager
	BackgroundProcesses func(context.Context, string, harness.ProcessCall) (json.RawMessage, error)
	ProviderAccountKey  func(string) string

	mu               sync.Mutex
	active           map[string]*activeTurn
	strandedLeases   map[string]store.RuntimeLease
	shuttingDown     bool
	quickTitleJobs   map[string]*quickTitleJob
	quickTitleSlots  chan struct{}
	minimumFreeBytes uint64
	diskAvailable    func(string) (uint64, error)
	turnTokenKey     []byte
	releaseLease     func(store.RuntimeLease) error
}

type activeTurn struct {
	selection      model.HarnessSelection
	cancel         context.CancelFunc
	cardID         string
	turnID         string
	lease          store.RuntimeLease
	done           chan struct{}
	suspend        bool
	startedAt      time.Time
	lastProgress   time.Time
	hostWork       int
	workerObserved bool
	recoveryErr    error
	finishing      bool
	// vaultSecrets are values revealed to this turn; stored transcript chunks
	// redact them.
	vaultSecrets []string
}

type TurnUpdate struct {
	Chunk json.RawMessage
	Done  bool
	Err   error
}

// DefaultMinimumFreeBytes is the free disk space a turn requires unless the
// daemon is configured otherwise (DIETER_MIN_FREE_BYTES).
const DefaultMinimumFreeBytes = uint64(2 << 30)

// Options configures a Service. Zero values select the production defaults:
// a subprocess runner and the discovering release catalog under the store
// root, and DefaultMinimumFreeBytes.
type Options struct {
	Runner           harness.Runner
	Catalog          *harness.Catalog
	MinimumFreeBytes *uint64
}

func New(data *store.Store, runner harness.Runner) *Service {
	return NewWithOptions(data, Options{Runner: runner})
}

func NewWithOptions(data *store.Store, options Options) *Service {
	runner := options.Runner
	if runner == nil {
		runner = harness.NewSubprocessRunner(data.Root, harness.Environment{})
	}
	catalog := options.Catalog
	if catalog == nil {
		catalog = harness.DefaultCatalog(data.Root, false)
	}
	minimumFreeBytes := DefaultMinimumFreeBytes
	if options.MinimumFreeBytes != nil {
		minimumFreeBytes = *options.MinimumFreeBytes
	}
	return &Service{
		Store: data, Runner: runner, Catalog: catalog, Workspaces: workspace.New(data, nil), active: map[string]*activeTurn{}, strandedLeases: map[string]store.RuntimeLease{},
		minimumFreeBytes: minimumFreeBytes, diskAvailable: availableDiskBytes, turnTokenKey: newTurnTokenKey(), releaseLease: data.ReleaseRuntimeLease,
		quickTitleJobs: map[string]*quickTitleJob{}, quickTitleSlots: make(chan struct{}, quickTaskTitleConcurrency),
	}
}

func newRuntimeID(prefix string) string {
	buffer := make([]byte, 9)
	if _, err := rand.Read(buffer); err == nil {
		return prefix + hex.EncodeToString(buffer)
	}
	return fmt.Sprintf("%s%x%x", prefix, os.Getpid(), time.Now().UnixNano())
}
