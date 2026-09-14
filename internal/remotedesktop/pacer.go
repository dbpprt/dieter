package remotedesktop

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

// packetPacer applies backpressure instead of accumulating a packet queue. The
// producer owns at most one encoded access unit and the helper replaces raw
// pending frames. Whole-frame admission/recovery happens before packetization.
type packetPacer struct {
	mu               sync.Mutex
	sendMu           sync.Mutex
	writers          map[uint32]interceptor.RTPWriter
	bitrate          int
	next             time.Time
	ctx              context.Context
	cancel           context.CancelFunc
	writeNanoseconds atomic.Int64
}

func newPacketPacer(rate int) *packetPacer {
	ctx, cancel := context.WithCancel(context.Background())
	return &packetPacer{writers: make(map[uint32]interceptor.RTPWriter), bitrate: rate, ctx: ctx, cancel: cancel}
}
func (p *packetPacer) AddStream(ssrc uint32, w interceptor.RTPWriter) {
	p.mu.Lock()
	p.writers[ssrc] = w
	p.mu.Unlock()
}
func (p *packetPacer) SetTargetBitrate(rate int) {
	p.mu.Lock()
	p.bitrate = max(100_000, rate)
	p.mu.Unlock()
}
func (p *packetPacer) Close() error { p.cancel(); return nil }
func (p *packetPacer) Write(header *rtp.Header, payload []byte, attributes interceptor.Attributes) (int, error) {
	p.sendMu.Lock()
	defer p.sendMu.Unlock()
	p.mu.Lock()
	writer := p.writers[header.SSRC]
	next := p.next
	// Headroom lets a bounded burst (not an unbounded packet queue) carry
	// keyframes and lets GCC observe capacity above the encoded media rate.
	rate := p.bitrate * 5 / 2
	p.mu.Unlock()
	if writer == nil {
		return 0, errors.New("pacer stream not registered")
	}
	const burst = 5 * time.Millisecond
	if delay := time.Until(next.Add(-burst)); delay > 0 {
		timer := time.NewTimer(delay)
		select {
		case <-p.ctx.Done():
			timer.Stop()
			return 0, p.ctx.Err()
		case <-timer.C:
		}
	}
	select {
	case <-p.ctx.Done():
		return 0, p.ctx.Err()
	default:
	}
	size := len(payload) + header.MarshalSize() + 48
	p.mu.Lock()
	// Keep the virtual send schedule across timer wakeups. Starting a fresh
	// per-packet timer loses throughput to scheduler latency on fast LANs.
	now := time.Now()
	if next.Before(now) {
		next = now
	}
	p.next = next.Add(time.Duration(float64(size*8) * float64(time.Second) / float64(max(100_000, rate))))
	p.mu.Unlock()
	started := time.Now()
	n, err := writer.Write(header, payload, attributes)
	p.writeNanoseconds.Add(int64(time.Since(started)))
	return n, err
}
