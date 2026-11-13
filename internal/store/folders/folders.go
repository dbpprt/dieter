// Package folders stores this daemon's synced folder memberships under
// DIETER_HOME/folders/<folder>: the binding of a local directory
// (member.json), the index of entries with versions (an append-only log with
// a compacted snapshot), checkpoints of what was fetched from each peer,
// acknowledgements of what peers and clients fetched from here, the client
// members homed here, and the trash of old versions. The directory a member
// binds holds only payload; nothing of this is ever written into it.
//
// Every mutation runs under the central writer lock without recording a
// metadata change (home.BeginWriteLock): folder heads reach clients through
// the change stream's local half, which the engine refreshes. Lock order is
// the writer lock, then an index's mutex.
package folders

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/home"
)

var validFolderID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// ErrNotAttached reports a folder this daemon is not a member of.
var ErrNotAttached = fault.New(fault.NotFound, "this machine is not a member of the folder")

// Member is this daemon's binding of a local directory to a folder.
type Member struct {
	FolderID      string       `json:"folderId"`
	Path          string       `json:"path"`
	RootDev       uint64       `json:"rootDev"`
	RootIno       uint64       `json:"rootIno"`
	Mode          folders.Mode `json:"mode"`
	Paused        bool         `json:"paused,omitempty"`
	RescanSeconds int          `json:"rescanSeconds"`
	Bandwidth     int64        `json:"bandwidthLimit,omitempty"`
	Concurrency   int          `json:"concurrency"`
	Quarantine    bool         `json:"quarantine"`
	Watch         bool         `json:"watch"`
	IndexID       string       `json:"indexId"`
	AttachedAt    string       `json:"attachedAt"`
	// Join is the attach policy of the first scan: merge or adopt. It is
	// cleared once the member joined.
	Join string `json:"join,omitempty"`
}

// Defaults of a new member.
const (
	DefaultRescanSeconds = 3600
	DefaultConcurrency   = 4
)

// Store is the folders aggregate of one DIETER_HOME.
type Store struct {
	home *home.Dir

	mu      sync.Mutex
	indexes map[string]*Index
}

// New returns the folders aggregate of dir.
func New(dir *home.Dir) *Store { return &Store{home: dir, indexes: map[string]*Index{}} }

// Root is DIETER_HOME/folders.
func (s *Store) Root() string { return filepath.Join(s.home.Root, "folders") }

func (s *Store) dir(id string) string { return filepath.Join(s.Root(), id) }

// ValidID reports whether id can name a folder directory.
func ValidID(id string) bool { return validFolderID.MatchString(id) }

// WithLock runs fn under the central writer lock without recording a
// metadata change. fn may call the *Locked methods.
func (s *Store) WithLock(ctx context.Context, fn func() error) error {
	release, err := s.home.BeginWriteLockContext(ctx)
	if err != nil {
		return err
	}
	defer release()
	return fn()
}

// NotifyChanges wakes change streams so they refresh folder heads.
func (s *Store) NotifyChanges() { s.home.NotifyChanges() }

// Members lists this daemon's memberships in folder ID order.
func (s *Store) Members() ([]Member, error) {
	entries, err := os.ReadDir(s.Root())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var members []Member
	for _, entry := range entries {
		if !entry.IsDir() || !ValidID(entry.Name()) {
			continue
		}
		member, err := s.Member(entry.Name())
		if errors.Is(err, ErrNotAttached) {
			continue
		}
		if err != nil {
			return nil, err
		}
		members = append(members, member)
	}
	return members, nil
}

// Member is this daemon's membership of folder id.
func (s *Store) Member(id string) (Member, error) {
	if !ValidID(id) {
		return Member{}, fault.Invalidf("invalid folder ID")
	}
	var member Member
	err := home.ReadJSON(filepath.Join(s.dir(id), "member.json"), &member)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, home.ErrNotFound) {
		return Member{}, ErrNotAttached
	}
	return member, err
}

// AttachLocked records a new membership with a fresh index ID. The caller
// holds the writer lock.
func (s *Store) AttachLocked(member Member) (Member, error) {
	if !ValidID(member.FolderID) || !filepath.IsAbs(member.Path) || !folders.ValidMode(member.Mode) {
		return member, fault.Invalidf("folder, absolute path and mode required")
	}
	if _, err := s.Member(member.FolderID); err == nil {
		return member, fault.New(fault.AlreadyExists, "this machine is already a member of the folder")
	}
	// A leftover directory of an earlier membership is discarded whole.
	if err := os.RemoveAll(s.dir(member.FolderID)); err != nil {
		return member, err
	}
	s.mu.Lock()
	delete(s.indexes, member.FolderID)
	s.mu.Unlock()
	member.IndexID = NewIndexID()
	if member.AttachedAt == "" {
		member.AttachedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}
	if member.RescanSeconds <= 0 {
		member.RescanSeconds = DefaultRescanSeconds
	}
	if member.Concurrency <= 0 {
		member.Concurrency = DefaultConcurrency
	}
	return member, home.WriteJSON(filepath.Join(s.dir(member.FolderID), "member.json"), member)
}

