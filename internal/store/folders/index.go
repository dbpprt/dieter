package folders

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
)

// Local is an index entry with what only this host knows: the observed
// filetransfer revision of the file on disk (empty for directories and
// tombstones) and when it was recorded.
type Local struct {
	folders.Entry
	Revision string `json:"revision,omitempty"`
	At       string `json:"at,omitempty"`
}

// Index is one membership's index: entries by path, ordered by sequence.
// Writers hold the central writer lock before its mutex.
type Index struct {
	dir string
	id  string

	mu      sync.Mutex
	head    uint64
	entries map[string]*Local
	// order lists sequences and paths in sequence order. A slot whose path
	// has a newer sequence is stale and skipped.
	order    []slot
	stale    int
	logLines int
	log      *os.File
}

type slot struct {
	sequence uint64
	path     string
}

type snapshotHeader struct {
	IndexID  string `json:"indexId"`
	Sequence uint64 `json:"sequence"`
}

// Index opens the index of folder id, loading it once per process.
func (s *Store) Index(id string) (*Index, error) {
	member, err := s.Member(id)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if index := s.indexes[id]; index != nil && index.id == member.IndexID {
		return index, nil
	}
	index := &Index{dir: filepath.Join(s.dir(id), "index"), id: member.IndexID, entries: map[string]*Local{}}
	if err := index.load(); err != nil {
		return nil, err
	}
	s.indexes[id] = index
	return index, nil
}

