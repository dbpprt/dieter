package home

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fsx"
)

// The store's change counter. Every committed mutation advances highwater;
// mutations other than streamed conversation text also advance
// metadata-highwater. A pending marker is durable before a writer changes
// domain files, so a writer killed mid-change still counts as a change once
// recovered. Readers treat changes to highwater as a hint and reread state.
const (
	MetadataChange     = "store_changed"
	ConversationChange = "conversation_changed"
)

type PendingMutation struct {
	Sequence uint64 `json:"sequence"`
	Kind     string `json:"kind"`
}

// StoreRevision identifies committed metadata: the counter's epoch and its
// metadata highwater. Streamed conversation text never changes it.
type Revision struct {
	Epoch    string
	Sequence uint64
}

func (s *Dir) SyncDir() string { return filepath.Join(s.Root, "sync") }

func (s *Dir) syncEpochPath() string   { return filepath.Join(s.SyncDir(), "epoch") }
func (s *Dir) syncPendingPath() string { return filepath.Join(s.SyncDir(), "pending.json") }

// SyncHighwaterPath counts every committed change.
func (s *Dir) SyncHighwaterPath() string { return filepath.Join(s.SyncDir(), "highwater") }

// SyncMetadataPath counts committed changes other than streamed conversation text.
func (s *Dir) SyncMetadataPath() string { return filepath.Join(s.SyncDir(), "metadata-highwater") }

// MetadataRevision excludes conversation text. A selected transcript has its
// own file revision; unrelated text must not rebuild card metadata.
func (s *Dir) MetadataRevision() (Revision, error) {
	epoch, err := os.ReadFile(s.syncEpochPath())
	if errors.Is(err, os.ErrNotExist) {
		return Revision{}, nil
	}
	if err != nil {
		return Revision{}, err
	}
	sequence, err := readCounter(s.SyncMetadataPath())
	return Revision{Epoch: strings.TrimSpace(string(epoch)), Sequence: sequence}, err
}

// ChangeCount is the number of committed changes, conversation text included.
func (s *Dir) ChangeCount() (uint64, error) {
	return readCounter(s.SyncHighwaterPath())
}

func (s *Dir) EnsureSyncEpoch() error {
	if err := os.MkdirAll(s.SyncDir(), 0o700); err != nil {
		return err
	}
	raw, err := os.ReadFile(s.syncEpochPath())
	if err == nil && strings.TrimSpace(string(raw)) != "" {
		return nil
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return fsx.WriteFile(s.syncEpochPath(), []byte(NewID("sync_")+"\n"), 0o600)
}

func readCounter(path string) (uint64, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	value, err := strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("decode %s: %w", filepath.Base(path), err)
	}
	return value, nil
}

func (s *Dir) readPendingMutation() (*PendingMutation, error) {
	raw, err := os.ReadFile(s.syncPendingPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var pending PendingMutation
	if err := json.Unmarshal(raw, &pending); err != nil {
		return nil, fmt.Errorf("decode pending mutation: %w", err)
	}
	return &pending, nil
}

// PrepareMutation is called only while the central cross-process writer
// lock is held. The pending marker is durable before any domain write begins.
func (s *Dir) PrepareMutation(kind string) (*PendingMutation, error) {
	if err := s.EnsureSyncEpoch(); err != nil {
		return nil, err
	}
	if err := s.RecoverMutation(); err != nil {
		return nil, err
	}
	highwater, err := readCounter(s.SyncHighwaterPath())
	if err != nil {
		return nil, err
	}
	if kind != ConversationChange {
		kind = MetadataChange
	}
	pending := &PendingMutation{Sequence: highwater + 1, Kind: kind}
	raw, err := json.Marshal(pending)
	if err != nil {
		return nil, err
	}
	if err := fsx.WriteFile(s.syncPendingPath(), raw, 0o600); err != nil {
		return nil, err
	}
	return pending, nil
}

// Must hold the central writer lock. Pending means a writer may have changed
// some domain files, so recovery always counts it as a metadata change.
func (s *Dir) RecoverMutation() error {
	pending, err := s.readPendingMutation()
	if err != nil || pending == nil {
		return err
	}
	pending.Kind = MetadataChange
	return s.CommitMutation(pending)
}

func (s *Dir) CommitMutation(pending *PendingMutation) error {
	if pending == nil {
		return nil
	}
	highwater, err := readCounter(s.SyncHighwaterPath())
	if err != nil {
		return err
	}
	// Metadata has its own boundary: text chunks cannot continuously
	// invalidate an otherwise unchanged directory.
	if pending.Kind != ConversationChange {
		if err := fsx.WriteFile(s.SyncMetadataPath(), []byte(strconv.FormatUint(pending.Sequence, 10)+"\n"), 0o600); err != nil {
			return err
		}
	}
	if pending.Sequence > highwater {
		if err := fsx.WriteFile(s.SyncHighwaterPath(), []byte(strconv.FormatUint(pending.Sequence, 10)+"\n"), 0o600); err != nil {
			return err
		}
	}
	if err := os.Remove(s.syncPendingPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// WaitForWriter crosses the committed writer boundary and recovers a killed
// owner without relying on a quiet gap between unrelated mutations.
func (s *Dir) WaitForWriter(ctx context.Context) error {
	release, err := s.BeginWriteLockContext(ctx)
	if err != nil {
		return err
	}
	defer release()
	return s.RecoverMutation()
}

// SyncMutationPending lets a watcher recover a writer that died before commit,
// even when the committed counters have not changed.
func (s *Dir) SyncMutationPending() bool {
	_, err := os.Stat(s.syncPendingPath())
	return err == nil
}
