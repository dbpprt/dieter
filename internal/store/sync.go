package store

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const SyncProjectionVersion = 5

const (
	maxSyncJournalBytes   = 16 << 20
	retainedSyncEventRows = 4_096
)

// SyncEvent is the durable, daemon-wide ordering boundary. The first protocol
// journal intentionally remains a conservative invalidation boundary. The
// server coalesces these events and derives a small metadata delta for native
// clients, so high-frequency conversation writes never duplicate transcripts
// onto the daemon-wide stream.
type SyncEvent struct {
	Sequence  uint64 `json:"sequence"`
	Kind      string `json:"kind"`
	CreatedAt string `json:"createdAt"`
	CommandID string `json:"commandId,omitempty"`
}

type SyncCursor struct {
	Epoch    string
	Sequence uint64
}

func (s *Store) syncDir() string { return filepath.Join(s.Root, "sync") }

func (s *Store) syncEpochPath() string     { return filepath.Join(s.syncDir(), "epoch") }
func (s *Store) syncEventsPath() string    { return filepath.Join(s.syncDir(), "events.ndjson") }
func (s *Store) syncPendingPath() string   { return filepath.Join(s.syncDir(), "pending.json") }
func (s *Store) syncHighwaterPath() string { return filepath.Join(s.syncDir(), "highwater") }
func (s *Store) syncMetadataPath() string  { return filepath.Join(s.syncDir(), "metadata-highwater") }

// MetadataCursor excludes token-only invalidations. A selected transcript has
// its own file revision; unrelated text must not rebuild its card/comments.
func (s *Store) MetadataCursor() (SyncCursor, error) {
	epoch, err := os.ReadFile(s.syncEpochPath())
	if errors.Is(err, os.ErrNotExist) {
		return SyncCursor{}, nil
	}
	if err != nil {
		return SyncCursor{}, err
	}
	raw, err := os.ReadFile(s.syncMetadataPath())
	if errors.Is(err, os.ErrNotExist) {
		return SyncCursor{Epoch: strings.TrimSpace(string(epoch))}, nil
	}
	if err != nil {
		return SyncCursor{}, err
	}
	sequence, err := strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 64)
	return SyncCursor{Epoch: strings.TrimSpace(string(epoch)), Sequence: sequence}, err
}

func (s *Store) ensureSyncEpoch() (string, error) {
	if err := os.MkdirAll(s.syncDir(), 0o700); err != nil {
		return "", err
	}
	raw, err := os.ReadFile(s.syncEpochPath())
	if err == nil && strings.TrimSpace(string(raw)) != "" {
		return strings.TrimSpace(string(raw)), nil
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	epoch := newID("sync_")
	if err := atomicWriteMode(s.syncEpochPath(), []byte(epoch+"\n"), 0o600); err != nil {
		return "", err
	}
	return epoch, nil
}

func (s *Store) syncHighwater() (uint64, error) {
	raw, err := os.ReadFile(s.syncHighwaterPath())
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	value, err := strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("decode sync highwater: %w", err)
	}
	return value, nil
}