// UpdateMember changes this daemon's membership of id.
func (s *Store) UpdateMember(ctx context.Context, id string, change func(*Member) error) (Member, error) {
	var member Member
	err := s.WithLock(ctx, func() error {
		var err error
		if member, err = s.Member(id); err != nil {
			return err
		}
		if err = change(&member); err != nil {
			return err
		}
		return home.WriteJSON(filepath.Join(s.dir(id), "member.json"), member)
	})
	return member, err
}

// DetachLocked forgets the membership of id: its index, checkpoints and
// trash. The member's directory is left alone.
func (s *Store) DetachLocked(id string) error {
	if _, err := s.Member(id); err != nil {
		return err
	}
	s.mu.Lock()
	if index := s.indexes[id]; index != nil {
		index.mu.Lock()
		if index.log != nil {
			_ = index.log.Close()
			index.log = nil
		}
		index.mu.Unlock()
	}
	delete(s.indexes, id)
	s.mu.Unlock()
	// The binding goes first, so a crash leaves no half-attached member.
	if err := os.Remove(filepath.Join(s.dir(id), "member.json")); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return os.RemoveAll(s.dir(id))
}

// NewIndexID is a random index ID.
func NewIndexID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return "ix_" + hex.EncodeToString(b)
}

// Checkpoint is how far this daemon fetched a peer's index.
type Checkpoint struct {
	IndexID    string `json:"indexId"`
	Sequence   uint64 `json:"sequence"`
	LastSyncAt string `json:"lastSyncAt,omitempty"`
}

func (s *Store) checkpointPath(id, member string) string {
	return filepath.Join(s.dir(id), "peers", hex.EncodeToString([]byte(member))+".json")
}

// Checkpoint is this daemon's checkpoint of member's index for folder id.
func (s *Store) Checkpoint(id, member string) (Checkpoint, error) {
	var checkpoint Checkpoint
	err := home.ReadJSON(s.checkpointPath(id, member), &checkpoint)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, home.ErrNotFound) {
		return Checkpoint{}, nil
	}
	return checkpoint, err
}

// SaveCheckpointLocked records a checkpoint. The caller holds the lock.
func (s *Store) SaveCheckpointLocked(id, member string, checkpoint Checkpoint) error {
	if _, err := s.Member(id); err != nil {
		return err
	}
	return home.WriteJSON(s.checkpointPath(id, member), checkpoint)
}

// Ack is how far a peer or client fetched this daemon's index.
type Ack struct {
	IndexID  string `json:"indexId"`
	Sequence uint64 `json:"sequence"`
	At       string `json:"at"`
}

// Client is a client member homed on this daemon.
type Client struct {
	DeviceID     string       `json:"deviceId"`
	Name         string       `json:"name,omitempty"`
	Mode         folders.Mode `json:"mode"`
	RegisteredAt string       `json:"registeredAt"`
	LastSeenAt   string       `json:"lastSeenAt,omitempty"`
}

type peersFile struct {
	Acks    map[string]Ack `json:"acks,omitempty"`
	Clients []Client       `json:"clients,omitempty"`
}

func (s *Store) peersPath(id string) string { return filepath.Join(s.dir(id), "members.json") }

func (s *Store) readPeers(id string) (peersFile, error) {
	var value peersFile
	err := home.ReadJSON(s.peersPath(id), &value)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, home.ErrNotFound) {
		err = nil
	}
	if value.Acks == nil {
		value.Acks = map[string]Ack{}
	}
	return value, err
}

// Clients lists the client members homed here for folder id.
func (s *Store) Clients(id string) ([]Client, error) {
	value, err := s.readPeers(id)
	return value.Clients, err
}

// Acks lists the acknowledgements of folder id by member ID.
func (s *Store) Acks(id string) (map[string]Ack, error) {
	value, err := s.readPeers(id)
	return value.Acks, err
}

// UpdatePeersLocked changes the clients and acknowledgements of folder id.
func (s *Store) UpdatePeersLocked(id string, change func(acks map[string]Ack, clients []Client) ([]Client, error)) error {
	if _, err := s.Member(id); err != nil {
		return err
	}
	value, err := s.readPeers(id)
	if err != nil {
		return err
	}
	clients, err := change(value.Acks, value.Clients)
	if err != nil {
		return err
	}
	sort.Slice(clients, func(i, j int) bool { return clients[i].DeviceID < clients[j].DeviceID })
	value.Clients = clients
	return home.WriteJSON(s.peersPath(id), value)
}
