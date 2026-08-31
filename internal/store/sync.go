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
	"time"
)

const SyncProjectionVersion = 4

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
	file, err := os.OpenFile(s.syncEventsPath(), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(append(line, '\n'))
	if writeErr == nil {
		writeErr = file.Sync()
	}
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

// prepareSyncMutation is called only while the central cross-process writer
// lock is held. A pending record is durable before any domain write begins.
// On a process crash readers treat it as an invalidation, and the next writer
// commits it before allocating another sequence.
func (s *Store) prepareSyncMutation() (*SyncEvent, error) {
	if _, err := s.ensureSyncEpoch(); err != nil {
		return nil, err
	}
	highwater, err := s.syncHighwater()
	if err != nil {
		return nil, err
	}
	if pending, pendingErr := s.readPendingSyncEvent(); pendingErr != nil {
		return nil, pendingErr
	} else if pending != nil {
		if pending.Sequence > highwater {
			if err := s.appendSyncEvent(*pending); err != nil {
				return nil, err
			}
			highwater = pending.Sequence
			if err := atomicWriteMode(s.syncHighwaterPath(), []byte(strconv.FormatUint(highwater, 10)+"\n"), 0o600); err != nil {
				return nil, err
			}
		}
		if err := os.Remove(s.syncPendingPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}
	event := &SyncEvent{Sequence: highwater + 1, Kind: "store_changed", CreatedAt: timestamp()}
	// Publish the invalidation before changing domain files. This removes the
	// post-mutation crash window. WatchSync waits for the writer lock to clear
	// before materializing the corresponding projection.
	if err := s.appendSyncEvent(*event); err != nil {
		return nil, err
	}
	if err := atomicWriteMode(s.syncHighwaterPath(), []byte(strconv.FormatUint(event.Sequence, 10)+"\n"), 0o600); err != nil {
		return nil, err
	}
	if info, statErr := os.Stat(s.syncEventsPath()); statErr == nil && info.Size() > maxSyncJournalBytes {
		if compactErr := s.compactSyncJournal(retainedSyncEventRows); compactErr != nil {
			return nil, compactErr
		}
	}
	return event, nil
}

func (s *Store) commitSyncMutation(event *SyncEvent) error {
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

// WaitForWriter ensures a streamed invalidation is materialized only after
// the mutation which published it has released the cross-process lock.
func (s *Store) WaitForWriter(ctx context.Context) error {
	lockPath := filepath.Join(s.Root, ".write-lock")
	for {
		_, err := os.Stat(lockPath)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// SyncEvents returns committed events after the cursor. A prepared event left
// by a killed writer is surfaced as a conservative invalidation so a mutation
// can never become invisible to native clients.
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
	pending, err := s.readPendingSyncEvent()
	if err != nil {
		return SyncCursor{}, nil, err
	}
	current := highwater
	if pending != nil && pending.Sequence > current {
		current = pending.Sequence
	}
	// Watchers spend almost all of their lifetime at the current cursor. Avoid
	// reopening and decoding the complete durable journal on every poll when no
	// committed row can possibly follow it. A pending crash-recovery event is
	// still surfaced below when it is newer than the committed highwater.
	if after >= highwater {
		result := make([]SyncEvent, 0, 1)
		if pending != nil && pending.Sequence > after && pending.Sequence > highwater {
			result = append(result, *pending)
		}
		return SyncCursor{Epoch: epoch, Sequence: current}, result, nil
	}
	result := make([]SyncEvent, 0)
	file, err := os.Open(s.syncEventsPath())
	if err == nil {
		scanner := bufio.NewScanner(file)
		scanner.Buffer(make([]byte, 64*1024), 1<<20)
		for scanner.Scan() {
			var event SyncEvent
			if json.Unmarshal(scanner.Bytes(), &event) == nil && event.Sequence > after {
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
	if pending != nil && pending.Sequence > after && pending.Sequence > highwater && len(result) < limit {
		result = append(result, *pending)
	}
	return SyncCursor{Epoch: epoch, Sequence: current}, result, nil
}
