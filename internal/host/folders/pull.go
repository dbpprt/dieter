package folders

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"sync"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	core "github.com/dbpprt/dieter/internal/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	sf "github.com/dbpprt/dieter/internal/store/folders"
)

// maxPagesPerCycle bounds one peer's exchange per cycle; the next continues.
const maxPagesPerCycle = 64

// pullAll exchanges with every peer daemon of a folder.
func (e *Engine) pullAll(ctx context.Context, r *run, member sf.Member, definition Definition) bool {
	if e.opts.Dial == nil {
		return false
	}
	peers, err := e.peerMembers(member.FolderID)
	if err != nil {
		e.problem(r, "", err)
		return false
	}
	changed := false
	synced := false
	for _, peer := range peers {
		if ctx.Err() != nil {
			return changed
		}
		did, err := e.pull(ctx, r, member, definition, peer)
		changed = changed || did
		e.mu.Lock()
		status := r.status.Peers[peer.DaemonID]
		status.Name = peer.Name
		if err != nil {
			status.Error = err.Error()
		} else {
			status.Error, status.LastSyncAt = "", e.now()
			synced = true
		}
		r.status.Peers[peer.DaemonID] = status
		e.mu.Unlock()
		if err != nil && !errors.Is(err, errStopped) {
			e.log.Debug("folder exchange pending", "folder", member.FolderID, "peer", peer.DaemonID, "error", err)
		}
		if e.held(r) {
			break
		}
	}
	e.mu.Lock()
	for id := range r.status.Peers {
		if !slices.ContainsFunc(peers, func(p schema.FolderMemberRecord) bool { return p.DaemonID == id }) {
			delete(r.status.Peers, id)
		}
	}
	if synced {
		r.status.LastSyncAt = e.now()
	}
	e.mu.Unlock()
	return changed
}

// pull fetches a peer's index from the checkpoint and applies it page by
// page. A page's checkpoint advances only when every step of it succeeded,
// so a failed step is retried on the next cycle; already-applied entries
// then compare equal.
func (e *Engine) pull(ctx context.Context, r *run, member sf.Member, definition Definition, peer schema.FolderMemberRecord) (bool, error) {
	changed := false
	err := e.withPeer(ctx, peer.DaemonID, func(client peerClient) error {
		checkpoint, err := e.folders().Checkpoint(member.FolderID, peer.DaemonID)
		if err != nil {
			return err
		}
		for range maxPagesPerCycle {
			page, err := client.index(ctx, member.FolderID, checkpoint.IndexID, checkpoint.Sequence, client.self, checkpoint.Sequence)
			if err != nil {
				return err
			}
			if page.Reset || checkpoint.IndexID != page.IndexID {
				checkpoint = sf.Checkpoint{IndexID: page.IndexID}
			}
			did, held, err := e.applyPage(ctx, r, member, definition, client, peer, page.Entries)
			changed = changed || did
			if err != nil || held {
				return err
			}
			checkpoint.Sequence, checkpoint.LastSyncAt = page.Sequence, e.now().UTC().Format(time.RFC3339Nano)
			if err := e.folders().WithLock(ctx, func() error {
				return e.folders().SaveCheckpointLocked(member.FolderID, peer.DaemonID, checkpoint)
			}); err != nil {
				return err
			}
			if !page.More {
				return nil
			}
		}
		return nil
	})
	return changed, err
}

type step struct {
	remote   core.Entry
	decision core.Decision
	current  *sf.Local
}

