package remotedesktop

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

// packetPacer applies backpressure instead of accumulating a packet queue. The
// producer owns at most one encoded access unit and the helper replaces raw
// pending frames. Whole-frame admission/recovery happens before packetization.
type packetPacer struct {
	mu      sync.Mutex
	sendMu  sync.Mutex
	writers map[uint32]interceptor.RTPWriter
	bitrate int
	next    time.Time
	ctx     context.Context
	cancel  context.CancelFunc
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
	rate := p.bitrate
	p.mu.Unlock()
	if writer == nil {
		return 0, errors.New("pacer stream not registered")
	}
	if delay := time.Until(next); delay > 0 {
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
	p.next = time.Now().Add(time.Duration(float64(size*8) * float64(time.Second) / float64(max(100_000, rate))))
	p.mu.Unlock()
	return writer.Write(header, payload, attributes)
}
