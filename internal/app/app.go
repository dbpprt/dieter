package app

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/workspace"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Service struct {
	Store               *store.Store
	Runner              harness.Runner
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
	workerObserved bool
	recoveryErr    error
	finishing      bool
}

type TurnUpdate struct {
	Chunk json.RawMessage
	Done  bool
	Err   error
}

func New(data *store.Store, runner harness.Runner) *Service {
	if runner == nil {
		runner = harness.NewSubprocessRunner(data.Root)
	}
	minimumFreeBytes := uint64(2 << 30)
	if raw := strings.TrimSpace(os.Getenv("DIETER_MIN_FREE_BYTES")); raw != "" {
		if configured, err := strconv.ParseUint(raw, 10, 64); err == nil {
			minimumFreeBytes = configured
		}
	}
	return &Service{
		Store: data, Runner: runner, Workspaces: workspace.New(data, nil), active: map[string]*activeTurn{}, strandedLeases: map[string]store.RuntimeLease{},
		minimumFreeBytes: minimumFreeBytes, diskAvailable: availableDiskBytes, releaseLease: data.ReleaseRuntimeLease,
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
