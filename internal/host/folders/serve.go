package folders

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	core "github.com/dbpprt/dieter/internal/folders"
	transfers "github.com/dbpprt/dieter/internal/host/filetransfer"
	"github.com/dbpprt/dieter/internal/platform/fault"
	sf "github.com/dbpprt/dieter/internal/store/folders"
)

// usableMember is a member that may serve and accept changes now.
func (e *Engine) usableMember(folderID string) (sf.Member, Definition, error) {
	member, err := e.folders().Member(folderID)
	if err != nil {
		return member, Definition{}, err
	}
	definition, err := e.Definition(folderID)
	if err != nil {
		return member, definition, err
	}
	if definition.Archived {
		return member, definition, fault.New(fault.FailedPrecondition, "the folder is archived")
	}
	if member.Paused {
		return member, definition, fault.New(fault.FailedPrecondition, "the folder is paused on this machine")
	}
	dev, ino, err := rootIdentity(member.Path)
	if err != nil || dev != member.RootDev || ino != member.RootIno {
		return member, definition, fault.New(fault.FailedPrecondition, "the folder's location on this machine is unavailable")
	}
	return member, definition, nil
}

// IndexPageResult is a page of this daemon's index.
type IndexPageResult struct {
	IndexID  string
	Reset    bool
	Entries  []core.Entry
	Sequence uint64
	Head     uint64
	More     bool
}

// IndexPage serves entries after a sequence and records how far memberID got.
func (e *Engine) IndexPage(ctx context.Context, folderID, indexID string, after uint64, limit int, memberID string, acknowledged uint64) (IndexPageResult, error) {
	if limit <= 0 || limit > 512 {
		limit = 512
	}
	index, err := e.folders().Index(folderID)
	if err != nil {
		return IndexPageResult{}, err
	}
	result := IndexPageResult{IndexID: index.ID()}
	if indexID != "" && indexID != index.ID() || indexID == "" && after > 0 {
		result.Reset, after, acknowledged = true, 0, 0
	}
	locals, last, more := index.Page(after, limit)
	for _, local := range locals {
		result.Entries = append(result.Entries, local.Entry)
	}
	result.Sequence, result.More, result.Head = last, more, index.Head()
	if memberID != "" {
		e.acknowledge(ctx, folderID, memberID, index.ID(), max(after, acknowledged))
	}
	return result, nil
}

type ackState struct {
	mu      sync.Mutex
	pending map[string]map[string]sf.Ack
	flushed map[string]time.Time
}

func (e *Engine) acknowledge(ctx context.Context, folderID, memberID, indexID string, sequence uint64) {
	now := e.now()
	acks := &e.acks
	acks.mu.Lock()
	if acks.pending == nil {
		acks.pending, acks.flushed = map[string]map[string]sf.Ack{}, map[string]time.Time{}
	}
	if acks.pending[folderID] == nil {
		acks.pending[folderID] = map[string]sf.Ack{}
	}
	acks.pending[folderID][memberID] = sf.Ack{IndexID: indexID, Sequence: sequence, At: now.UTC().Format(time.RFC3339Nano)}
	due := now.Sub(acks.flushed[folderID]) > 30*time.Second
	var batch map[string]sf.Ack
	if due {
		batch = acks.pending[folderID]
		delete(acks.pending, folderID)
		acks.flushed[folderID] = now
	}
	acks.mu.Unlock()
	if batch == nil {
		return
	}
	seen := false
	err := e.folders().WithLock(ctx, func() error {
		return e.folders().UpdatePeersLocked(folderID, func(stored map[string]sf.Ack, clients []sf.Client) ([]sf.Client, error) {
			for id, ack := range batch {
				stored[id] = ack
				for i := range clients {
					if clients[i].DeviceID == id {
						clients[i].LastSeenAt, seen = ack.At, true
					}
				}
			}
			return clients, nil
		})
	})
	if err != nil {
		e.log.Debug("folder acknowledgements not saved", "folder", folderID, "error", err)
	}
	if seen {
		e.writeRecord(folderID, false)
	}
}

