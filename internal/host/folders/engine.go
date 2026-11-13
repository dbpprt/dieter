// Package folders runs synced folders on a daemon: it scans each member
// directory, exchanges indexes with the other daemon members, pulls the
// content it needs, serves its index and content to peers and phones, and
// keeps the trash. It starts only inside `dieter serve`; constructing an
// Engine starts nothing.
package folders

import (
	"cmp"
	"context"
	"errors"
	"log/slog"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	core "github.com/dbpprt/dieter/internal/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
	sf "github.com/dbpprt/dieter/internal/store/folders"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

// Dialer connects to another daemon of the account. close releases it.
type Dialer func(ctx context.Context, daemonID string) (client dieterclient.Client, close func(), err error)

// Options configure an Engine. Zero durations select the defaults.
type Options struct {
	Store *store.Store
	Log   *slog.Logger
	// Name is how this daemon names itself in conflict copies and members.
	Name string
	// Dial reaches peer daemons; nil means this daemon has no peers.
	Dial Dialer
	// Trusted reports whether a daemon is in the pinned roster; nil trusts all.
	Trusted func(daemonID string) bool
	Now     func() time.Time
	// PeerPoll is how often an idle member asks its peers for changes.
	PeerPoll time.Duration
	// Walk is the stat-walk interval when the file system is not watched.
	Walk time.Duration
	// Supervise is how often running members are reconciled with storage.
	Supervise time.Duration
	// DeleteSettle is how long a path must stay missing before its deletion
	// is recorded, so a deletion in progress (rm -rf) is judged as one batch.
	DeleteSettle time.Duration
}

// Defaults.
const (
	defaultPeerPoll  = 15 * time.Second
	idlePeerPoll     = 60 * time.Second
	defaultWalk      = 60 * time.Second
	defaultSupervise = 5 * time.Second
	defaultSettle    = 3 * time.Second
	recordInterval   = time.Minute
	tombstoneAge     = 90 * 24 * time.Hour
	maxProblems      = 100
	trashQuota       = int64(20) << 30
)

// Problem is one error or unsyncable path of a member.
type Problem struct {
	Path    string
	Message string
	At      time.Time
}

// Pending are deletions the guard holds.
type Pending struct {
	Source string // "local" or "remote"
	Peer   string
	Paths  []string
	// Entries are the remote tombstones (source remote).
	Entries []core.Entry
}

// PeerStatus is the last exchange with one peer daemon.
type PeerStatus struct {
	Name       string
	LastSyncAt time.Time
	Error      string
}

// Status is a member's live state.
type Status struct {
	State        string
	Detail       string
	LastScanAt   time.Time
	LastSyncAt   time.Time
	NeedFiles    int64
	NeedBytes    int64
	Errors       []Problem
	Unsyncable   []Problem
	Pending      *Pending
	LocalChanges []string
	OutOfSync    []string
	Peers        map[string]PeerStatus
}

// Head is a member's position for change streams.
type Head struct {
	FolderID   string
	IndexID    string
	Sequence   uint64
	State      string
	Detail     string
	NeedFiles  int64
	NeedBytes  int64
	Conflicts  int
	LastSyncAt time.Time
}

type run struct {
	folderID string
	wake     chan bool // true: scan too
	cancel   context.CancelFunc
	done     chan struct{}

	// Guarded by Engine.mu.
	status     Status
	cycleDone  chan struct{}
	recorded   schema.FolderMemberRecord
	recordedAt time.Time
	resolve    *resolution

	// Only the member's loop touches these.
	missingSince map[string]time.Time
	restoring    map[string]bool
}

// resolution is a person's answer to held deletions, applied by the loop.
type resolution struct{ apply bool }

// Engine runs this daemon's synced folders.
type Engine struct {
	opts Options
	log  *slog.Logger

	mu       sync.Mutex
	runs     map[string]*run
	kick     chan struct{}
	revision atomic.Uint64
	started  atomic.Bool

	peerMu sync.Mutex
	peers  map[string]*peerConn

	blockMu sync.Mutex
	blocks  map[string][]string

	acks      ackState
	preserved sync.Map // upload ID → preserved version
	conflicts map[string]conflictMemo
}

// New returns an engine; Run starts it.
func New(options Options) *Engine {
	if options.Log == nil {
		options.Log = slog.Default()
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.PeerPoll <= 0 {
		options.PeerPoll = defaultPeerPoll
	}
	if options.Walk <= 0 {
		options.Walk = defaultWalk
	}
	if options.Supervise <= 0 {
		options.Supervise = defaultSupervise
	}
	if options.DeleteSettle <= 0 {
		options.DeleteSettle = defaultSettle
	}
	if options.Name == "" {
		options.Name, _ = os.Hostname()
	}
	return &Engine{opts: options, log: options.Log.With("component", "folders"), runs: map[string]*run{}, kick: make(chan struct{}, 1), peers: map[string]*peerConn{}, blocks: map[string][]string{}, conflicts: map[string]conflictMemo{}}
}

func (e *Engine) store() *store.Store { return e.opts.Store }

// Name is how this daemon names itself.
func (e *Engine) Name() string       { return e.opts.Name }
func (e *Engine) folders() *sf.Store { return e.opts.Store.Folders }
func (e *Engine) now() time.Time     { return e.opts.Now() }

// DaemonID is this daemon's member ID: its replica writer identity.
func (e *Engine) DaemonID() (string, error) { return e.store().KV.ChannelDaemon() }

func (e *Engine) actor() (string, string, error) {
	id, err := e.DaemonID()
	if err != nil {
		return "", "", err
	}
	return id, core.ActorOf(id), nil
}

// Revision changes whenever a head changes.
func (e *Engine) Revision() uint64 { return e.revision.Load() }

func (e *Engine) changed() {
	e.revision.Add(1)
	e.store().NotifyChanges()
}

// Run supervises members until ctx ends.
func (e *Engine) Run(ctx context.Context) {
	e.started.Store(true)
	ticker := time.NewTicker(e.opts.Supervise)
	defer ticker.Stop()
	for {
		e.supervise(ctx)
		select {
		case <-ctx.Done():
			e.mu.Lock()
			runs := e.runs
			e.runs = map[string]*run{}
			e.mu.Unlock()
			for _, r := range runs {
				r.cancel()
				<-r.done
			}
			e.closePeers()
			return
		case <-ticker.C:
		case <-e.kick:
		}
	}
}

// Kick makes the supervisor reconcile members now.
func (e *Engine) Kick() {
	select {
	case e.kick <- struct{}{}:
	default:
	}
}

func (e *Engine) supervise(ctx context.Context) {
	members, err := e.folders().Members()
	if err != nil {
		e.log.Warn("folder members unavailable", "error", err)
		return
	}
	want := map[string]bool{}
	for _, member := range members {
		want[member.FolderID] = true
	}
	e.mu.Lock()
	var stopped []*run
	for id, r := range e.runs {
		if !want[id] {
			r.cancel()
			stopped = append(stopped, r)
			delete(e.runs, id)
		}
	}
	for id := range want {
		if e.runs[id] != nil {
			continue
		}
		runCtx, cancel := context.WithCancel(ctx)
		r := &run{folderID: id, wake: make(chan bool, 1), cancel: cancel, done: make(chan struct{}), cycleDone: make(chan struct{}), status: Status{State: "idle", Peers: map[string]PeerStatus{}}}
		e.runs[id] = r
		go e.loop(runCtx, r)
	}
	e.mu.Unlock()
	for _, r := range stopped {
		<-r.done
	}
	if len(stopped) > 0 {
		e.changed()
	}
}

// Wake asks a member to run a cycle; scan includes a walk of its directory.
func (e *Engine) Wake(folderID string, scan bool) {
	e.mu.Lock()
	r := e.runs[folderID]
	e.mu.Unlock()
	if r == nil {
		return
	}
	select {
	case r.wake <- scan:
	default:
		if scan {
			// Replace a pending pull-only wake with a scan.
			select {
			case <-r.wake:
			default:
			}
			select {
			case r.wake <- true:
			default:
			}
		}
	}
}

// WaitCycle wakes a member and waits for the cycle that follows, bounded by ctx.
func (e *Engine) WaitCycle(ctx context.Context, folderID string, scan bool) error {
	if !e.started.Load() {
		return nil
	}
	var r *run
	var done chan struct{}
	for {
		e.mu.Lock()
		r = e.runs[folderID]
		if r != nil {
			done = r.cycleDone
		}
		e.mu.Unlock()
		if r != nil {
			break
		}
		// A member attached a moment ago starts with the next supervision.
		if _, err := e.folders().Member(folderID); err != nil {
			return err
		}
		e.Kick()
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(20 * time.Millisecond):
		}
	}
	e.Wake(folderID, scan)
	select {
	case <-done:
		// The cycle that was running may have started before the wake.
		e.mu.Lock()
		done = r.cycleDone
		e.mu.Unlock()
		select {
		case <-done:
		case <-ctx.Done():
		}
		return nil
	case <-ctx.Done():
		return nil
	}
}

func (e *Engine) loop(ctx context.Context, r *run) {
	defer close(r.done)
	events, watching := e.watch(ctx, r.folderID)
	walkEvery := e.opts.Walk
	walk := time.NewTimer(0)
	defer walk.Stop()
	poll := time.NewTimer(e.opts.PeerPoll)
	defer poll.Stop()
	lastActive := e.now()
	for {
		scan := false
		select {
		case <-ctx.Done():
			return
		case s := <-r.wake:
			scan = s
		case <-events:
			scan = true
		case <-walk.C:
			scan = true
		case <-poll.C:
		}
		changed := e.cycle(ctx, r, scan)
		if changed {
			lastActive = e.now()
		}
		if scan {
			member, err := e.folders().Member(r.folderID)
			interval := walkEvery
			if err == nil && watching && member.RescanSeconds > 0 {
				interval = time.Duration(member.RescanSeconds) * time.Second
			}
			if len(r.missingSince) > 0 {
				// Deletions are settling: look again once they have.
				interval = min(interval, e.opts.DeleteSettle+100*time.Millisecond)
			}
			walk.Reset(interval)
		}
		next := e.opts.PeerPoll
		if e.now().Sub(lastActive) > 5*time.Minute {
			next = max(next, idlePeerPoll)
		}
		poll.Reset(next)
		e.mu.Lock()
		close(r.cycleDone)
		r.cycleDone = make(chan struct{})
		e.mu.Unlock()
	}
}

// setState changes a member's state and detail.
func (e *Engine) setState(r *run, state, detail string) {
	e.mu.Lock()
	changed := r.status.State != state || r.status.Detail != detail
	r.status.State, r.status.Detail = state, detail
	e.mu.Unlock()
	if changed {
		e.changed()
	}
}

func (e *Engine) problem(r *run, path string, err error) {
	if err == nil {
		return
	}
	e.mu.Lock()
	r.status.Errors = append(r.status.Errors, Problem{Path: path, Message: err.Error(), At: e.now()})
	if len(r.status.Errors) > maxProblems {
		r.status.Errors = r.status.Errors[len(r.status.Errors)-maxProblems:]
	}
	e.mu.Unlock()
}

func (e *Engine) runOf(folderID string) *run {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.runs[folderID]
}

// StatusOf is a copy of a member's live status.
func (e *Engine) StatusOf(folderID string) Status {
	e.mu.Lock()
	defer e.mu.Unlock()
	r := e.runs[folderID]
	if r == nil {
		return Status{State: "idle"}
	}
	status := r.status
	status.Errors = slices.Clone(status.Errors)
	status.Unsyncable = slices.Clone(status.Unsyncable)
	status.LocalChanges = slices.Clone(status.LocalChanges)
	status.OutOfSync = slices.Clone(status.OutOfSync)
	status.Peers = make(map[string]PeerStatus, len(r.status.Peers))
	for id, peer := range r.status.Peers {
		status.Peers[id] = peer
	}
	if r.status.Pending != nil {
		pending := *r.status.Pending
		status.Pending = &pending
	}
	return status
}

// Heads are the positions of every member of this daemon.
func (e *Engine) Heads() []Head {
	members, err := e.folders().Members()
	if err != nil {
		return nil
	}
	heads := make([]Head, 0, len(members))
	for _, member := range members {
		head := Head{FolderID: member.FolderID, IndexID: member.IndexID, State: "idle"}
		if index, err := e.folders().Index(member.FolderID); err == nil {
			head.Sequence = index.Head()
			head.Conflicts = e.conflictCount(member.FolderID, index)
		}
		status := e.StatusOf(member.FolderID)
		head.State, head.Detail, head.NeedFiles, head.NeedBytes, head.LastSyncAt = status.State, status.Detail, status.NeedFiles, status.NeedBytes, status.LastSyncAt
		if member.Paused {
			head.State = "paused"
		}
		heads = append(heads, head)
	}
	return heads
}

// conflictCount counts conflict copies once per index head.
func (e *Engine) conflictCount(folderID string, index *sf.Index) int {
	head := index.Head()
	e.mu.Lock()
	if memo, ok := e.conflicts[folderID]; ok && memo.index == index.ID() && memo.head == head {
		e.mu.Unlock()
		return memo.count
	}
	e.mu.Unlock()
	count := len(conflictCopies(index))
	e.mu.Lock()
	e.conflicts[folderID] = conflictMemo{index: index.ID(), head: head, count: count}
	e.mu.Unlock()
	return count
}

type conflictMemo struct {
	index string
	head  uint64
	count int
}

func conflictCopies(index *sf.Index) []string {
	var paths []string
	for path, entry := range index.Snapshot() {
		if entry.Kind == core.KindFile && strings.Contains(path, " (conflict, ") {
			paths = append(paths, path)
		}
	}
	slices.Sort(paths)
	return paths
}

// writeRecord publishes this daemon's membership of a folder, at most once
// a minute unless force.
func (e *Engine) writeRecord(folderID string, force bool) {
	member, err := e.folders().Member(folderID)
	if err != nil {
		return
	}
	daemonID, err := e.DaemonID()
	if err != nil {
		return
	}
	record := schema.FolderMemberRecord{FolderID: folderID, DaemonID: daemonID, Name: e.opts.Name, Mode: string(member.Mode), Paused: member.Paused, IndexID: member.IndexID, State: "idle"}
	if index, err := e.folders().Index(folderID); err == nil {
		record.Sequence = index.Head()
		record.Conflicts = e.conflictCount(folderID, index)
	}
	status := e.StatusOf(folderID)
	record.State, record.StateDetail, record.NeedFiles, record.NeedBytes = status.State, truncate(status.Detail, 500), status.NeedFiles, status.NeedBytes
	if member.Paused {
		record.State = "paused"
	}
	if !status.LastSyncAt.IsZero() {
		record.LastSyncAt = status.LastSyncAt.UTC().Format(time.RFC3339Nano)
	}
	clients, _ := e.folders().Clients(folderID)
	acks, _ := e.folders().Acks(folderID)
	for _, client := range clients {
		item := schema.FolderClientRecord{DeviceID: client.DeviceID, Name: truncate(client.Name, 500), Mode: string(client.Mode), LastSeenAt: client.LastSeenAt}
		if ack, ok := acks[client.DeviceID]; ok && ack.IndexID == member.IndexID {
			item.Acknowledged = ack.Sequence
		}
		record.Clients = append(record.Clients, item)
	}
	e.mu.Lock()
	r := e.runs[folderID]
	if r != nil && !force && (e.now().Sub(r.recordedAt) < recordInterval || sameRecord(r.recorded, record)) {
		e.mu.Unlock()
		return
	}
	e.mu.Unlock()
	if err := e.store().KV.PutFolderMember(record); err != nil {
		e.log.Warn("folder membership not published", "folder", folderID, "error", err)
		return
	}
	e.mu.Lock()
	if r != nil {
		r.recorded, r.recordedAt = record, e.now()
	}
	e.mu.Unlock()
}

func sameRecord(a, b schema.FolderMemberRecord) bool {
	return a.Mode == b.Mode && a.Paused == b.Paused && a.State == b.State && a.StateDetail == b.StateDetail && a.IndexID == b.IndexID &&
		a.Sequence == b.Sequence && a.NeedFiles == b.NeedFiles && a.Conflicts == b.Conflicts && slices.EqualFunc(a.Clients, b.Clients, func(x, y schema.FolderClientRecord) bool { return x == y })
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8Start(s[n]) {
		n--
	}
	return s[:n]
}

func utf8Start(b byte) bool { return b&0xC0 != 0x80 }

// peerMembers are the other daemon members of a folder that are trusted.
func (e *Engine) peerMembers(folderID string) ([]schema.FolderMemberRecord, error) {
	self, err := e.DaemonID()
	if err != nil {
		return nil, err
	}
	var peers []schema.FolderMemberRecord
	err = e.store().KV.FolderMembers(folderID+".", func(record schema.FolderMemberRecord) error {
		if record.FolderID == folderID && record.DaemonID != self && (e.opts.Trusted == nil || e.opts.Trusted(record.DaemonID)) {
			peers = append(peers, record)
		}
		return nil
	})
	slices.SortFunc(peers, func(a, b schema.FolderMemberRecord) int { return cmp.Compare(a.DaemonID, b.DaemonID) })
	return peers, err
}

// cycle runs one round for a member: scan (optionally), then pull from each
// peer. It reports whether anything changed.
func (e *Engine) cycle(ctx context.Context, r *run, scan bool) bool {
	member, err := e.folders().Member(r.folderID)
	if err != nil {
		return false
	}
	definition, err := e.Definition(r.folderID)
	if err != nil {
		e.setState(r, "error", "folder definition unavailable: "+err.Error())
		return false
	}
	if definition.Archived {
		e.setState(r, "paused", "the folder is archived")
		e.writeRecord(r.folderID, false)
		return false
	}
	if member.Paused {
		e.setState(r, "paused", "")
		e.writeRecord(r.folderID, false)
		return false
	}
	dev, ino, rootErr := rootIdentity(member.Path)
	if rootErr != nil || dev != member.RootDev || ino != member.RootIno {
		detail := "the folder's location is unavailable: " + member.Path
		if rootErr == nil {
			detail = "the folder's location was replaced or unmounted: " + member.Path
		}
		e.setState(r, "attention", detail)
		e.writeRecord(r.folderID, false)
		return false
	}
	changed := false
	e.mu.Lock()
	resolve := r.resolve
	r.resolve = nil
	e.mu.Unlock()
	if resolve != nil {
		if e.resolveHeld(ctx, r, member, definition, resolve.apply) {
			changed = true
		}
	}
	e.restoreMissing(ctx, r, member, definition)
	if member.Join != "" {
		if err := e.join(ctx, r, member, definition); err != nil {
			e.problem(r, "", err)
			e.setState(r, "error", "joining the folder: "+err.Error())
			return false
		}
		member, _ = e.folders().Member(r.folderID)
		scan = true
	}
	if scan {
		e.setState(r, "scanning", "")
		did, err := e.scan(ctx, r, member, definition)
		if err != nil {
			e.problem(r, "", err)
			e.setState(r, "error", err.Error())
			e.writeRecord(r.folderID, false)
			return changed
		}
		changed = changed || did
	}
	if e.held(r) {
		e.setState(r, "attention", "deletions wait for confirmation")
		e.writeRecord(r.folderID, true)
		return changed
	}
	if e.pullAll(ctx, r, member, definition) {
		changed = true
	}
	e.housekeeping(ctx, r, member, definition)
	switch {
	case e.held(r):
		e.setState(r, "attention", "deletions wait for confirmation")
	default:
		status := e.StatusOf(r.folderID)
		state, detail := "idle", ""
		for _, peer := range status.Peers {
			if peer.Error != "" {
				state, detail = "error", peer.Name+": "+peer.Error
			}
		}
		e.setState(r, state, detail)
	}
	e.writeRecord(r.folderID, changed)
	return changed
}

func (e *Engine) held(r *run) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return r.status.Pending != nil
}

