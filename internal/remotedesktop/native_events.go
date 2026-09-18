package remotedesktop

import (
	"context"
	"sync"
)

// State/cursor delivery may enter a slow peer's data channel. Never run it on
// the helper ACK reader. Keep only the latest values per native stream, with a
// fixed bound that also allows for retiring encoder lanes.
type nativeEventMailbox struct {
	mu      sync.Mutex
	pending map[uint64]SourceEvent
	wake    chan struct{}
}

func newNativeEventMailbox() *nativeEventMailbox {
	return &nativeEventMailbox{pending: make(map[uint64]SourceEvent), wake: make(chan struct{}, 1)}
}
func (m *nativeEventMailbox) push(event SourceEvent) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	old, exists := m.pending[event.StreamID]
	if !exists && len(m.pending) >= 2*maxClients+1 {
		return false
	}
	old.StreamID = event.StreamID
	if event.State != nil {
		old.State = event.State
	}
	if event.Cursor != nil {
		// Position-only updates must not erase an undelivered cursor shape.
		if old.Cursor != nil && old.Cursor.ShapeId == event.Cursor.ShapeId && len(event.Cursor.Png) == 0 {
			event.Cursor.Png = old.Cursor.Png
		}
		old.Cursor = event.Cursor
	}
	if event.Content != nil && (old.Content == nil || event.Content.Generation > old.Content.Generation ||
		event.Content.Generation == old.Content.Generation && event.Content.Sequence > old.Content.Sequence) {
		old.Content = event.Content
	}
	if event.Err != nil {
		old.Err = event.Err
	}
	m.pending[event.StreamID] = old
	select {
	case m.wake <- struct{}{}:
	default:
	}
	return true
}
func (m *nativeEventMailbox) run(ctx context.Context, handler func(SourceEvent)) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-m.wake:
		}
		m.mu.Lock()
		pending := m.pending
		m.pending = make(map[uint64]SourceEvent)
		m.mu.Unlock()
		for _, event := range pending {
			if ctx.Err() != nil {
				return
			}
			handler(event)
		}
	}
}
