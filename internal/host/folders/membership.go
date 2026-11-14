package folders

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	core "github.com/dbpprt/dieter/internal/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	sf "github.com/dbpprt/dieter/internal/store/folders"
)

func rootIdentity(root string) (uint64, uint64, error) { return files.RootIdentity(root) }

// System locations no folder may be or contain.
var (
	deniedTrees = []string{"/System", "/usr", "/bin", "/sbin", "/etc", "/dev", "/proc", "/sys", "/boot", "/Library", "/Applications", "/private/etc", "/run"}
	deniedExact = []string{"/", "/var", "/private", "/private/var", "/tmp", "/private/tmp", "/opt", "/home", "/Users", "/Volumes", "/mnt", "/media", "/root"}
)

func within(path, root string) bool {
	return path == root || strings.HasPrefix(path, strings.TrimSuffix(root, "/")+"/")
}

func overlaps(a, b string) bool { return within(a, b) || within(b, a) }

func canonical(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fault.Invalidf("the folder location must be an absolute path")
	}
	path = filepath.Clean(path)
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	// A missing location is created; its existing parent decides.
	parent, err := canonical(filepath.Dir(path))
	if err != nil {
		return "", err
	}
	return filepath.Join(parent, filepath.Base(path)), nil
}

// checkLocation refuses locations that would sync system files, Dieter's
// own storage, a registered checkout or another folder's directory.
func (e *Engine) checkLocation(folderID, path string) error {
	for _, denied := range deniedExact {
		if path == denied {
			return fault.Invalidf("%s cannot be a synced folder", path)
		}
	}
	for _, denied := range deniedTrees {
		if within(path, denied) {
			return fault.Invalidf("system locations cannot be synced folders: %s", path)
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		if resolved, err := filepath.EvalSymlinks(home); err == nil {
			home = resolved
		}
		if path == home || path == filepath.Dir(home) {
			return fault.Invalidf("choose a directory inside your home directory, not %s", path)
		}
	}
	dieterHome := e.store().Root
	if resolved, err := filepath.EvalSymlinks(dieterHome); err == nil {
		dieterHome = resolved
	}
	if overlaps(path, dieterHome) {
		return fault.Invalidf("a synced folder cannot contain or be inside Dieter's storage (%s)", dieterHome)
	}
	members, err := e.folders().Members()
	if err != nil {
		return err
	}
	for _, member := range members {
		if member.FolderID != folderID && overlaps(path, member.Path) {
			return fault.Invalidf("%s overlaps the location of another synced folder (%s)", path, member.Path)
		}
	}
	checkouts, err := e.store().Kanban.OwnedCheckouts()
	if err != nil {
		return err
	}
	for _, checkout := range checkouts {
		if checkout.Path == "" {
			continue
		}
		checkoutPath := checkout.Path
		if resolved, err := filepath.EvalSymlinks(checkoutPath); err == nil {
			checkoutPath = resolved
		}
		if overlaps(path, checkoutPath) {
			return fault.Invalidf("%s overlaps the registered checkout %s; Git syncs checkouts", path, checkoutPath)
		}
	}
	return nil
}

// AttachRequest binds a directory of this daemon to a folder.
type AttachRequest struct {
	FolderID string
	Path     string
	Mode     core.Mode
	Join     string // merge or adopt
	DryRun   bool
}

// PlanEntry is one path of an attach plan.
type PlanEntry struct{ Path, Action string }

// AttachResult is the outcome of AttachFolder.
type AttachResult struct {
	Member                                 sf.Member
	DryRun                                 bool
	Plan                                   []PlanEntry
	Adopt, New, Conflicts, Trash, Download int64
}

// Attach binds a directory to a folder, or plans it.
func (e *Engine) Attach(ctx context.Context, request AttachRequest) (AttachResult, error) {
	definition, err := e.Definition(request.FolderID)
	if err != nil {
		return AttachResult{}, err
	}
	if definition.Archived {
		return AttachResult{}, fault.New(fault.FailedPrecondition, "the folder is archived")
	}
	if request.Mode == "" {
		request.Mode = core.ModeTwoWay
	}
	if !core.ValidMode(request.Mode) {
		return AttachResult{}, fault.Invalidf("mode must be two-way, send-only or receive-only")
	}
	if request.Join == "" {
		request.Join = "merge"
	}
	if request.Join != "merge" && request.Join != "adopt" {
		return AttachResult{}, fault.Invalidf("join must be merge or adopt")
	}
	if _, err := e.folders().Member(request.FolderID); err == nil {
		return AttachResult{}, fault.New(fault.AlreadyExists, "this machine is already a member of the folder")
	}
	path, err := canonical(request.Path)
	if err != nil {
		return AttachResult{}, err
	}
	if err := e.checkLocation(request.FolderID, path); err != nil {
		return AttachResult{}, err
	}
	members, err := e.memberCount(request.FolderID)
	if err != nil {
		return AttachResult{}, err
	}
	if members >= schema.MaxFolderMembers {
		return AttachResult{}, fault.New(fault.ResourceExhausted, "a folder has at most 16 members")
	}
	result := AttachResult{DryRun: request.DryRun}
	if info, err := os.Stat(path); err == nil && !info.IsDir() {
		return result, fault.Invalidf("%s is not a directory", path)
	}
	plan, err := e.plan(ctx, request.FolderID, path, definition, request.Join)
	if err != nil {
		return result, err
	}
	result.Plan, result.Adopt, result.New, result.Conflicts, result.Trash, result.Download = plan.entries, plan.adopt, plan.new, plan.conflicts, plan.trash, plan.download
	if request.DryRun {
		result.Member = sf.Member{FolderID: request.FolderID, Path: path, Mode: request.Mode}
		return result, nil
	}
	if err := os.MkdirAll(path, 0o755); err != nil {
		return result, err
	}
	dev, ino, err := rootIdentity(path)
	if err != nil {
		return result, err
	}
	member := sf.Member{FolderID: request.FolderID, Path: path, RootDev: dev, RootIno: ino, Mode: request.Mode, Watch: true, Quarantine: quarantineDefault, Join: request.Join}
	err = e.folders().WithLock(ctx, func() error {
		var err error
		member, err = e.folders().AttachLocked(member)
		return err
	})
	if err != nil {
		return result, err
	}
	result.Member = member
	e.writeRecord(request.FolderID, true)
	e.Kick()
	return result, nil
}

func (e *Engine) memberCount(folderID string) (int, error) {
	seen := map[string]bool{}
	err := e.store().KV.FolderMembers(folderID+".", func(record schema.FolderMemberRecord) error {
		if record.FolderID != folderID {
			return nil
		}
		seen["d:"+record.DaemonID] = true
		for _, client := range record.Clients {
			seen["c:"+client.DeviceID] = true
		}
		return nil
	})
	return len(seen), err
}

type joinPlan struct {
	entries                                []PlanEntry
	adopt, new, conflicts, trash, download int64
	differing                              map[string]files.Entry
}

// remoteIndex is every entry of the first reachable peer's index.
func (e *Engine) remoteIndex(ctx context.Context, folderID string) (map[string]core.Entry, error) {
	peers, err := e.peerMembers(folderID)
	if err != nil || len(peers) == 0 || e.opts.Dial == nil {
		return nil, err
	}
	var lastErr error
	for _, peer := range peers {
		entries := map[string]core.Entry{}
		err := e.withPeer(ctx, peer.DaemonID, func(client peerClient) error {
			var after uint64
			indexID := ""
			for {
				page, err := client.index(ctx, folderID, indexID, after, "", 0)
				if err != nil {
					return err
				}
				indexID = page.IndexID
				for _, entry := range page.Entries {
					entries[entry.Path] = entry
				}
				after = page.Sequence
				if !page.More {
					return nil
				}
				if len(entries) > core.MaxEntries {
					return fault.New(fault.ResourceExhausted, "the folder has too many entries")
				}
			}
		})
		if err == nil {
			return entries, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

func (e *Engine) plan(ctx context.Context, folderID, path string, definition Definition, join string) (joinPlan, error) {
	plan := joinPlan{differing: map[string]files.Entry{}}
	local := map[string]files.Entry{}
	if _, err := os.Stat(path); err == nil {
		scanned, err := files.Scan(ctx, path, files.ScanOptions{Exclude: func(p string) bool { return !definition.Included(p) }})
		if err != nil {
			return plan, err
		}
		for _, entry := range scanned.Entries {
			if entry.Kind == "file" {
				local[entry.Path] = entry
			}
		}
	}
	remote, err := e.remoteIndex(ctx, folderID)
	if err != nil {
		return plan, err
	}
	add := func(path, action string) {
		if len(plan.entries) < 512 {
			plan.entries = append(plan.entries, PlanEntry{Path: path, Action: action})
		}
	}
	paths := make([]string, 0, len(local))
	for path := range local {
		paths = append(paths, path)
	}
	slices.Sort(paths)
	for _, p := range paths {
		entry := local[p]
		other, ok := remote[p]
		if !ok || other.Kind != core.KindFile {
			plan.new++
			add(p, "new")
			continue
		}
		hashed, err := files.Stat(ctx, path, p, true)
		if err != nil {
			return plan, err
		}
		if hashed.SHA256 == other.SHA256 && hashed.Size == other.Size {
			plan.adopt++
			add(p, "adopt")
			continue
		}
		plan.differing[p] = entry
		if join == "adopt" {
			plan.trash++
			add(p, "trash")
		} else {
			plan.conflicts++
			add(p, "conflict")
		}
	}
	remotePaths := make([]string, 0, len(remote))
	for p, entry := range remote {
		if entry.Kind == core.KindFile {
			if _, ok := local[p]; !ok {
				remotePaths = append(remotePaths, p)
			}
		}
	}
	slices.Sort(remotePaths)
	for _, p := range remotePaths {
		plan.download++
		add(p, "download")
	}
	return plan, nil
}

// join runs a new member's first round: with adopt, local files that differ
// from the folder go to the trash first; with merge, the scan and the pulls
// keep both versions.
func (e *Engine) join(ctx context.Context, r *run, member sf.Member, definition Definition) error {
	if member.Join == "adopt" {
		plan, err := e.plan(ctx, member.FolderID, member.Path, definition, "adopt")
		if err != nil {
			return err
		}
		for p, entry := range plan.differing {
			if err := e.trashFile(ctx, member, definition, p, entry.Revision, "adopted", "", nil); err != nil {
				e.problem(r, p, err)
			}
		}
	}
	_, err := e.folders().UpdateMember(ctx, member.FolderID, func(m *sf.Member) error {
		m.Join = ""
		return nil
	})
	return err
}

// MemberChange changes this daemon's membership; nil fields stay.
type MemberChange struct {
	Mode          *core.Mode
	Paused        *bool
	RescanSeconds *int
	Bandwidth     *int64
	Concurrency   *int
	Quarantine    *bool
	Watch         *bool
}

// UpdateMember changes this daemon's membership of a folder.
func (e *Engine) UpdateMember(ctx context.Context, folderID string, change MemberChange) (sf.Member, error) {
	member, err := e.folders().UpdateMember(ctx, folderID, func(m *sf.Member) error {
		if change.Mode != nil {
			if !core.ValidMode(*change.Mode) {
				return fault.Invalidf("mode must be two-way, send-only or receive-only")
			}
			m.Mode = *change.Mode
		}
		if change.Paused != nil {
			m.Paused = *change.Paused
		}
		if change.RescanSeconds != nil {
			if *change.RescanSeconds < 60 || *change.RescanSeconds > 7*24*3600 {
				return fault.Invalidf("rescan interval must be 60 s to 7 days")
			}
			m.RescanSeconds = *change.RescanSeconds
		}
		if change.Bandwidth != nil {
			if *change.Bandwidth < 0 {
				return fault.Invalidf("bandwidth limit must not be negative")
			}
			m.Bandwidth = *change.Bandwidth
		}
		if change.Concurrency != nil {
			if *change.Concurrency < 1 || *change.Concurrency > 8 {
				return fault.Invalidf("concurrency must be 1 to 8")
			}
			m.Concurrency = *change.Concurrency
		}
		if change.Quarantine != nil {
			m.Quarantine = *change.Quarantine
		}
		if change.Watch != nil {
			m.Watch = *change.Watch
		}
		return nil
	})
	if err != nil {
		return member, err
	}
	e.writeRecord(folderID, true)
	e.Wake(folderID, true)
	return member, nil
}

// Detach stops syncing on this daemon; files stay on disk.
func (e *Engine) Detach(ctx context.Context, folderID string) error {
	e.mu.Lock()
	r := e.runs[folderID]
	delete(e.runs, folderID)
	e.mu.Unlock()
	if r != nil {
		r.cancel()
		<-r.done
	}
	if err := e.folders().WithLock(ctx, func() error { return e.folders().DetachLocked(folderID) }); err != nil {
		return err
	}
	daemonID, err := e.DaemonID()
	if err != nil {
		return err
	}
	e.closePeers()
	if err := e.store().KV.DeleteFolderMember(folderID, daemonID); err != nil {
		return err
	}
	e.changed()
	return nil
}

// RegisterClient makes this daemon a phone's home for a folder.
func (e *Engine) RegisterClient(ctx context.Context, folderID, deviceID, name string, mode core.Mode) (sf.Client, error) {
	if deviceID == "" || len(deviceID) > 128 || strings.ContainsAny(deviceID, "\x00/") {
		return sf.Client{}, fault.Invalidf("device ID required")
	}
	if mode == "" {
		mode = core.ModeTwoWay
	}
	if !core.ValidMode(mode) {
		return sf.Client{}, fault.Invalidf("mode must be two-way, send-only or receive-only")
	}
	if _, err := e.folders().Member(folderID); err != nil {
		return sf.Client{}, err
	}
	now := e.now().UTC().Format(time.RFC3339Nano)
	client := sf.Client{DeviceID: deviceID, Name: core.SanitizeName(truncate(name, core.MaxNameBytes)), Mode: mode, RegisteredAt: now, LastSeenAt: now}
	count, err := e.memberCount(folderID)
	if err != nil {
		return client, err
	}
	err = e.folders().WithLock(ctx, func() error {
		return e.folders().UpdatePeersLocked(folderID, func(_ map[string]sf.Ack, clients []sf.Client) ([]sf.Client, error) {
			for i := range clients {
				if clients[i].DeviceID == deviceID {
					client.RegisteredAt = clients[i].RegisteredAt
					clients[i] = client
					return clients, nil
				}
			}
			if len(clients) >= schema.MaxFolderClients || count >= schema.MaxFolderMembers {
				return nil, fault.New(fault.ResourceExhausted, "a folder has at most 16 members")
			}
			return append(clients, client), nil
		})
	})
	if err != nil {
		return client, err
	}
	e.writeRecord(folderID, true)
	return client, nil
}

// UnregisterClient forgets a phone homed here.
func (e *Engine) UnregisterClient(ctx context.Context, folderID, deviceID string) error {
	err := e.folders().WithLock(ctx, func() error {
		return e.folders().UpdatePeersLocked(folderID, func(acks map[string]sf.Ack, clients []sf.Client) ([]sf.Client, error) {
			delete(acks, deviceID)
			return slices.DeleteFunc(clients, func(c sf.Client) bool { return c.DeviceID == deviceID }), nil
		})
	})
	if err == nil {
		e.writeRecord(folderID, true)
	}
	return err
}