// applyPage reconciles a page of a peer's entries with the local index and
// performs the decisions: merges first, then directories (shallow first),
// deletions (deep first) and files (small first, several at a time).
func (e *Engine) applyPage(ctx context.Context, r *run, member sf.Member, definition Definition, client peerClient, peer schema.FolderMemberRecord, entries []core.Entry) (changed, held bool, err error) {
	index, err := e.folders().Index(member.FolderID)
	if err != nil {
		return false, false, err
	}
	var steps []step
	var outOfSync []string
	live := 0
	for _, entry := range index.Snapshot() {
		if entry.Kind != core.KindDeleted {
			live++
		}
	}
	for _, remote := range entries {
		if err := remote.Validate(); err != nil {
			e.problem(r, remote.Path, fmt.Errorf("invalid entry from %s: %w", peer.Name, err))
			continue
		}
		if !definition.Included(remote.Path) {
			continue
		}
		var current *sf.Local
		if local, ok := index.Get(remote.Path); ok {
			current = &local
		}
		var localEntry *core.Entry
		if current != nil {
			localEntry = &current.Entry
		}
		decision := core.Decide(localEntry, remote, member.Mode)
		switch decision.Action {
		case core.ActionNone:
			continue
		case core.ActionOutOfSync:
			outOfSync = append(outOfSync, remote.Path)
			continue
		}
		steps = append(steps, step{remote: remote, decision: decision, current: current})
	}
	e.mu.Lock()
	if member.Mode == core.ModeSendOnly {
		r.status.OutOfSync = mergePaths(r.status.OutOfSync, outOfSync)
	}
	e.mu.Unlock()
	if len(steps) == 0 {
		return false, false, nil
	}
	var deletions []string
	var tombstones []core.Entry
	for _, s := range steps {
		if s.decision.Action == core.ActionApply && s.decision.Result.Kind == core.KindDeleted && s.current != nil && s.current.Kind != core.KindDeleted {
			deletions = append(deletions, s.remote.Path)
			tombstones = append(tombstones, s.decision.Result)
		}
	}
	if len(deletions) > 0 && core.GuardTrips(definition.DeleteGuard, len(deletions), live) {
		slices.Sort(deletions)
		e.mu.Lock()
		r.status.Pending = &Pending{Source: "remote", Peer: peer.DaemonID, Paths: deletions, Entries: tombstones}
		e.mu.Unlock()
		e.changed()
		return false, true, nil
	}
	return e.perform(ctx, r, member, definition, &client, steps)
}

func mergePaths(a, b []string) []string {
	out := append(slices.Clone(a), b...)
	slices.Sort(out)
	out = slices.Compact(out)
	if len(out) > maxProblems {
		out = out[:maxProblems]
	}
	return out
}