// ReadTarget resolves a content read of a folder member: the root and the
// observed revision of path, if it still has content sha.
func (e *Engine) ReadTarget(folderID, path, sha string) (string, string, error) {
	member, _, err := e.usableMember(folderID)
	if err != nil {
		return "", "", err
	}
	revision, err := e.currentRevision(context.Background(), member, path, sha)
	return member.Path, revision, err
}

// currentRevision is the observed revision of path while it has content sha.
// A recorded revision goes stale without a content change (a publish's
// rename, a hard link into the trash change the ctime); the file is then
// hashed once and the index refreshed.
func (e *Engine) currentRevision(ctx context.Context, member sf.Member, path, sha string) (string, error) {
	index, err := e.folders().Index(member.FolderID)
	if err != nil {
		return "", err
	}
	entry, ok := index.Get(path)
	if !ok || entry.Kind != core.KindFile || entry.SHA256 != sha {
		return "", fault.New(fault.Conflict, "this machine no longer has that version")
	}
	if entry.Revision != "" {
		if stat, err := files.Stat(ctx, member.Path, path, false); err == nil && stat.Revision == entry.Revision {
			return entry.Revision, nil
		}
	}
	hashed, err := files.Stat(ctx, member.Path, path, true)
	if err != nil {
		return "", err
	}
	if hashed.Kind != "file" || hashed.SHA256 != sha {
		return "", fault.New(fault.Conflict, "this machine no longer has that version")
	}
	entry.Revision = hashed.Revision
	if err := e.folders().WithLock(ctx, func() error { return e.folders().TouchLocked(member.FolderID, []sf.Local{entry}) }); err != nil {
		return "", err
	}
	return hashed.Revision, nil
}

// Root is the member root for transfers that don't need versions (stat,
// listing, the CLI's cp and sync).
func (e *Engine) Root(folderID string) (string, error) {
	member, _, err := e.usableMember(folderID)
	return member.Path, err
}

// Blocks are the block hashes of path at content sha.
func (e *Engine) Blocks(ctx context.Context, folderID, path, sha string) ([]string, error) {
	member, _, err := e.usableMember(folderID)
	if err != nil {
		return nil, err
	}
	revision, err := e.currentRevision(ctx, member, path, sha)
	if err != nil {
		return nil, err
	}
	return e.fileBlocks(ctx, member, path, revision, sha)
}

// acceptsChanges checks that a remote change may replace the local entry.
func (e *Engine) acceptsChanges(member sf.Member, definition Definition, entry core.Entry) error {
	if member.Mode == core.ModeSendOnly {
		return fault.New(fault.FailedPrecondition, "this machine only sends changes of the folder")
	}
	if !definition.Included(entry.Path) {
		return fault.Invalidf("the folder's rules exclude %s", entry.Path)
	}
	return nil
}

func dominates(current *sf.Local, entry core.Entry) error {
	if current == nil {
		return nil
	}
	switch core.Compare(current.Version, entry.Version) {
	case core.Before:
		return nil
	case core.Equal:
		return errEqual
	}
	return fault.New(fault.Conflict, "the folder changed; fetch its index and try again")
}

var errEqual = errors.New("already recorded")

// ExpectFolderUpload implements transfers.FolderCommitter.
func (e *Engine) ExpectFolderUpload(_ context.Context, folderID, path string, entry core.Entry) (string, error) {
	member, definition, err := e.usableMember(folderID)
	if err != nil {
		return "", err
	}
	if err := e.acceptsChanges(member, definition, entry); err != nil {
		return "", err
	}
	index, err := e.folders().Index(folderID)
	if err != nil {
		return "", err
	}
	var current *sf.Local
	if local, ok := index.Get(path); ok {
		current = &local
	}
	if err := dominates(current, entry); err != nil && !errors.Is(err, errEqual) {
		return "", err
	}
	if current == nil || current.Kind != core.KindFile || current.Revision == "" {
		return files.Missing, nil
	}
	return current.Revision, nil
}

type preserved struct{ item sf.TrashItem }

