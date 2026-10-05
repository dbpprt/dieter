package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// The store's change counter. Every committed mutation advances highwater;
// mutations other than streamed conversation text also advance
// metadata-highwater. A pending marker is durable before a writer changes
// domain files, so a writer killed mid-change still counts as a change once
// recovered. Readers treat changes to highwater as a hint and reread state.
const (
	metadataChange     = "store_changed"
	conversationChange = "conversation_changed"
)

type pendingMutation struct {
	Sequence uint64 `json:"sequence"`
	Kind     string `json:"kind"`
}

// StoreRevision identifies committed metadata: the counter's epoch and its
// metadata highwater. Streamed conversation text never changes it.
type StoreRevision struct {
	Epoch    string
	Sequence uint64
}

func (s *Store) syncDir() string { return filepath.Join(s.Root, "sync") }

func (s *Store) syncEpochPath() string     { return filepath.Join(s.syncDir(), "epoch") }
func (s *Store) syncPendingPath() string   { return filepath.Join(s.syncDir(), "pending.json") }
func (s *Store) syncHighwaterPath() string { return filepath.Join(s.syncDir(), "highwater") }
func (s *Store) syncMetadataPath() string  { return filepath.Join(s.syncDir(), "metadata-highwater") }

// MetadataRevision excludes conversation text. A selected transcript has its
// own file revision; unrelated text must not rebuild card metadata.
func (s *Store) MetadataRevision() (StoreRevision, error) {
	epoch, err := os.ReadFile(s.syncEpochPath())
	if errors.Is(err, os.ErrNotExist) {
		return StoreRevision{}, nil
	}
	if err != nil {
		return StoreRevision{}, err
	}
	sequence, err := readCounter(s.syncMetadataPath())
	return StoreRevision{Epoch: strings.TrimSpace(string(epoch)), Sequence: sequence}, err
}

// ChangeCount is the number of committed changes, conversation text included.
func (s *Store) ChangeCount() (uint64, error) {
	return readCounter(s.syncHighwaterPath())
}

func (s *Store) ensureSyncEpoch() error {
	if err := os.MkdirAll(s.syncDir(), 0o700); err != nil {
		return err
	}
	raw, err := os.ReadFile(s.syncEpochPath())
	if err == nil && strings.TrimSpace(string(raw)) != "" {
		return nil
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return atomicWriteMode(s.syncEpochPath(), []byte(newID("sync_")+"\n"), 0o600)
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

func (s *Store) readPendingMutation() (*pendingMutation, error) {
	raw, err := os.ReadFile(s.syncPendingPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var pending pendingMutation
	if err := json.Unmarshal(raw, &pending); err != nil {
		return nil, fmt.Errorf("decode pending mutation: %w", err)
	}
	return &pending, nil
}

// prepareSyncMutation is called only while the central cross-process writer
// lock is held. The pending marker is durable before any domain write begins.
func (s *Store) prepareSyncMutation(kind string) (*pendingMutation, error) {
	if err := s.ensureSyncEpoch(); err != nil {
		return nil, err
	}
	if err := s.recoverSyncMutation(); err != nil {
		return nil, err
	}
	highwater, err := readCounter(s.syncHighwaterPath())
	if err != nil {
		return nil, err
	}
	if kind != conversationChange {
		kind = metadataChange
	}
	pending := &pendingMutation{Sequence: highwater + 1, Kind: kind}
	raw, err := json.Marshal(pending)
	if err != nil {
		return nil, err
	}
	if err := atomicWriteMode(s.syncPendingPath(), raw, 0o600); err != nil {
		return nil, err
	}
	return pending, nil
}

// Must hold the central writer lock. Pending means a writer may have changed
// some domain files, so recovery always counts it as a metadata change.
func (s *Store) recoverSyncMutation() error {
	pending, err := s.readPendingMutation()
	if err != nil || pending == nil {
		return err
	}
	pending.Kind = metadataChange
	return s.commitSyncMutation(pending)
}

func (s *Store) commitSyncMutation(pending *pendingMutation) error {
	if pending == nil {
		return nil
	}
	highwater, err := readCounter(s.syncHighwaterPath())
	if err != nil {
		return err
	}
	// Metadata has its own boundary: text chunks cannot continuously
	// invalidate an otherwise unchanged directory.
	if pending.Kind != conversationChange {
		if err := atomicWriteMode(s.syncMetadataPath(), []byte(strconv.FormatUint(pending.Sequence, 10)+"\n"), 0o600); err != nil {
			return err
		}
	}
	if pending.Sequence > highwater {
		if err := atomicWriteMode(s.syncHighwaterPath(), []byte(strconv.FormatUint(pending.Sequence, 10)+"\n"), 0o600); err != nil {
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
func (s *Store) WaitForWriter(ctx context.Context) error {
	release, err := s.beginWriteLockContext(ctx)
	if err != nil {
		return err
	}
	defer release()
	return s.recoverSyncMutation()
}

// SyncMutationPending lets a watcher recover a writer that died before commit,
// even when the committed counters have not changed.
func (s *Store) SyncMutationPending() bool {
	_, err := os.Stat(s.syncPendingPath())
	return err == nil
}
