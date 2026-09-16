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
	lastFrameEnd     time.Time
	lastProbe        time.Time
	probeUntil       time.Time
	probeBytes       int
	probeRate        int
	recentRate       int
	recentAt         time.Time
	healthyUntil     time.Time
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

// Feedback is sampled outside GCC's callback (which owns its estimator lock).
// Delay overuse, loss, or a high RTT cancels probing, even on private routes.
func (p *packetPacer) ObserveNetwork(now time.Time, healthy bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !healthy {
		p.healthyUntil = time.Time{}
		p.probeBytes = 0
		p.recentRate = 0
		return
	}
	p.healthyUntil = now.Add(time.Second)
	if !p.lastFrameEnd.IsZero() && now.Sub(p.lastFrameEnd) < 250*time.Millisecond && p.probeBytes == 0 {
		p.recentRate, p.recentAt = p.bitrate, now
	}
}

func (p *packetPacer) BeginFrame(now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	// A gap after COMPLETING a frame is application idle. A long paced frame
	// is congestion/backpressure, and must never re-arm this probe.
	if !p.lastFrameEnd.IsZero() && now.Sub(p.lastFrameEnd) >= 500*time.Millisecond &&
		now.Sub(p.lastProbe) >= 5*time.Second && now.Before(p.healthyUntil) &&
		now.Sub(p.recentAt) < 30*time.Second && p.recentRate > p.bitrate {
		p.probeRate = min(p.recentRate, 8_000_000)
		p.probeBytes = 64 << 10
		p.probeUntil = now.Add(250 * time.Millisecond)
		p.lastProbe = now
		p.next = now
	}
}

func (p *packetPacer) EndFrame(now time.Time) {
	p.mu.Lock()
	p.lastFrameEnd = now
	p.mu.Unlock()
}

func (p *packetPacer) targetLocked(now time.Time) int {
	if p.probeBytes > 0 && now.Before(p.probeUntil) && now.Before(p.healthyUntil) {
		return max(p.bitrate, p.probeRate)
	}
	p.probeBytes = 0
	return p.bitrate
}

func (p *packetPacer) TargetBitrate() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.targetLocked(time.Now())
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
	size := len(payload) + header.MarshalSize() + 48
	if size > p.probeBytes {
		p.probeBytes = 0
	}
	rate := p.targetLocked(time.Now()) * 5 / 2
	p.probeBytes = max(0, p.probeBytes-size)
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