// PrepareFolderCommitLocked implements transfers.FolderCommitter.
func (e *Engine) PrepareFolderCommitLocked(ctx context.Context, upload transfers.Upload) (string, bool, error) {
	folder := upload.Folder
	member, definition, err := e.usableMember(folder.FolderID)
	if err != nil {
		return "", false, err
	}
	if upload.Root != member.Path {
		return "", false, fault.New(fault.Conflict, "the folder's location changed")
	}
	if err := e.acceptsChanges(member, definition, folder.Entry); err != nil {
		return "", false, err
	}
	index, err := e.folders().Index(folder.FolderID)
	if err != nil {
		return "", false, err
	}
	var current *sf.Local
	if local, ok := index.Get(upload.Path); ok {
		current = &local
	}
	if err := dominates(current, folder.Entry); err != nil {
		if errors.Is(err, errEqual) && current.SHA256 == folder.Entry.SHA256 && current.Revision != "" {
			// A retry of an upload whose index entry exists: publish again
			// over the identical file.
			return current.Revision, member.Quarantine, nil
		}
		return "", false, err
	}
	expected := files.Missing
	if current != nil {
		switch current.Kind {
		case core.KindFile:
			if current.Revision != "" {
				expected = current.Revision
			}
		case core.KindDirectory:
			if err := files.RemoveEmptyDir(member.Path, upload.Path); err != nil {
				return "", false, err
			}
		}
	}
	if expected != files.Missing && definition.TrashDays > 0 {
		id := newItemID()
		revision, err := files.Preserve(ctx, member.Path, upload.Path, expected, e.folders().TrashDir(folder.FolderID), id)
		if err != nil {
			return "", false, err
		}
		expected = revision
		e.preserved.Store(upload.ID, preserved{item: sf.TrashItem{ID: id, Path: upload.Path, Size: current.Size, SHA256: current.SHA256, Executable: current.Executable,
			Modified: current.Modified, Version: current.Version, DeletedAt: e.now().UTC().Format(time.RFC3339Nano), DeletedBy: folder.Entry.AuthorName, Reason: "replaced"}})
	}
	return expected, member.Quarantine, nil
}

// FolderCommittedLocked implements transfers.FolderCommitter.
func (e *Engine) FolderCommittedLocked(_ context.Context, upload transfers.Upload, published files.Entry) error {
	folder := upload.Folder
	index, err := e.folders().Index(folder.FolderID)
	if err != nil {
		return err
	}
	if current, ok := index.Get(upload.Path); ok && core.Compare(current.Version, folder.Entry.Version) == core.Equal && current.SHA256 == folder.Entry.SHA256 {
		if current.Revision != published.Revision {
			current.Revision = published.Revision
			return e.folders().TouchLocked(folder.FolderID, []sf.Local{current})
		}
		return nil
	}
	entry := folder.Entry
	entry.Sequence = 0
	if _, err := e.folders().CommitLocked(folder.FolderID, []sf.Local{{Entry: entry, Revision: published.Revision}}); err != nil {
		return err
	}
	if value, ok := e.preserved.LoadAndDelete(upload.ID); ok {
		if err := e.folders().AddTrashLocked(folder.FolderID, value.(preserved).item); err != nil {
			e.log.Warn("replaced version kept without a trash record", "folder", folder.FolderID, "error", err)
		}
	}
	go e.changed()
	return nil
}

// FolderCommitFailedLocked implements transfers.FolderCommitter.
func (e *Engine) FolderCommitFailedLocked(_ context.Context, upload transfers.Upload) {
	if value, ok := e.preserved.LoadAndDelete(upload.ID); ok {
		_ = os.Remove(filepath.Join(e.folders().TrashDir(upload.Folder.FolderID), value.(preserved).item.ID))
	}
}

