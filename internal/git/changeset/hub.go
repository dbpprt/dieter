package changeset

import (
	"context"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/git"
)

const (
	// A watched directory is read this often while an agent works in it…
	activeWatchInterval = 750 * time.Millisecond
	// …and this often otherwise.
	idleWatchInterval = 3 * time.Second
	// Reads are never closer than this, nor than watchCostFactor times the
	// last read's duration, so a huge tree is read less often.
	minimumWatchGap = 250 * time.Millisecond
	watchCostFactor = 10
)

// Hub reads each watched directory once per interval, however many streams
// watch it, and tells them when its status changed. A Git operation, a file
// save or a transfer (StatusReader.Invalidate) wakes the reader at once.
type Hub struct {
	service *Service

	mu      sync.Mutex
	watched map[string]*watchedDirectory
}

type watchedDirectory struct {
	refs    int
	cancel  context.CancelFunc
	status  git.StatusSnapshot
	err     error
	read    bool
	changed chan struct{}
}

// Watch is one stream's view of a watched directory.
type Watch struct {
	hub       *Hub
	directory string
	released  bool
}

func NewHub(service *Service) *Hub {
	return &Hub{service: service, watched: map[string]*watchedDirectory{}}
}

// Watch starts or joins the reader of target's directory. agentActive picks
// the faster interval; the first watcher's function is used.
func (h *Hub) Watch(target Target, agentActive func() bool) *Watch {
	directory := target.Workspace.Path
	h.mu.Lock()
	defer h.mu.Unlock()
	entry := h.watched[directory]
	if entry == nil {
		ctx, cancel := context.WithCancel(context.Background())
		entry = &watchedDirectory{cancel: cancel, changed: make(chan struct{})}
		h.watched[directory] = entry
		go h.run(ctx, directory, entry, agentActive)
	}
	entry.refs++
	return &Watch{hub: h, directory: directory}
}

// Reading is a watched directory's latest status.
type Reading struct {
	Status git.StatusSnapshot
	// Err is the last read's failure; Status keeps the last good status.
	Err error
	// Read is false until the first read finished.
	Read bool
	// Changed is closed when the reading next changes.
	Changed <-chan struct{}
}

// Current returns the directory's latest reading.
func (w *Watch) Current() Reading {
	w.hub.mu.Lock()
	defer w.hub.mu.Unlock()
	entry := w.hub.watched[w.directory]
	if entry == nil {
		closed := make(chan struct{})
		close(closed)
		return Reading{Changed: closed}
	}
	return Reading{Status: entry.status, Err: entry.err, Read: entry.read, Changed: entry.changed}
}

// Release leaves the directory; the last watcher stops its reader.
func (w *Watch) Release() {
	w.hub.mu.Lock()
	defer w.hub.mu.Unlock()
	if w.released {
		return
	}
	w.released = true
	entry := w.hub.watched[w.directory]
	if entry == nil {
		return
	}
	entry.refs--
	if entry.refs <= 0 {
		entry.cancel()
		delete(w.hub.watched, w.directory)
	}
}

// Watching reports how many directories have a reader, for tests.
func (h *Hub) Watching() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.watched)
}

func (h *Hub) run(ctx context.Context, directory string, entry *watchedDirectory, agentActive func() bool) {
	status := h.service.Workspaces.Status
	for {
		invalidated := status.Invalidated(directory)
		started := time.Now()
		snapshot, err := status.Read(ctx, directory, false)
		if ctx.Err() != nil {
			return
		}
		took := time.Since(started)
		h.publish(entry, snapshot, err)
		interval := idleWatchInterval
		if agentActive != nil && agentActive() {
			interval = activeWatchInterval
		}
		gap := max(minimumWatchGap, watchCostFactor*took)
		interval = max(interval, gap)
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		case <-invalidated:
			timer.Stop()
			if wait := gap - time.Since(started); wait > 0 {
				select {
				case <-ctx.Done():
					return
				case <-time.After(wait):
				}
			}
		}
	}
}

func (h *Hub) publish(entry *watchedDirectory, snapshot git.StatusSnapshot, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	same := entry.read && (err == nil) == (entry.err == nil) && snapshot.Revision == entry.status.Revision &&
		snapshot.Branch == entry.status.Branch && snapshot.HeadSHA == entry.status.HeadSHA &&
		snapshot.Ahead == entry.status.Ahead && snapshot.Behind == entry.status.Behind
	if err != nil && entry.err != nil && err.Error() != entry.err.Error() {
		same = false
	}
	if err == nil {
		entry.status = snapshot
	}
	entry.err, entry.read = err, true
	if !same {
		close(entry.changed)
		entry.changed = make(chan struct{})
	}
}