// housekeeping sweeps the trash and forgets tombstones every member has.
func (e *Engine) housekeeping(ctx context.Context, r *run, member sf.Member, definition Definition) {
	retention := time.Duration(definition.TrashDays) * 24 * time.Hour
	_ = e.folders().WithLock(ctx, func() error {
		if err := e.folders().SweepTrashLocked(r.folderID, retention, trashQuota, e.now()); err != nil {
			e.problem(r, "", err)
		}
		upTo, ok := e.acknowledgedByAll(r.folderID, member)
		if !ok {
			upTo = 0
		}
		if removed, err := e.folders().ForgetLocked(r.folderID, upTo, e.now().Add(-tombstoneAge)); err != nil {
			e.problem(r, "", err)
		} else if removed > 0 {
			e.log.Debug("forgot folder tombstones", "folder", r.folderID, "count", removed)
		}
		return nil
	})
}

// acknowledgedByAll is the lowest sequence of this daemon's index that every
// known peer and client fetched.
func (e *Engine) acknowledgedByAll(folderID string, member sf.Member) (uint64, bool) {
	acks, err := e.folders().Acks(folderID)
	if err != nil {
		return 0, false
	}
	peers, err := e.peerMembers(folderID)
	if err != nil {
		return 0, false
	}
	clients, _ := e.folders().Clients(folderID)
	ids := make([]string, 0, len(peers)+len(clients))
	for _, peer := range peers {
		ids = append(ids, peer.DaemonID)
	}
	for _, client := range clients {
		ids = append(ids, client.DeviceID)
	}
	if len(ids) == 0 {
		return 0, false
	}
	low := uint64(0)
	for i, id := range ids {
		ack, ok := acks[id]
		if !ok || ack.IndexID != member.IndexID {
			return 0, false
		}
		if i == 0 || ack.Sequence < low {
			low = ack.Sequence
		}
	}
	return low, true
}

var errStopped = errors.New("stopped")

func isConflict(err error) bool {
	kind, ok := fault.KindOf(err)
	return ok && kind == fault.Conflict
}