// perform executes steps and commits their results. With client nil only
// local operations are possible (merges, directories, deletions).
func (e *Engine) perform(ctx context.Context, r *run, member sf.Member, definition Definition, client *peerClient, steps []step) (changed, held bool, err error) {
	byPath := make(map[string]step, len(steps))
	results := make([]core.Entry, 0, len(steps))
	var merges []sf.Local
	for _, s := range steps {
		if s.decision.Action == core.ActionMerge {
			local := sf.Local{Entry: s.decision.Result}
			if s.current != nil {
				local.Revision = s.current.Revision
			}
			merges = append(merges, local)
			continue
		}
		byPath[s.remote.Path] = s
		results = append(results, s.decision.Result)
	}
	var failures []error
	var outcome sync.Mutex
	fail := func(err error) {
		outcome.Lock()
		failures = append(failures, err)
		outcome.Unlock()
	}
	commit := func(locals []sf.Local) {
		if len(locals) == 0 {
			return
		}
		err := e.folders().WithLock(ctx, func() error {
			index, err := e.folders().Index(member.FolderID)
			if err != nil {
				return err
			}
			accepted := locals[:0]
			for _, local := range locals {
				s, ok := byPath[local.Path]
				current, exists := index.Get(local.Path)
				// A step's result applies only over the entry it was decided on.
				if ok && (s.current == nil && exists && current.Kind != core.KindDeleted || s.current != nil && exists && current.Sequence != s.current.Sequence) {
					continue
				}
				accepted = append(accepted, local)
			}
			_, err = e.folders().CommitLocked(member.FolderID, accepted)
			return err
		})
		outcome.Lock()
		defer outcome.Unlock()
		if err != nil {
			failures = append(failures, err)
			return
		}
		changed = true
	}
	commit(merges)
	ordered := core.Ordered(results)
	var fileSteps []step
	var needBytes int64
	for _, result := range ordered {
		s := byPath[result.Path]
		if result.Kind == core.KindFile {
			fileSteps = append(fileSteps, s)
			needBytes += result.Size
			continue
		}
		local, err := e.applyLocal(ctx, member, definition, s)
		if err != nil {
			e.problem(r, s.remote.Path, err)
			fail(err)
			continue
		}
		commit([]sf.Local{local})
	}
	if len(fileSteps) > 0 {
		if client == nil {
			return changed, false, fault.New(fault.Unavailable, "no peer to download from")
		}
		e.mu.Lock()
		r.status.NeedFiles, r.status.NeedBytes = int64(len(fileSteps)), needBytes
		e.mu.Unlock()
		e.setState(r, "syncing", fmt.Sprintf("%d files", len(fileSteps)))
		concurrency := min(max(member.Concurrency, 1), 8)
		work := make(chan step)
		var mu sync.Mutex
		var batch []sf.Local
		var wg sync.WaitGroup
		limiter := newLimiter(member.Bandwidth)
		for range concurrency {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for s := range work {
					local, copied, err := e.applyFile(ctx, member, definition, *client, s, limiter)
					mu.Lock()
					if err != nil {
						e.problem(r, s.remote.Path, err)
						fail(err)
					} else {
						batch = append(batch, copied...)
						batch = append(batch, local)
					}
					e.mu.Lock()
					r.status.NeedFiles--
					r.status.NeedBytes -= s.remote.Size
					e.mu.Unlock()
					flush := len(batch) >= 64
					var toCommit []sf.Local
					if flush {
						toCommit, batch = batch, nil
					}
					mu.Unlock()
					if flush {
						commit(toCommit)
					}
				}
			}()
		}
		for _, s := range fileSteps {
			select {
			case work <- s:
			case <-ctx.Done():
			}
			if ctx.Err() != nil {
				break
			}
		}
		close(work)
		wg.Wait()
		commit(batch)
		e.mu.Lock()
		r.status.NeedFiles, r.status.NeedBytes = 0, 0
		e.mu.Unlock()
	}
	if ctx.Err() != nil {
		return changed, false, errStopped
	}
	outcome.Lock()
	defer outcome.Unlock()
	if len(failures) > 0 {
		return changed, false, fmt.Errorf("%d changes failed; the first: %w", len(failures), failures[0])
	}
	return changed, false, nil
}

func newItemID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return "tr_" + hex.EncodeToString(b)
}

