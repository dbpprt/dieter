package folders

import (
	"context"
	"slices"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	core "github.com/dbpprt/dieter/internal/folders"
	sf "github.com/dbpprt/dieter/internal/store/folders"
)

// scan walks a member's directory and records local changes: new and
// modified files and directories bump this daemon's counter, missing entries
// become tombstones (unless the deletion guard holds them), and a touched
// file whose content did not change only refreshes its observed revision.
// A receive-only member records nothing and lists its local changes.
func (e *Engine) scan(ctx context.Context, r *run, member sf.Member, definition Definition) (bool, error) {
	daemonID, actor, err := e.actor()
	if err != nil {
		return false, err
	}
	index, err := e.folders().Index(member.FolderID)
	if err != nil {
		return false, err
	}
	result, err := files.Scan(ctx, member.Path, files.ScanOptions{Limit: core.MaxEntries, Exclude: func(p string) bool { return !definition.Included(p) }})
	if err != nil {
		return false, err
	}
	snapshot := index.Snapshot()
	seen := make(map[string]bool, len(result.Entries))
	var changes, touches []sf.Local
	var localChanges []string
	receiveOnly := member.Mode == core.ModeReceiveOnly
	author := func(entry core.Entry) core.Entry {
		entry.AuthorID, entry.AuthorName = daemonID, core.SanitizeName(e.opts.Name)
		return entry
	}
	var unsyncable []Problem
	for _, skipped := range result.Skipped {
		unsyncable = append(unsyncable, Problem{Path: skipped.Path, Message: skipped.Reason, At: e.now()})
	}
	for _, entry := range result.Entries {
		p := entry.Path
		if err := core.ValidatePath(p); err != nil {
			unsyncable = append(unsyncable, Problem{Path: p, Message: err.Error(), At: e.now()})
			continue
		}
		seen[p] = true
		current, known := snapshot[p]
		switch entry.Kind {
		case "directory":
			if known && current.Kind == core.KindDirectory {
				continue
			}
			if receiveOnly {
				localChanges = append(localChanges, p)
				continue
			}
			changes = append(changes, sf.Local{Entry: author(core.Entry{Path: p, Kind: core.KindDirectory, Modified: entry.Modified, Version: current.Version.Bump(actor)})})
		case "file":
			if known && current.Kind == core.KindFile && current.Revision == entry.Revision {
				continue
			}
			hashed, err := files.Stat(ctx, member.Path, p, true)
			if err != nil {
				if !isConflict(err) {
					e.problem(r, p, err)
				}
				// A file that changes while it is hashed is retried next scan.
				continue
			}
			if hashed.Kind != "file" {
				continue
			}
			executable := hashed.Mode&0o111 != 0
			if known && current.Kind == core.KindFile && current.SHA256 == hashed.SHA256 && current.Size == hashed.Size && current.Executable == executable {
				touch := current
				touch.Revision = hashed.Revision
				touches = append(touches, touch)
				continue
			}
			if receiveOnly {
				if known && current.Kind == core.KindFile || !known {
					localChanges = append(localChanges, p)
				}
				continue
			}
			changes = append(changes, sf.Local{
				Entry:    author(core.Entry{Path: p, Kind: core.KindFile, Size: hashed.Size, Modified: hashed.Modified, Executable: executable, SHA256: hashed.SHA256, Version: current.Version.Bump(actor)}),
				Revision: hashed.Revision,
			})
		}
	}
	var deletions []sf.Local
	live := 0
	missing := map[string]bool{}
	now := e.now()
	for p, current := range snapshot {
		if current.Kind == core.KindDeleted {
			continue
		}
		live++
		if seen[p] || !definition.Included(p) || absentByDesign(p, result.Skipped) || r.restoring[p] {
			continue
		}
		if receiveOnly {
			localChanges = append(localChanges, p)
			continue
		}
		missing[p] = true
		deletions = append(deletions, sf.Local{Entry: author(core.Entry{Path: p, Kind: core.KindDeleted, Modified: now.UnixNano(), Version: current.Version.Bump(actor)})})
	}
	// A path must stay missing for the settle time before its deletion is
	// recorded; the guard judges every missing path, settled or not.
	if r.missingSince == nil {
		r.missingSince = map[string]time.Time{}
	}
	for p := range r.missingSince {
		if !missing[p] {
			delete(r.missingSince, p)
		}
	}
	for p := range missing {
		if _, ok := r.missingSince[p]; !ok {
			r.missingSince[p] = now
		}
	}
	allMissing := len(deletions)
	tripped := allMissing > 0 && core.GuardTrips(definition.DeleteGuard, allMissing, live)
	if !tripped {
		settled := deletions[:0]
		for _, deletion := range deletions {
			if now.Sub(r.missingSince[deletion.Path]) >= e.opts.DeleteSettle {
				settled = append(settled, deletion)
			}
		}
		deletions = settled
	}
	e.mu.Lock()
	r.status.LastScanAt = e.now()
	r.status.Unsyncable = unsyncable
	if len(r.status.Unsyncable) > maxProblems {
		r.status.Unsyncable = r.status.Unsyncable[:maxProblems]
	}
	slices.Sort(localChanges)
	r.status.LocalChanges = localChanges
	if tripped {
		paths := make([]string, 0, len(deletions))
		for _, deletion := range deletions {
			paths = append(paths, deletion.Path)
		}
		slices.Sort(paths)
		r.status.Pending = &Pending{Source: "local", Paths: paths}
		deletions = nil
		clear(r.missingSince)
	}
	e.mu.Unlock()
	for _, deletion := range deletions {
		delete(r.missingSince, deletion.Path)
	}
	changes = append(changes, deletions...)
	committed := 0
	err = e.folders().WithLock(ctx, func() error {
		// What changed since the snapshot (an upload, a pull) is left for the
		// next scan rather than overwritten.
		accepted := changes[:0]
		for _, change := range changes {
			current, ok := index.Get(change.Path)
			before, wasKnown := snapshot[change.Path]
			if ok != wasKnown || ok && current.Sequence != before.Sequence {
				continue
			}
			accepted = append(accepted, change)
		}
		out, err := e.folders().CommitLocked(member.FolderID, accepted)
		committed = len(out)
		if err != nil {
			return err
		}
		return e.folders().TouchLocked(member.FolderID, touches)
	})
	if committed > 0 {
		e.changed()
	}
	return committed > 0, err
}

// absentByDesign reports whether p is missing because a scan skipped it or
// one of its ancestors (a symlink, a mount point), not because it was deleted.
func absentByDesign(p string, skipped []files.Skipped) bool {
	for _, s := range skipped {
		if p == s.Path || len(p) > len(s.Path) && p[:len(s.Path)] == s.Path && p[len(s.Path)] == '/' {
			return true
		}
	}
	return false
}
