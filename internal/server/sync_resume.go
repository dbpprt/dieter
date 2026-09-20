package server

import (
	"crypto/sha256"
	"encoding/hex"
	"sync"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/proto"
)

const maxRetainedSyncBytes = 32 << 20

type retainedSyncProjection struct {
	value                *syncProjection
	limit, recent, bytes int
	used                 uint64
}
type syncProjectionCache struct {
	mu     sync.Mutex
	values map[string]retainedSyncProjection
	bytes  int
	clock  uint64
}

func (s *Server) retainSyncProjection(p *syncProjection, limit, recent int) string {
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(p.snapshot)
	if err != nil {
		return ""
	}
	digest := sha256.Sum256(raw)
	id := hex.EncodeToString(digest[:])
	cache := &s.syncProjections
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.values == nil {
		cache.values = make(map[string]retainedSyncProjection)
	}
	if old, ok := cache.values[id]; ok {
		cache.bytes -= old.bytes
		delete(cache.values, id)
	}
	if len(raw) > maxRetainedSyncBytes {
		return ""
	}
	for len(cache.values) > 0 && (cache.bytes+len(raw) > maxRetainedSyncBytes || len(cache.values) >= 64) {
		oldest := ""
		age := ^uint64(0)
		for key, item := range cache.values {
			if item.used < age {
				oldest, age = key, item.used
			}
		}
		cache.bytes -= cache.values[oldest].bytes
		delete(cache.values, oldest)
	}
	cache.clock++
	cache.values[id] = retainedSyncProjection{p, limit, recent, len(raw), cache.clock}
	cache.bytes += len(raw)
	return id
}

func (s *Server) resumedSyncProjection(request *dieterv1.SyncRequest, current store.SyncCursor) *syncProjection {
	after := request.GetAfter()
	if after.GetProjectionId() == "" || after.GetEpoch() != current.Epoch || after.GetProjectionVersion() != store.SyncProjectionVersion || after.GetSequence() > current.Sequence {
		return nil
	}
	cache := &s.syncProjections
	cache.mu.Lock()
	defer cache.mu.Unlock()
	entry, ok := cache.values[after.GetProjectionId()]
	if !ok || entry.limit != int(request.GetConversationLimit()) || entry.recent != int(request.GetRecentConversationLimit()) || entry.value.cursor.Epoch != after.GetEpoch() || entry.value.cursor.Sequence != after.GetSequence() {
		return nil
	}
	cache.clock++
	entry.used = cache.clock
	cache.values[after.GetProjectionId()] = entry
	return entry.value
}
