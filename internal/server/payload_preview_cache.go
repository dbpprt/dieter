package server

import "sync"

// This process-local cache retains at most 256 short previews (160 Unicode
// codepoints each), never raw tool payloads. Content hashes prevent stale
// previews when a streamed or corrected tool result changes. FIFO admission
// bounds metadata as well as memory; no timers or background work are needed.
const maxPayloadPreviews = 256

var toolPayloadPreviews payloadPreviewCache

type payloadPreviewCache struct {
	mu      sync.Mutex
	entries map[[32]byte]string
	keys    [maxPayloadPreviews][32]byte
	next    int
}

func (c *payloadPreviewCache) get(key [32]byte) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	value, ok := c.entries[key]
	return value, ok
}

func (c *payloadPreviewCache) put(key [32]byte, value string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = make(map[[32]byte]string)
	}
	if _, exists := c.entries[key]; exists {
		return
	}
	if len(c.entries) == maxPayloadPreviews {
		delete(c.entries, c.keys[c.next])
	}
	c.keys[c.next] = key
	c.next = (c.next + 1) % maxPayloadPreviews
	c.entries[key] = value
}