// ApplyEntry creates a directory or applies a tombstone for a client or peer.
func (e *Engine) ApplyEntry(ctx context.Context, folderID string, entry core.Entry) (core.Entry, error) {
	if err := entry.Validate(); err != nil {
		return core.Entry{}, err
	}
	if entry.Kind != core.KindDirectory && entry.Kind != core.KindDeleted {
		return core.Entry{}, fault.Invalidf("files are uploaded, not applied")
	}
	member, definition, err := e.usableMember(folderID)
	if err != nil {
		return core.Entry{}, err
	}
	if err := e.acceptsChanges(member, definition, entry); err != nil {
		return core.Entry{}, err
	}
	var out core.Entry
	err = e.folders().WithLock(ctx, func() error {
		index, err := e.folders().Index(folderID)
		if err != nil {
			return err
		}
		var current *sf.Local
		if local, ok := index.Get(entry.Path); ok {
			current = &local
		}
		if err := dominates(current, entry); err != nil {
			if errors.Is(err, errEqual) {
				out = current.Entry
				return nil
			}
			return err
		}
		if current != nil && current.Kind == core.KindFile {
			if err := e.trashLocked(ctx, member, definition, *current, "deleted", entry.AuthorName); err != nil {
				return err
			}
		}
		switch entry.Kind {
		case core.KindDirectory:
			if err := files.Mkdir(member.Path, entry.Path); err != nil {
				return err
			}
		case core.KindDeleted:
			if current != nil && current.Kind == core.KindDirectory {
				if err := files.RemoveEmptyDir(member.Path, entry.Path); err != nil {
					return err
				}
			}
		}
		entry.Sequence = 0
		committed, err := e.folders().CommitLocked(folderID, []sf.Local{{Entry: entry}})
		if err == nil && len(committed) == 1 {
			out = committed[0].Entry
		}
		return err
	})
	if err == nil {
		go e.changed()
	}
	return out, err
}

