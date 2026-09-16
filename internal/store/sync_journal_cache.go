package store

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"sync"
)

// Watchers share a bounded tail and read only bytes appended since their last
// poll. Reopening/scanning a 16 MiB journal for every active client would make
// catch-up latency grow throughout an otherwise healthy session.
type syncJournalCache struct {
	mu     sync.Mutex
	epoch  string
	file   os.FileInfo
	offset int64
	rows   []SyncEvent
}

func (s *Store) cachedSyncEvents(epoch string, highwater, after uint64, limit int) ([]SyncEvent, bool, error) {
	cache := &s.syncJournal
	cache.mu.Lock()
	defer cache.mu.Unlock()
	file, err := os.Open(s.syncEventsPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, true, nil
	}
	if err != nil {
		return nil, false, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, false, err
	}
	if cache.epoch != epoch || cache.file == nil || !os.SameFile(cache.file, info) || info.Size() < cache.offset || info.Size() == cache.offset && !sameFileRevision(cache.file, info) {
		cache.epoch = epoch
		cache.offset = 0
		cache.rows = nil
	}
	scanner := bufio.NewScanner(io.NewSectionReader(file, cache.offset, info.Size()-cache.offset))
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for scanner.Scan() {
		line := scanner.Bytes()
		next := cache.offset + int64(len(line)+1)
		if next > info.Size() {
			break
		} // Never cache a torn, uncommitted last record.
		cache.offset = next
		var event SyncEvent
		if json.Unmarshal(line, &event) != nil {
			continue
		}
		if n := len(cache.rows); n > 0 && event.Sequence <= cache.rows[n-1].Sequence {
			continue
		}
		cache.rows = append(cache.rows, event)
		if len(cache.rows) > 2*retainedSyncEventRows {
			cache.rows = append([]SyncEvent(nil), cache.rows[len(cache.rows)-retainedSyncEventRows:]...)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, false, err
	}
	cache.file = info
	if len(cache.rows) > 0 && cache.rows[0].Sequence > after+1 {
		return nil, false, nil
	}
	result := make([]SyncEvent, 0, min(limit, len(cache.rows)))
	for _, event := range cache.rows {
		if event.Sequence > after && event.Sequence <= highwater {
			result = append(result, event)
			if len(result) == limit {
				break
			}
		}
	}
	return result, true, nil
}