func (x *Index) load() error {
	if err := os.MkdirAll(x.dir, 0o700); err != nil {
		return err
	}
	apply := func(line []byte, last bool) error {
		var entry Local
		if err := json.Unmarshal(line, &entry); err != nil {
			if last {
				// A crash can leave the last appended line incomplete.
				return errTruncated
			}
			return fault.New(fault.DataLoss, "corrupt folder index")
		}
		// A later line with the same sequence is a touch: it wins.
		if current := x.entries[entry.Path]; current == nil || current.Sequence <= entry.Sequence {
			x.entries[entry.Path] = &entry
		}
		x.head = max(x.head, entry.Sequence)
		return nil
	}
	if raw, err := os.ReadFile(filepath.Join(x.dir, "snapshot.jsonl")); err == nil {
		lines := bytes.Split(raw, []byte("\n"))
		var header snapshotHeader
		if len(lines) == 0 || json.Unmarshal(lines[0], &header) != nil || header.IndexID != x.id {
			return fault.New(fault.DataLoss, "folder index snapshot belongs to another index")
		}
		x.head = header.Sequence
		for _, line := range lines[1:] {
			if len(bytes.TrimSpace(line)) == 0 {
				continue
			}
			if err := apply(line, false); err != nil {
				return err
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	logPath := filepath.Join(x.dir, "log.jsonl")
	raw, err := os.ReadFile(logPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	valid := 0
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for scanner.Scan() {
		line := scanner.Bytes()
		end := valid + len(line) + 1
		last := end >= len(raw)
		if len(bytes.TrimSpace(line)) > 0 {
			if err := apply(line, last); errors.Is(err, errTruncated) {
				break
			} else if err != nil {
				return err
			}
			x.logLines++
		}
		valid = min(end, len(raw))
	}
	if valid < len(raw) {
		if err := os.Truncate(logPath, int64(valid)); err != nil {
			return err
		}
	}
	x.rebuildOrder()
	return nil
}

var errTruncated = errors.New("truncated folder index line")

func (x *Index) rebuildOrder() {
	x.order = x.order[:0]
	for path, entry := range x.entries {
		x.order = append(x.order, slot{entry.Sequence, path})
	}
	sort.Slice(x.order, func(i, j int) bool { return x.order[i].sequence < x.order[j].sequence })
	x.stale = 0
}

// ID is the index ID: a peer's checkpoint applies only to the same ID.
func (x *Index) ID() string { return x.id }

// Head is the latest sequence.
func (x *Index) Head() uint64 { x.mu.Lock(); defer x.mu.Unlock(); return x.head }

// Get is the entry at path.
func (x *Index) Get(path string) (Local, bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	entry := x.entries[path]
	if entry == nil {
		return Local{}, false
	}
	return *entry, true
}

// Len is the number of entries, tombstones included.
func (x *Index) Len() int { x.mu.Lock(); defer x.mu.Unlock(); return len(x.entries) }

// Stats counts live entries, files and their bytes.
func (x *Index) Stats() (entries, files, bytes int64) {
	x.mu.Lock()
	defer x.mu.Unlock()
	for _, entry := range x.entries {
		if entry.Kind == folders.KindDeleted {
			continue
		}
		entries++
		if entry.Kind == folders.KindFile {
			files++
			bytes += entry.Size
		}
	}
	return
}

// Snapshot copies every entry.
func (x *Index) Snapshot() map[string]Local {
	x.mu.Lock()
	defer x.mu.Unlock()
	out := make(map[string]Local, len(x.entries))
	for path, entry := range x.entries {
		out[path] = *entry
	}
	return out
}

// Page returns up to limit entries with a sequence after after, in order,
// the sequence of the last one and whether more follow.
func (x *Index) Page(after uint64, limit int) ([]Local, uint64, bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	start := sort.Search(len(x.order), func(i int) bool { return x.order[i].sequence > after })
	var out []Local
	last := after
	for i := start; i < len(x.order); i++ {
		s := x.order[i]
		entry := x.entries[s.path]
		if entry == nil || entry.Sequence != s.sequence {
			continue
		}
		if len(out) == limit {
			return out, last, true
		}
		out = append(out, *entry)
		last = s.sequence
	}
	return out, last, false
}

// Commit records changes (under the writer lock) and returns them with
// their new sequences.
func (s *Store) Commit(ctx context.Context, id string, changes []Local) ([]Local, error) {
	var out []Local
	err := s.WithLock(ctx, func() error {
		var err error
		out, err = s.CommitLocked(id, changes)
		return err
	})
	return out, err
}

// CommitLocked records changes; the caller holds the writer lock. Each
// change gets the next sequence and replaces the entry at its path.
func (s *Store) CommitLocked(id string, changes []Local) ([]Local, error) {
	if len(changes) == 0 {
		return nil, nil
	}
	index, err := s.Index(id)
	if err != nil {
		return nil, err
	}
	return index.commit(changes)
}

func (x *Index) commit(changes []Local) ([]Local, error) {
	x.mu.Lock()
	defer x.mu.Unlock()
	added := 0
	for _, change := range changes {
		if x.entries[change.Path] == nil {
			added++
		}
	}
	if len(x.entries)+added > folders.MaxEntries {
		return nil, fault.New(fault.ResourceExhausted, fmt.Sprintf("a folder holds at most %d entries", folders.MaxEntries))
	}
	if x.log == nil {
		f, err := os.OpenFile(filepath.Join(x.dir, "log.jsonl"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
		if err != nil {
			return nil, err
		}
		x.log = f
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	var buffer bytes.Buffer
	out := make([]Local, len(changes))
	head := x.head
	for i, change := range changes {
		head++
		change.Sequence = head
		if change.At == "" {
			change.At = now
		}
		raw, err := json.Marshal(change)
		if err != nil {
			return nil, err
		}
		buffer.Write(raw)
		buffer.WriteByte('\n')
		out[i] = change
	}
	if _, err := x.log.Write(buffer.Bytes()); err != nil {
		return nil, err
	}
	if err := x.log.Sync(); err != nil {
		return nil, err
	}
	x.head = head
	for i := range out {
		change := out[i]
		if old := x.entries[change.Path]; old != nil {
			x.stale++
		}
		x.entries[change.Path] = &change
		x.order = append(x.order, slot{change.Sequence, change.Path})
		x.logLines++
	}
	if x.stale > len(x.order)/2 {
		x.rebuildOrder()
	}
	if x.logLines > 4*len(x.entries)+1024 {
		return out, x.compact()
	}
	return out, nil
}

// TouchLocked records new observed revisions of unchanged entries (same
// content, e.g. a touched file) without changing their sequence. The caller
// holds the writer lock. Entries whose sequence moved on are skipped.
func (s *Store) TouchLocked(id string, touches []Local) error {
	if len(touches) == 0 {
		return nil
	}
	index, err := s.Index(id)
	if err != nil {
		return err
	}
	index.mu.Lock()
	defer index.mu.Unlock()
	if index.log == nil {
		f, err := os.OpenFile(filepath.Join(index.dir, "log.jsonl"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
		if err != nil {
			return err
		}
		index.log = f
	}
	var buffer bytes.Buffer
	var applied []Local
	for _, touch := range touches {
		current := index.entries[touch.Path]
		if current == nil || current.Sequence != touch.Sequence {
			continue
		}
		next := *current
		next.Revision = touch.Revision
		raw, err := json.Marshal(next)
		if err != nil {
			return err
		}
		buffer.Write(raw)
		buffer.WriteByte('\n')
		applied = append(applied, next)
	}
	if len(applied) == 0 {
		return nil
	}
	if _, err := index.log.Write(buffer.Bytes()); err != nil {
		return err
	}
	if err := index.log.Sync(); err != nil {
		return err
	}
	for i := range applied {
		entry := applied[i]
		index.entries[entry.Path] = &entry
		index.logLines++
	}
	return nil
}

// compact writes every live entry into a new snapshot and empties the log.
// Replaying an old log over a new snapshot is harmless: the highest sequence
// of a path wins.
func (x *Index) compact() error {
	var buffer bytes.Buffer
	header, _ := json.Marshal(snapshotHeader{IndexID: x.id, Sequence: x.head})
	buffer.Write(header)
	buffer.WriteByte('\n')
	for _, s := range x.order {
		entry := x.entries[s.path]
		if entry == nil || entry.Sequence != s.sequence {
			continue
		}
		raw, err := json.Marshal(entry)
		if err != nil {
			return err
		}
		buffer.Write(raw)
		buffer.WriteByte('\n')
	}
	if err := fsx.WriteFile(filepath.Join(x.dir, "snapshot.jsonl"), buffer.Bytes(), 0o600); err != nil {
		return err
	}
	if x.log != nil {
		_ = x.log.Close()
		x.log = nil
	}
	if err := fsx.WriteFile(filepath.Join(x.dir, "log.jsonl"), nil, 0o600); err != nil {
		return err
	}
	x.logLines = 0
	return nil
}

// ForgetLocked drops tombstones whose sequence every member has fetched
// (upTo) or that are older than cutoff. The caller holds the writer lock.
func (s *Store) ForgetLocked(id string, upTo uint64, cutoff time.Time) (int, error) {
	index, err := s.Index(id)
	if err != nil {
		return 0, err
	}
	index.mu.Lock()
	defer index.mu.Unlock()
	removed := 0
	for path, entry := range index.entries {
		if entry.Kind != folders.KindDeleted {
			continue
		}
		at, _ := time.Parse(time.RFC3339Nano, entry.At)
		if entry.Sequence <= upTo || !at.IsZero() && at.Before(cutoff) {
			delete(index.entries, path)
			removed++
		}
	}
	if removed == 0 {
		return 0, nil
	}
	index.rebuildOrder()
	return removed, index.compact()
}

// Close releases open index logs.
func (s *Store) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, index := range s.indexes {
		index.mu.Lock()
		if index.log != nil {
			_ = index.log.Close()
			index.log = nil
		}
		index.mu.Unlock()
	}
}