// trashLocked moves a file into the trash while the caller holds the lock.
func (e *Engine) trashLocked(ctx context.Context, member sf.Member, definition Definition, current sf.Local, reason, by string) error {
	if definition.TrashDays <= 0 {
		err := files.Remove(ctx, member.Path, current.Path, current.Revision)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	id := newItemID()
	if _, err := files.MoveOut(ctx, member.Path, current.Path, current.Revision, e.folders().TrashDir(member.FolderID), id); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	return e.folders().AddTrashLocked(member.FolderID, sf.TrashItem{ID: id, Path: current.Path, Size: current.Size, SHA256: current.SHA256, Executable: current.Executable,
		Modified: current.Modified, Version: current.Version, DeletedAt: e.now().UTC().Format(time.RFC3339Nano), DeletedBy: by, Reason: reason})
}

// TrashPage lists trash items after the item ID after, newest first.
func (e *Engine) TrashPage(folderID, after string, limit int) ([]sf.TrashItem, string, int64, error) {
	items, err := e.folders().Trash(folderID)
	if err != nil {
		return nil, "", 0, err
	}
	var total int64
	for _, item := range items {
		total += item.Size
	}
	if limit <= 0 || limit > 512 {
		limit = 256
	}
	start := 0
	if after != "" {
		start = slices.IndexFunc(items, func(item sf.TrashItem) bool { return item.ID == after }) + 1
	}
	end := min(start+limit, len(items))
	next := ""
	if end < len(items) {
		next = items[end-1].ID
	}
	return items[start:end], next, total, nil
}

// RestoreTrash puts a trashed version back at its path as a new change.
func (e *Engine) RestoreTrash(ctx context.Context, folderID, itemID string) (core.Entry, error) {
	member, _, err := e.usableMember(folderID)
	if err != nil {
		return core.Entry{}, err
	}
	daemonID, actor, err := e.actor()
	if err != nil {
		return core.Entry{}, err
	}
	item, err := e.folders().TrashItemLocked(folderID, itemID)
	if err != nil {
		return core.Entry{}, err
	}
	index, err := e.folders().Index(folderID)
	if err != nil {
		return core.Entry{}, err
	}
	// The path must be free on disk; the index may still be recording the
	// deletion that trashed the item.
	if occupied, err := files.Stat(ctx, member.Path, item.Path, false); err != nil {
		return core.Entry{}, err
	} else if occupied.Kind != files.Missing {
		return core.Entry{}, fault.New(fault.Conflict, "something exists at "+item.Path+"; move it away first")
	}
	current, _ := index.Get(item.Path)
	payload, err := os.Open(filepath.Join(e.folders().TrashDir(folderID), item.ID))
	if err != nil {
		return core.Entry{}, err
	}
	defer payload.Close()
	info, err := payload.Stat()
	if err != nil {
		return core.Entry{}, err
	}
	sha := item.SHA256
	if sha == "" {
		hashed, err := files.Describe(ctx, payload, item.ID, true)
		if err != nil {
			return core.Entry{}, err
		}
		sha = hashed.SHA256
		if _, err := payload.Seek(0, 0); err != nil {
			return core.Entry{}, err
		}
	}
	mode := uint32(0o644)
	if item.Executable {
		mode = 0o755
	}
	modified := item.Modified
	if modified == 0 {
		modified = info.ModTime().UnixNano()
	}
	stat, err := files.PublishWith(ctx, member.Path, item.Path, files.Missing, files.Entry{Size: info.Size(), SHA256: sha, Mode: mode, Modified: modified}, payload, files.PublishOptions{})
	if err != nil {
		return core.Entry{}, err
	}
	entry := core.Entry{Path: item.Path, Kind: core.KindFile, Size: info.Size(), Modified: modified, Executable: item.Executable, SHA256: sha,
		Version: core.Merge(current.Version, item.Version).Bump(actor), AuthorID: daemonID, AuthorName: core.SanitizeName(e.opts.Name)}
	var out core.Entry
	err = e.folders().WithLock(ctx, func() error {
		committed, err := e.folders().CommitLocked(folderID, []sf.Local{{Entry: entry, Revision: stat.Revision}})
		if err != nil {
			return err
		}
		out = committed[0].Entry
		return e.folders().RemoveTrashLocked(folderID, []string{item.ID})
	})
	if err == nil {
		go e.changed()
	}
	return out, err
}

// PurgeTrash forgets trashed versions for good (all when ids is empty).
func (e *Engine) PurgeTrash(ctx context.Context, folderID string, ids []string) error {
	if _, err := e.folders().Member(folderID); err != nil {
		return err
	}
	return e.folders().WithLock(ctx, func() error { return e.folders().RemoveTrashLocked(folderID, ids) })
}

// ResolveDeletions applies or undoes the deletions the guard holds, and waits
// for the member's next cycle.
func (e *Engine) ResolveDeletions(ctx context.Context, folderID string, apply bool) error {
	r := e.runOf(folderID)
	if r == nil {
		return sf.ErrNotAttached
	}
	if !e.held(r) {
		return fault.New(fault.FailedPrecondition, "no deletions wait for confirmation")
	}
	e.mu.Lock()
	r.resolve = &resolution{apply: apply}
	e.mu.Unlock()
	wait, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return e.WaitCycle(wait, folderID, false)
}

// resolveHeld runs a person's answer inside the member's loop.
func (e *Engine) resolveHeld(ctx context.Context, r *run, member sf.Member, definition Definition, apply bool) bool {
	e.mu.Lock()
	pending := r.status.Pending
	r.status.Pending = nil
	e.mu.Unlock()
	if pending == nil {
		return false
	}
	defer e.changed()
	daemonID, actor, err := e.actor()
	if err != nil {
		e.problem(r, "", err)
		return false
	}
	index, err := e.folders().Index(member.FolderID)
	if err != nil {
		e.problem(r, "", err)
		return false
	}
	author := func(entry core.Entry) core.Entry {
		entry.AuthorID, entry.AuthorName = daemonID, core.SanitizeName(e.opts.Name)
		return entry
	}
	switch {
	case pending.Source == "local" && apply:
		var tombstones []sf.Local
		for _, p := range pending.Paths {
			current, ok := index.Get(p)
			if !ok || current.Kind == core.KindDeleted {
				continue
			}
			if stat, err := files.Stat(ctx, member.Path, p, false); err != nil || stat.Kind != files.Missing {
				continue
			}
			tombstones = append(tombstones, sf.Local{Entry: author(core.Entry{Path: p, Kind: core.KindDeleted, Modified: e.now().UnixNano(), Version: current.Version.Bump(actor)})})
		}
		if _, err := e.folders().Commit(ctx, member.FolderID, tombstones); err != nil {
			e.problem(r, "", err)
		}
	case pending.Source == "local":
		if r.restoring == nil {
			r.restoring = map[string]bool{}
		}
		for _, p := range pending.Paths {
			r.restoring[p] = true
		}
		e.restoreMissing(ctx, r, member, definition)
	case apply:
		var steps []step
		for _, tombstone := range pending.Entries {
			var current *sf.Local
			var localEntry *core.Entry
			if local, ok := index.Get(tombstone.Path); ok {
				current, localEntry = &local, &local.Entry
			}
			decision := core.Decide(localEntry, tombstone, member.Mode)
			if decision.Action == core.ActionApply || decision.Action == core.ActionMerge {
				steps = append(steps, step{remote: tombstone, decision: decision, current: current})
			}
		}
		if _, _, err := e.perform(ctx, r, member, definition, nil, steps); err != nil {
			e.problem(r, "", err)
		}
	default:
		var revived []sf.Local
		for _, tombstone := range pending.Entries {
			current, ok := index.Get(tombstone.Path)
			if !ok || current.Kind == core.KindDeleted {
				continue
			}
			current.Version = core.Merge(current.Version, tombstone.Version).Bump(actor)
			current.Entry = author(current.Entry)
			current.Sequence = 0
			revived = append(revived, current)
		}
		if _, err := e.folders().Commit(ctx, member.FolderID, revived); err != nil {
			e.problem(r, "", err)
		}
	}
	return true
}

// restoreMissing downloads the files a person chose to restore after the
// deletion guard held them, from any peer that has the same version, and
// recreates missing directories. Paths still missing are retried next cycle;
// scans do not record them as deletions meanwhile.
func (e *Engine) restoreMissing(ctx context.Context, r *run, member sf.Member, definition Definition) {
	if len(r.restoring) == 0 {
		return
	}
	index, err := e.folders().Index(member.FolderID)
	if err != nil {
		e.problem(r, "", err)
		return
	}
	peers, _ := e.peerMembers(member.FolderID)
	paths := make([]string, 0, len(r.restoring))
	for p := range r.restoring {
		paths = append(paths, p)
	}
	slices.Sort(paths)
	for _, p := range paths {
		current, ok := index.Get(p)
		if !ok {
			delete(r.restoring, p)
			continue
		}
		if stat, err := files.Stat(ctx, member.Path, p, false); err == nil && stat.Kind != files.Missing {
			delete(r.restoring, p)
			continue
		}
		switch current.Kind {
		case core.KindDirectory:
			if err := files.Mkdir(member.Path, p); err != nil {
				e.problem(r, p, err)
			} else {
				delete(r.restoring, p)
			}
			continue
		case core.KindDeleted:
			delete(r.restoring, p)
			continue
		}
		restored := false
		for _, peer := range peers {
			err := e.withPeer(ctx, peer.DaemonID, func(client peerClient) error {
				mode := uint32(0o644)
				if current.Executable {
					mode = 0o755
				}
				reader := &remoteReader{ctx: ctx, client: client, folderID: member.FolderID, entry: current.Entry}
				stat, err := files.PublishWith(ctx, member.Path, p, files.Missing, files.Entry{Size: current.Size, SHA256: current.SHA256, Mode: mode, Modified: current.Modified}, reader, files.PublishOptions{Quarantine: member.Quarantine})
				if err != nil {
					return err
				}
				touched := current
				touched.Revision = stat.Revision
				return e.folders().WithLock(ctx, func() error { return e.folders().TouchLocked(member.FolderID, []sf.Local{touched}) })
			})
			if err == nil {
				restored = true
				break
			}
		}
		if restored {
			delete(r.restoring, p)
		} else {
			e.problem(r, p, fault.New(fault.Unavailable, "no machine could restore this file yet"))
		}
	}
}