func (s *Store) readPendingSyncEvent() (*SyncEvent, error) {
	raw, err := os.ReadFile(s.syncPendingPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var event SyncEvent
	if err := json.Unmarshal(raw, &event); err != nil {
		return nil, fmt.Errorf("decode pending sync event: %w", err)
	}
	return &event, nil
}

func (s *Store) appendSyncEvent(event SyncEvent) error {
	if err := os.MkdirAll(s.syncDir(), 0o700); err != nil {
		return err
	}
	line, err := json.Marshal(event)
	if err != nil {
		return err
	}
	return appendJournalRecord(s.syncEventsPath(), line)
}

// prepareSyncMutation is called only while the central cross-process writer
// lock is held. A pending record is durable before any domain write begins.
// On a process crash readers treat it as an invalidation, and the next writer
// commits it before allocating another sequence.
func (s *Store) prepareSyncMutation(kind ...string) (*SyncEvent, error) {
	if _, err := s.ensureSyncEpoch(); err != nil {
		return nil, err
	}
	if err := s.recoverSyncMutation(); err != nil {
		return nil, err
	}
	highwater, err := s.syncHighwater()
	if err != nil {
		return nil, err
	}
	eventKind := "store_changed"
	if len(kind) > 0 && strings.TrimSpace(kind[0]) != "" {
		eventKind = strings.TrimSpace(kind[0])
	}
	event := &SyncEvent{Sequence: highwater + 1, Kind: eventKind, CreatedAt: timestamp()}
	raw, err := json.Marshal(event)
	if err != nil {
		return nil, err
	}
	if err := atomicWriteMode(s.syncPendingPath(), raw, 0o600); err != nil {
		return nil, err
	}
	return event, nil
}

// Must hold the central writer lock. Pending means a writer may have changed
// some domain files, never that the projection at that sequence is committed.
func (s *Store) recoverSyncMutation() error {
	pending, err := s.readPendingSyncEvent()
	if err != nil || pending == nil {
		return err
	}
	pending.Kind = "store_changed"
	return s.commitSyncMutation(pending)
}

func (s *Store) commitSyncMutation(event *SyncEvent) error {
	if event == nil {
		return nil
	}
	highwater, err := s.syncHighwater()
	if err != nil {
		return err
	}
	if event.Sequence > highwater {
		if err := s.appendSyncEvent(*event); err != nil {
			return err
		}
	}
	// Metadata has its own invalidation boundary: text chunks cannot continuously
	// invalidate an otherwise unchanged directory scan.
	if event.Kind != "conversation_changed" {
		if err := atomicWriteMode(s.syncMetadataPath(), []byte(strconv.FormatUint(event.Sequence, 10)+"\n"), 0o600); err != nil {
			return err
		}
	}
	if event.Sequence > highwater {
		if err := atomicWriteMode(s.syncHighwaterPath(), []byte(strconv.FormatUint(event.Sequence, 10)+"\n"), 0o600); err != nil {
			return err
		}
	}
	if err := os.Remove(s.syncPendingPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if info, err := os.Stat(s.syncEventsPath()); err == nil && info.Size() > maxSyncJournalBytes {
		return s.compactSyncJournal(retainedSyncEventRows)
	}
	return nil
}

// compactSyncJournal keeps disk use bounded. Changing the epoch makes every
// older cursor explicitly reset to a fresh projection instead of silently
// skipping rows which were compacted away.
func (s *Store) compactSyncJournal(retain int) error {
	if retain < 1 {
		retain = 1
	}
	file, err := os.Open(s.syncEventsPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	rows := make([][]byte, 0, retain)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 1<<20)
	for scanner.Scan() {
		row := append([]byte(nil), scanner.Bytes()...)
		if len(rows) == retain {
			copy(rows, rows[1:])
			rows[len(rows)-1] = row
		} else {
			rows = append(rows, row)
		}
	}
	scanErr := scanner.Err()
	closeErr := file.Close()
	if scanErr != nil {
		return scanErr
	}
	if closeErr != nil {
		return closeErr
	}
	var compacted strings.Builder
	for _, row := range rows {
		compacted.Write(row)
		compacted.WriteByte('\n')
	}
	if err := atomicWriteMode(s.syncEventsPath(), []byte(compacted.String()), 0o600); err != nil {
		return err
	}
	return atomicWriteMode(s.syncEpochPath(), []byte(newID("sync_")+"\n"), 0o600)
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

// SyncEvents returns only committed events. GlobalStateContext and the next
// writer recover a durable pending invalidation under the central lock.
func (s *Store) SyncEvents(after uint64, limit int) (SyncCursor, []SyncEvent, error) {
	epochRaw, err := os.ReadFile(s.syncEpochPath())
	if errors.Is(err, os.ErrNotExist) {
		return SyncCursor{}, []SyncEvent{}, nil
	}
	if err != nil {
		return SyncCursor{}, nil, err
	}
	epoch := strings.TrimSpace(string(epochRaw))
	if limit < 1 || limit > 256 {
		limit = 256
	}
	highwater, err := s.syncHighwater()
	if err != nil {
		return SyncCursor{}, nil, err
	}
	current := highwater
	if after >= highwater {
		return SyncCursor{Epoch: epoch, Sequence: current}, nil, nil
	}
	if result, complete, err := s.cachedSyncEvents(epoch, highwater, after, limit); err != nil || complete {
		return SyncCursor{Epoch: epoch, Sequence: current}, result, err
	}
	// A cursor older than the in-memory tail can still inspect retained disk
	// history. The ordinary connected path never rescans that prefix.
	result := make([]SyncEvent, 0)
	file, err := os.Open(s.syncEventsPath())
	if err == nil {
		scanner := bufio.NewScanner(file)
		scanner.Buffer(make([]byte, 64*1024), 1<<20)
		for scanner.Scan() {
			var event SyncEvent
			if json.Unmarshal(scanner.Bytes(), &event) == nil && event.Sequence > after && event.Sequence <= highwater {
				result = append(result, event)
				if len(result) == limit {
					break
				}
			}
		}
		scanErr := scanner.Err()
		closeErr := file.Close()
		if scanErr != nil {
			return SyncCursor{}, nil, scanErr
		}
		if closeErr != nil {
			return SyncCursor{}, nil, closeErr
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return SyncCursor{}, nil, err
	}
	return SyncCursor{Epoch: epoch, Sequence: current}, result, nil
}

// SyncMutationPending lets a watcher recover a writer that died before commit,
// even when the last published highwater has not changed.
func (s *Store) SyncMutationPending() bool {
	_, err := os.Stat(s.syncPendingPath())
	return err == nil
}
