package remotedesktop

import (
	"context"
	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/flexfec"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
	"time"
)

// Repair is negotiated independently of the video codec. Generate parity after
// every media header extension is final; changing a protected header afterwards
// makes recovered packets corrupt. Parity has its own SSRC and no TWCC extension.
const fecPayloadType = 118
const fecBlockAge = 20 * time.Millisecond

type fecBindingFactory struct{ pacer *packetPacer }

func (f fecBindingFactory) NewInterceptor(string) (interceptor.Interceptor, error) {
	return &fecBinding{pacer: f.pacer}, nil
}

type fecBinding struct {
	interceptor.NoOp
	pacer *packetPacer
}

func (f *fecBinding) BindLocalStream(info *interceptor.StreamInfo, writer interceptor.RTPWriter) interceptor.RTPWriter {
	if info.SSRCForwardErrorCorrection != 0 && info.PayloadTypeForwardErrorCorrection != 0 {
		f.pacer.sendMu.Lock()
		f.pacer.fec = &fecStream{mediaSSRC: info.SSRC, encoder: flexfec.NewFlexEncoder03(info.PayloadTypeForwardErrorCorrection, info.SSRCForwardErrorCorrection), writer: writer}
		f.pacer.sendMu.Unlock()
		f.pacer.fecNegotiated.Store(true)
	}
	return writer
}
func registerFEC(engine *webrtc.MediaEngine) error {
	return engine.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypeFlexFEC03, ClockRate: 90000, SDPFmtpLine: "repair-window=10000000",
	}, PayloadType: fecPayloadType}, webrtc.RTPCodecTypeVideo)
}

type fecStream struct {
	mediaSSRC uint32
	encoder   *flexfec.FlexEncoder03
	writer    interceptor.RTPWriter
	packets   []rtp.Packet
	started   time.Time
	credit    int // hundredths of a wire byte; bounded to one repair packet
	last      uint16
	seen      bool
}

// No media is delayed waiting for a repair group. Flush on the frame marker,
// sequence gap, size limit, or deadline; never retain one frame into the next.
func (f *fecStream) protect(now time.Time, header *rtp.Header, payload []byte, percent int) []rtp.Packet {
	if header.SSRC != f.mediaSSRC {
		return nil
	}
	if percent == 0 {
		f.packets = nil
		f.credit = 0
		f.seen = false
		return nil
	}
	if f.seen && int16(header.SequenceNumber-f.last) <= 0 {
		return nil
	} // retransmission
	if header.Padding || len(payload) == 0 {
		f.packets = nil
		f.last = header.SequenceNumber
		f.seen = true
		return nil
	}
	if len(f.packets) > 0 && (header.SequenceNumber != f.last+1 || header.Timestamp != f.packets[0].Timestamp || now.Sub(f.started) > fecBlockAge) {
		f.packets = nil
	}
	f.last, f.seen = header.SequenceNumber, true
	if len(f.packets) == 0 {
		f.started = now
	}
	packet := (&rtp.Packet{Header: *header, Payload: payload}).Clone()
	f.packets = append(f.packets, *packet)
	f.credit = min(1500*100, f.credit+(packet.MarshalSize()+48)*percent)
	group := 12
	if percent >= 20 {
		group = 6
	}
	if !header.Marker && len(f.packets) < group {
		return nil
	}
	packets := f.encoder.EncodeFec(f.packets, 1)
	f.packets = nil
	if len(packets) != 1 {
		return nil
	}
	cost := (packets[0].MarshalSize() + 48) * 100
	if cost > f.credit {
		return nil
	}
	f.credit -= cost
	return packets
}

// Loss with growing queues calls for less traffic. Only repeated fresh loss
// without queue growth enables parity. Clean/stale feedback removes overhead.
// This is deliberately conservative; it never changes resolution or cadence.
type fecController struct {
	observed, window, cleanAt time.Time
	packets                   int
	lost                      float64
}

func (c *fecController) next(now time.Time, current int, h transportHealth) int {
	if !h.fresh(now) || now.Sub(h.at) > time.Second {
		c.window = time.Time{}
		c.packets = 0
		c.lost = 0
		return 0
	}
	if !h.at.After(c.observed) {
		return current
	}
	c.observed = h.at
	if h.growthMS > 15 {
		c.window = time.Time{}
		c.packets = 0
		c.lost = 0
		c.cleanAt = time.Time{}
		return 0
	}
	if h.packets < 3 || h.span < 20*time.Millisecond {
		return current
	}
	if c.window.IsZero() {
		c.window = now
	}
	c.packets += h.packets
	c.lost += h.loss * float64(h.packets)
	if now.Sub(c.window) < time.Second {
		return current
	}
	packets, lost := c.packets, c.lost
	c.window = now
	c.packets = 0
	c.lost = 0
	if packets < 30 {
		return current
	}
	loss := lost / float64(packets)
	if loss > .08 {
		c.cleanAt = time.Time{}
		return 0
	}
	desired := 0
	if loss >= .005 {
		desired = 10
	}
	if loss >= .025 {
		desired = 20
	}
	if desired == 0 {
		if c.cleanAt.IsZero() {
			c.cleanAt = now
		}
		if now.Sub(c.cleanAt) >= 2*time.Second {
			return 0
		}
		return current
	}
	c.cleanAt = time.Time{}
	return desired
}

func fecMediaBudget(total, percent int) int { return max(100, total*100/(100+percent)) }

// Reserve repair bytes before enabling redundancy, including when the encoder
// is already at the user ceiling. Failed configuration leaves protection off.
func (s *Session) adaptFEC(now time.Time, controller *fecController, h transportHealth) {
	if !s.pacer.fecNegotiated.Load() {
		return
	}
	previous := int(s.pacer.fecPercent.Load())
	desired := controller.next(now, previous, h)
	if desired <= previous {
		s.pacer.fecPercent.Store(int64(desired))
		return
	}
	source, ok := s.source.(AdaptiveFrameSource)
	if !ok {
		return
	}
	s.configurationMu.Lock()
	defer s.configurationMu.Unlock()
	s.mu.Lock()
	current := s.applied
	limit := int(s.status.GetConfiguration().GetMaxBitrateKbps())
	closed := s.closed
	s.mu.Unlock()
	if closed || current.BitrateKbps <= 100 {
		return
	}
	total := receiverBudget(now, limit, s.pacer.TargetBitrate(), int(s.remb.Load()), s.rembAt.Load())
	config := current
	config.BitrateKbps = min(fecMediaBudget(total, desired), current.BitrateKbps*(100+previous)/(100+desired))
	if config.BitrateKbps < 100 {
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, time.Second)
	err := source.Configure(ctx, config)
	cancel()
	if err != nil {
		return
	}
	s.mu.Lock()
	s.applied = config
	s.mu.Unlock()
	s.pacer.fecPercent.Store(int64(desired))
}