// trashFile moves a file out of a member into the trash, or removes it when
// the folder has no trash.
func (e *Engine) trashFile(ctx context.Context, member sf.Member, definition Definition, p, revision, reason, by string, entry *core.Entry) error {
	if definition.TrashDays <= 0 {
		err := files.Remove(ctx, member.Path, p, revision)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	id := newItemID()
	if _, err := files.MoveOut(ctx, member.Path, p, revision, e.folders().TrashDir(member.FolderID), id); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	item := sf.TrashItem{ID: id, Path: p, DeletedAt: e.now().UTC().Format(time.RFC3339Nano), DeletedBy: by, Reason: reason}
	if entry != nil {
		item.Size, item.SHA256, item.Executable, item.Modified, item.Version = entry.Size, entry.SHA256, entry.Executable, entry.Modified, entry.Version
	}
	return e.folders().WithLock(ctx, func() error { return e.folders().AddTrashLocked(member.FolderID, item) })
}

// applyLocal performs a directory or deletion step.
func (e *Engine) applyLocal(ctx context.Context, member sf.Member, definition Definition, s step) (sf.Local, error) {
	result := s.decision.Result
	p := result.Path
	current := s.current
	switch result.Kind {
	case core.KindDirectory:
		if current != nil && current.Kind == core.KindFile {
			if s.decision.ConflictCopy != "" {
				if _, err := e.conflictCopy(ctx, member, *current, s.decision.ConflictCopy); err != nil {
					return sf.Local{}, err
				}
			} else if err := e.trashFile(ctx, member, definition, p, current.Revision, "replaced", result.AuthorName, &current.Entry); err != nil {
				return sf.Local{}, err
			}
		}
		if err := files.Mkdir(member.Path, p); err != nil {
			return sf.Local{}, err
		}
		return sf.Local{Entry: result}, nil
	case core.KindDeleted:
		if current != nil {
			switch current.Kind {
			case core.KindFile:
				if err := e.trashFile(ctx, member, definition, p, current.Revision, "deleted", result.AuthorName, &current.Entry); err != nil {
					return sf.Local{}, err
				}
			case core.KindDirectory:
				// A directory that still holds unsynced files stays; it
				// returns on the next scan rather than losing them.
				if err := files.RemoveEmptyDir(member.Path, p); err != nil && !isConflict(err) {
					return sf.Local{}, err
				}
			}
		}
		return sf.Local{Entry: result}, nil
	}
	return sf.Local{}, fault.Invalidf("not a local step")
}

// conflictCopy keeps a losing local file under its conflict name and returns
// the entry for it.
func (e *Engine) conflictCopy(ctx context.Context, member sf.Member, current sf.Local, name string) (sf.Local, error) {
	daemonID, actor, err := e.actor()
	if err != nil {
		return sf.Local{}, err
	}
	if err := files.Rename(ctx, member.Path, current.Path, current.Revision, name); err != nil {
		return sf.Local{}, err
	}
	stat, err := files.Stat(ctx, member.Path, name, false)
	if err != nil {
		return sf.Local{}, err
	}
	var version core.Version
	if index, err := e.folders().Index(member.FolderID); err == nil {
		if existing, ok := index.Get(name); ok {
			version = existing.Version
		}
	}
	entry := core.Entry{Path: name, Kind: core.KindFile, Size: current.Size, Modified: current.Modified, Executable: current.Executable, SHA256: current.SHA256,
		Version: version.Bump(actor), AuthorID: daemonID, AuthorName: core.SanitizeName(e.opts.Name)}
	local := sf.Local{Entry: entry, Revision: stat.Revision}
	_, err = e.folders().Commit(ctx, member.FolderID, []sf.Local{local})
	return local, err
}

// applyFile makes a member's file match a remote file entry.
func (e *Engine) applyFile(ctx context.Context, member sf.Member, definition Definition, client peerClient, s step, limiter *limiter) (sf.Local, []sf.Local, error) {
	remote := s.decision.Result
	p := remote.Path
	current := s.current
	var copied []sf.Local
	if caseInsensitive {
		if other := e.caseCollision(member.FolderID, p); other != "" {
			return sf.Local{}, nil, fmt.Errorf("can't sync here: %q differs from %q only by case", p, other)
		}
	}
	if current != nil && current.Kind == core.KindFile && s.decision.ConflictCopy != "" {
		local, err := e.conflictCopy(ctx, member, *current, s.decision.ConflictCopy)
		if err != nil {
			return sf.Local{}, nil, err
		}
		_ = local
		current = nil
	}
	expected := files.Missing
	if current != nil {
		switch current.Kind {
		case core.KindFile:
			expected = current.Revision
			if expected == "" {
				expected = files.Missing
			}
		case core.KindDirectory:
			if err := files.RemoveEmptyDir(member.Path, p); err != nil {
				return sf.Local{}, nil, err
			}
		}
	}
	if current != nil && current.Kind == core.KindFile && current.SHA256 == remote.SHA256 && current.Size == remote.Size && current.Executable == remote.Executable && current.Revision != "" {
		return sf.Local{Entry: remote, Revision: current.Revision}, copied, nil
	}
	mode := uint32(0o644)
	if remote.Executable {
		mode = 0o755
	}
	source := files.Entry{Size: remote.Size, SHA256: remote.SHA256, Mode: mode, Modified: remote.Modified}
	preserved := ""
	if expected != files.Missing && definition.TrashDays > 0 {
		preserved = newItemID()
		revision, err := files.Preserve(ctx, member.Path, p, expected, e.folders().TrashDir(member.FolderID), preserved)
		switch {
		case err == nil:
			expected = revision
		case isConflict(err):
			return sf.Local{}, nil, err
		default:
			preserved = ""
		}
	}
	reader, closeReader := e.contentReader(ctx, member, client, remote, current, limiter)
	stat, err := files.PublishWith(ctx, member.Path, p, expected, source, reader, files.PublishOptions{Quarantine: member.Quarantine})
	closeReader()
	if err != nil {
		if preserved != "" {
			_ = os.Remove(e.folders().TrashDir(member.FolderID) + "/" + preserved)
		}
		return sf.Local{}, nil, err
	}
	if preserved != "" && current != nil {
		item := sf.TrashItem{ID: preserved, Path: p, Size: current.Size, SHA256: current.SHA256, Executable: current.Executable, Modified: current.Modified, Version: current.Version,
			DeletedAt: e.now().UTC().Format(time.RFC3339Nano), DeletedBy: remote.AuthorName, Reason: "replaced"}
		if err := e.folders().WithLock(ctx, func() error { return e.folders().AddTrashLocked(member.FolderID, item) }); err != nil {
			return sf.Local{}, nil, err
		}
	}
	return sf.Local{Entry: remote, Revision: stat.Revision}, copied, nil
}

// caseCollision is a live entry whose path differs from p only by case.
func (e *Engine) caseCollision(folderID, p string) string {
	index, err := e.folders().Index(folderID)
	if err != nil {
		return ""
	}
	key := core.FoldKey(p)
	for other, entry := range index.Snapshot() {
		if other != p && entry.Kind != core.KindDeleted && core.FoldKey(other) == key {
			return other
		}
	}
	return ""
}

// contentReader streams a remote file's content: from an identical local
// file when one exists, reusing unchanged blocks of the old version of a
// large file, and otherwise from the peer.
func (e *Engine) contentReader(ctx context.Context, member sf.Member, client peerClient, remote core.Entry, current *sf.Local, limiter *limiter) (io.Reader, func()) {
	if local := e.localCopy(ctx, member, remote); local != nil {
		return local, func() { _ = local.Close() }
	}
	var oldBlocks, newBlocks []string
	var old *os.File
	if remote.Size > core.BlockThreshold && current != nil && current.Kind == core.KindFile && current.Revision != "" && current.Size > 0 {
		if blocks, err := client.blocks(ctx, member.FolderID, remote.Path, remote.SHA256); err == nil && len(blocks) == int((remote.Size+core.BlockSize-1)/core.BlockSize) {
			if local, err := e.fileBlocks(ctx, member, current.Path, current.Revision, current.SHA256); err == nil {
				if f, _, err := files.OpenRevision(ctx, member.Path, current.Path, current.Revision); err == nil {
					old, oldBlocks, newBlocks = f, local, blocks
				}
			}
		}
	}
	reader := &remoteReader{ctx: ctx, client: client, folderID: member.FolderID, entry: remote, limiter: limiter, old: old, oldBlocks: oldBlocks, newBlocks: newBlocks}
	return reader, func() {
		if old != nil {
			_ = old.Close()
		}
	}
}

type verifiedFile struct {
	*os.File
	ctx      context.Context
	path     string
	revision string
	done     bool
}

func (f *verifiedFile) Read(b []byte) (int, error) {
	n, err := f.File.Read(b)
	if errors.Is(err, io.EOF) && !f.done {
		f.done = true
		if verr := files.Unchanged(f.ctx, f.File, f.path, f.revision); verr != nil {
			return n, verr
		}
	}
	return n, err
}

// localCopy opens another file of the member with the wanted content.
func (e *Engine) localCopy(ctx context.Context, member sf.Member, remote core.Entry) *verifiedFile {
	index, err := e.folders().Index(member.FolderID)
	if err != nil {
		return nil
	}
	for path, entry := range index.Snapshot() {
		if entry.Kind != core.KindFile || entry.SHA256 != remote.SHA256 || entry.Size != remote.Size || entry.Revision == "" {
			continue
		}
		f, _, err := files.OpenRevision(ctx, member.Path, path, entry.Revision)
		if err != nil {
			continue
		}
		return &verifiedFile{File: f, ctx: ctx, path: path, revision: entry.Revision}
	}
	return nil
}

// fileBlocks are the block hashes of a local file version, cached by SHA-256.
func (e *Engine) fileBlocks(ctx context.Context, member sf.Member, path, revision, sha string) ([]string, error) {
	e.blockMu.Lock()
	if blocks, ok := e.blocks[sha]; ok {
		e.blockMu.Unlock()
		return blocks, nil
	}
	e.blockMu.Unlock()
	blocks, whole, err := files.Blocks(ctx, member.Path, path, revision)
	if err != nil {
		return nil, err
	}
	if whole != sha {
		return nil, fault.New(fault.Conflict, "file content changed")
	}
	e.blockMu.Lock()
	if len(e.blocks) >= 64 {
		for key := range e.blocks {
			delete(e.blocks, key)
			break
		}
	}
	e.blocks[sha] = blocks
	e.blockMu.Unlock()
	return blocks, nil
}

// remoteReader reads a file from a peer in block-sized chunks, taking blocks
// whose hash matches from the old local version instead.
type remoteReader struct {
	ctx       context.Context
	client    peerClient
	folderID  string
	entry     core.Entry
	limiter   *limiter
	old       *os.File
	oldBlocks []string
	newBlocks []string
	offset    int64
	buffer    []byte
}

func (r *remoteReader) Read(b []byte) (int, error) {
	if len(r.buffer) == 0 {
		if r.offset >= r.entry.Size {
			return 0, io.EOF
		}
		block := int(r.offset / core.BlockSize)
		length := int(min(int64(core.BlockSize), r.entry.Size-r.offset))
		var data []byte
		if r.old != nil && block < len(r.oldBlocks) && block < len(r.newBlocks) && r.oldBlocks[block] == r.newBlocks[block] {
			data = make([]byte, length)
			if _, err := r.old.ReadAt(data, r.offset); err != nil {
				data = nil
			} else if files.Digest(data) != r.newBlocks[block] {
				data = nil
			}
		}
		if data == nil {
			var err error
			data, err = r.client.read(r.ctx, r.folderID, r.entry.Path, r.entry.SHA256, r.offset, length)
			if err != nil {
				return 0, err
			}
			if len(data) != length {
				return 0, fault.New(fault.DataLoss, "short chunk from peer")
			}
			if block < len(r.newBlocks) && files.Digest(data) != r.newBlocks[block] {
				return 0, fault.New(fault.DataLoss, "chunk hash mismatch")
			}
			r.limiter.wait(r.ctx, len(data))
		}
		r.buffer = data
		r.offset += int64(len(data))
	}
	n := copy(b, r.buffer)
	r.buffer = r.buffer[n:]
	return n, nil
}

// limiter spreads transfers to at most bytes per second; nil is unlimited.
type limiter struct {
	mu    sync.Mutex
	rate  int64
	ready time.Time
}

func newLimiter(rate int64) *limiter {
	if rate <= 0 {
		return nil
	}
	return &limiter{rate: rate}
}

func (l *limiter) wait(ctx context.Context, n int) {
	if l == nil {
		return
	}
	l.mu.Lock()
	now := time.Now()
	if l.ready.Before(now) {
		l.ready = now
	}
	l.ready = l.ready.Add(time.Duration(float64(n) / float64(l.rate) * float64(time.Second)))
	delay := l.ready.Sub(now)
	l.mu.Unlock()
	if delay <= 0 {
		return
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-timer.C:
	}
}
