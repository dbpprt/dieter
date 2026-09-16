package remotedesktop

import (
	"context"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

const retransmissionPackets = 512
const retransmissionAge = 250 * time.Millisecond

type retransmissionFactory struct{ refresh func() }

func (f retransmissionFactory) NewInterceptor(string) (interceptor.Interceptor, error) {
	ctx, cancel := context.WithCancel(context.Background())
	value := &retransmissionInterceptor{ctx: ctx, cancel: cancel, streams: make(map[uint32]*retransmissionStream), pending: make(map[retransmissionKey]bool), requests: make(chan retransmissionKey, 64), refresh: f.refresh}
	go value.run()
	return value, nil
}

type retransmissionKey struct {
	ssrc     uint32
	sequence uint16
}
type cachedRTP struct {
	header   rtp.Header
	payload  []byte
	stored   time.Time
	attempts int
}
type retransmissionStream struct {
	packets [retransmissionPackets]*cachedRTP
	writer  interceptor.RTPWriter
}

// A single worker replaces per-NACK goroutines. Packet history, retry age,
// attempts and pending requests are all bounded; retransmits own their headers.
type retransmissionInterceptor struct {
	interceptor.NoOp
	mu       sync.Mutex
	streams  map[uint32]*retransmissionStream
	pending  map[retransmissionKey]bool
	requests chan retransmissionKey
	ctx      context.Context
	cancel   context.CancelFunc
	refresh  func()
}

func (r *retransmissionInterceptor) BindLocalStream(info *interceptor.StreamInfo, writer interceptor.RTPWriter) interceptor.RTPWriter {
	stream := &retransmissionStream{writer: writer}
	r.mu.Lock()
	if len(r.streams) >= 4 {
		r.mu.Unlock()
		return writer
	}
	r.streams[info.SSRC] = stream
	r.mu.Unlock()
	return interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, a interceptor.Attributes) (int, error) {
		if len(p) <= 2048 && h.MarshalSize() <= 256 {
			packet := &cachedRTP{header: h.Clone(), payload: append([]byte(nil), p...), stored: time.Now()}
			r.mu.Lock()
			stream.packets[int(h.SequenceNumber)%retransmissionPackets] = packet
			r.mu.Unlock()
		}
		return writer.Write(h, p, a)
	})
}
func (r *retransmissionInterceptor) UnbindLocalStream(info *interceptor.StreamInfo) {
	r.mu.Lock()
	delete(r.streams, info.SSRC)
	r.mu.Unlock()
}
func (r *retransmissionInterceptor) BindRTCPReader(reader interceptor.RTCPReader) interceptor.RTCPReader {
	return interceptor.RTCPReaderFunc(func(b []byte, a interceptor.Attributes) (int, interceptor.Attributes, error) {
		n, attributes, err := reader.Read(b, a)
		if err != nil {
			return n, attributes, err
		}
		packets, err := rtcp.Unmarshal(b[:n])
		if err != nil {
			return n, attributes, err
		}
		r.mu.Lock()
		for _, packet := range packets {
			if nack, ok := packet.(*rtcp.TransportLayerNack); ok {
				for _, pair := range nack.Nacks {
					pair.Range(func(sequence uint16) bool {
						key := retransmissionKey{nack.MediaSSRC, sequence}
						if r.pending[key] {
							return true
						}
						select {
						case r.requests <- key:
							r.pending[key] = true
						default:
							return false
						}
						return true
					})
				}
			}
		}
		r.mu.Unlock()
		return n, attributes, nil
	})
}
func (r *retransmissionInterceptor) run() {
	var lastRefresh time.Time
	for {
		select {
		case <-r.ctx.Done():
			return
		case key := <-r.requests:
			r.mu.Lock()
			delete(r.pending, key)
			stream := r.streams[key.ssrc]
			var packet *cachedRTP
			if stream != nil {
				packet = stream.packets[int(key.sequence)%retransmissionPackets]
			}
			valid := packet != nil && packet.header.SequenceNumber == key.sequence && time.Since(packet.stored) <= retransmissionAge && packet.attempts < 2
			var header rtp.Header
			if valid {
				packet.attempts++
				header = packet.header.Clone()
			}
			r.mu.Unlock()
			if valid {
				_, _ = stream.writer.Write(&header, packet.payload, nil)
			} else if r.refresh != nil && time.Since(lastRefresh) > 200*time.Millisecond {
				lastRefresh = time.Now()
				r.refresh()
			}
		}
	}
}
func (r *retransmissionInterceptor) Close() error { r.cancel(); return nil }
