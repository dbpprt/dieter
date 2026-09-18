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

const repairDeadlineAttribute = "dieter.repairDeadline"
const repairGenerationAttribute = "dieter.repairGeneration"
const fecPacketAttribute = "dieter.fecPacket"

var errRepairExpired = errors.New("repair expired while pacing")
var errRepairObsolete = errors.New("repair belongs to a retired generation")

// packetPacer applies backpressure instead of accumulating a packet queue. The
// producer owns at most one encoded access unit and the helper replaces raw
// pending frames. Whole-frame admission/recovery happens before packetization.
type packetPacer struct {
	recoveryMetrics        recoveryMetrics
	mediaGeneration        atomic.Uint64
	descriptorID           atomic.Uint32
	fec                    *fecStream // sendMu; finalized packets, at most 12 retained
	fecNegotiated          atomic.Bool
	fecPercent             atomic.Int64
	fecPackets             atomic.Uint64
	fecBytes               atomic.Uint64
	mediaRTPBytes          atomic.Uint64
	repairRTPBytes         atomic.Uint64
	probeRTPBytes          atomic.Uint64
	fecRTPBytes            atomic.Uint64
	mu                     sync.Mutex
	sendMu                 sync.Mutex
	writers                map[uint32]interceptor.RTPWriter
	bitrate                int
	bitrateUpdated         time.Time
	next                   time.Time
	ctx                    context.Context
	cancel                 context.CancelFunc
	writeNanoseconds       atomic.Int64
	lastFrameEnd           time.Time
	lastProbe              time.Time
	probeUntil             time.Time
	probeBytes             int
	probeRate              int
	healthyUntil           time.Time
	confirmedRate          int
	probeCeiling           int
	probeID                uint64
	probeACK               probeAcknowledgments
	transportID            uint8
	transportHistory       [transportHistorySize]sentTransportPacket
	transport              transportHealth
	feedbackReady          chan struct{} // one coalesced wakeup; never configure from RTCP/GCC
	transportPressureSince time.Time
	recoveryRTT            time.Duration
	recoveryMeasured       time.Time
	recoveryFPS            int
}

// One delayed feedback burst is jitter, not sustained queue growth. Loss
// still revokes capacity immediately; delay needs repeated fresh evidence.
func (p *packetPacer) transportCongestedLocked(now time.Time, health transportHealth) bool {
	if health.loss >= .02 {
		return true
	}
	if health.growthMS <= 15 {
		p.transportPressureSince = time.Time{}
		return false
	}
	if p.transportPressureSince.IsZero() || now.Sub(p.transport.at) >= 2*time.Second {
		p.transportPressureSince = now
	}
	return now.Sub(p.transportPressureSince) >= 500*time.Millisecond
}

func (p *packetPacer) ConfirmedBitrate() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.confirmedRate
}

func newPacketPacer(rate int) *packetPacer {
	ctx, cancel := context.WithCancel(context.Background())
	return &packetPacer{writers: make(map[uint32]interceptor.RTPWriter), bitrate: rate, probeCeiling: 16_000_000, ctx: ctx, cancel: cancel, feedbackReady: make(chan struct{}, 1)}
}
func (p *packetPacer) AddStream(ssrc uint32, w interceptor.RTPWriter) {
	p.mu.Lock()
	p.writers[ssrc] = w
	p.mu.Unlock()
}
func (p *packetPacer) SetTargetBitrate(rate int) {
	p.mu.Lock()
	p.bitrate = max(100_000, rate)
	p.bitrateUpdated = time.Now()
	p.mu.Unlock()
	p.notifyFeedback()
}

func (p *packetPacer) notifyFeedback() {
	select {
	case p.feedbackReady <- struct{}{}:
	default:
	}
}

// Feedback is sampled outside GCC's callback (which owns its estimator lock).
// Sustained queue growth, loss, or missing fresh receiver feedback cancels
// probing, even on private routes.
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
	p.mu.Unlock()
	n, err := p.writePacket(header, payload, attributes, writer)
	if err != nil || p.fec == nil {
		return n, err
	}
	for _, repair := range p.fec.protect(time.Now(), header, payload, int(p.fecPercent.Load())) {
		if _, err = p.writePacket(&repair.Header, repair.Payload, interceptor.Attributes{fecPacketAttribute: true}, p.fec.writer); err != nil {
			return n, err
		}
		p.fecPackets.Add(1)
		p.fecBytes.Add(uint64(repair.MarshalSize() + 48))
	}
	return n, nil
}

func (p *packetPacer) writePacket(header *rtp.Header, payload []byte, attributes interceptor.Attributes, writer interceptor.RTPWriter) (int, error) {
	generation, repair := attributes[repairGenerationAttribute].(uint64)
	if repair && generation != p.mediaGeneration.Load() {
		return 0, errRepairObsolete
	}
	deadline, _ := attributes[repairDeadlineAttribute].(time.Time)
	if !deadline.IsZero() && !time.Now().Before(deadline) {
		return 0, errRepairExpired
	}
	p.mu.Lock()
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
	if !deadline.IsZero() && !next.Add(-burst).Before(deadline) {
		return 0, errRepairExpired
	}
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
	if repair && generation != p.mediaGeneration.Load() {
		return 0, errRepairObsolete
	}
	if !deadline.IsZero() && !time.Now().Before(deadline) {
		return 0, errRepairExpired
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
	if err == nil {
		bytes := uint64(header.MarshalSize() + len(payload) + int(header.PaddingSize))
		switch {
		case attributes[fecPacketAttribute] == true:
			p.fecRTPBytes.Add(bytes)
		case !deadline.IsZero():
			p.repairRTPBytes.Add(bytes)
		case header.Padding:
			p.probeRTPBytes.Add(bytes)
		default:
			p.mediaRTPBytes.Add(bytes)
		}
	}
	return n, err
}

// RecoveryDeadline bounds useful repair time from the first packet of a frame.
// RTT is a round trip; reserve half for the retransmission's outward transit.
// Unknown/stale receiver timing keeps the compatibility retention window.
func (p *packetPacer) RecoveryDeadline() (time.Duration, time.Duration) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.recoveryRTT <= 0 || time.Since(p.recoveryMeasured) < 0 || time.Since(p.recoveryMeasured) > 2*time.Second {
		return retransmissionAge, 0
	}
	frame := time.Second / time.Duration(max(1, p.recoveryFPS))
	return min(retransmissionAge, max(50*time.Millisecond, 2*p.recoveryRTT+2*frame)), p.recoveryRTT / 2
}
