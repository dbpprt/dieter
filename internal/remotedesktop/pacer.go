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
	healthyUntil     time.Time
	confirmedRate    int
	probeCeiling     int
	probeID          uint64
	probeACK         probeAcknowledgments
	transportID      uint8
	transportHistory [transportHistorySize]sentTransportPacket
	transport        transportHealth
}

func newPacketPacer(rate int) *packetPacer {
	ctx, cancel := context.WithCancel(context.Background())
	return &packetPacer{writers: make(map[uint32]interceptor.RTPWriter), bitrate: rate, probeCeiling: 16_000_000, ctx: ctx, cancel: cancel}
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
		p.confirmedRate = 0
		p.probeACK.lost = true
		return
	}
	p.healthyUntil = now.Add(time.Second)
}

func (p *packetPacer) BeginFrame(now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	// Probe after idle AND during sparse activity. No extra frame queue or
	// old capacity assumption: each doubling needs TWCC
	// acknowledgment. A probe does not itself become the encoder's budget.
	base := max(p.bitrate, p.confirmedRate)
	if now.Sub(p.lastProbe) >= 3*time.Second && now.Before(p.healthyUntil) &&
		p.transportID != 0 && base < p.probeCeiling {
		p.probeRate = min(base*2, p.probeCeiling)
		p.probeBytes = min(64<<10, max(3840, base/8/10))
		p.probeUntil = now.Add(250 * time.Millisecond)
		p.lastProbe = now
		p.probeID++
		p.probeACK = probeAcknowledgments{}
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
		return max(p.bitrate, p.confirmedRate, p.probeRate)
	}
	p.probeBytes = 0
	return max(p.bitrate, p.confirmedRate)
}

func (p *packetPacer) TargetBitrate() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return max(p.bitrate, p.confirmedRate)
}

// Small RTP padding completes a probe when desktop changes contain too few
// packets to measure capacity. Padding follows the frame and uses its remaining
// byte/time budget; it never runs on a timer while the desktop is idle.
func (p *packetPacer) needsProbePadding(now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.probeBytes >= 384 && now.Before(p.probeUntil) && now.Before(p.healthyUntil)
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
	size := len(payload) + int(header.PaddingSize) + header.MarshalSize() + 48
	if size > p.probeBytes {
		p.probeBytes = 0
	}
	rate := p.targetLocked(time.Now()) * 5 / 2
	probe := uint64(0)
	if p.probeBytes > 0 {
		probe = p.probeID
	}
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
	p.recordTransport(started, header, size, probe)
	n, err := writer.Write(header, payload, attributes)
	p.writeNanoseconds.Add(int64(time.Since(started)))
	return n, err
}
