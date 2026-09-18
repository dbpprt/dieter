package remotedesktop

import (
	"container/list"
	"context"
	"sync"
	"sync/atomic"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

// A time horizon alone is insufficient at high rates: 512 MTU packets retain
// less than 50 ms at 100 Mbps. Both limits apply across all SSRCs of a session.
const retransmissionPackets = 4096
const retransmissionBytes = 4 << 20
const retransmissionAge = 250 * time.Millisecond

type retransmissionFactory struct {
	refresh    func()
	deadline   func() (time.Duration, time.Duration)
	metrics    *recoveryMetrics
	generation func() uint64
}

type recoveryMetrics struct {
	hits, misses, evicted, expired, duplicate, packets, bytes atomic.Uint64
}

func (m *recoveryMetrics) snapshot() *dieterv1.RemoteDesktopRecoveryDiagnostics {
	return &dieterv1.RemoteDesktopRecoveryDiagnostics{HistoryHits: m.hits.Load(), HistoryMisses: m.misses.Load(),
		CapacityEvictions: m.evicted.Load(), ExpiredRepairs: m.expired.Load(), DuplicateRequests: m.duplicate.Load(),
		RetainedPackets: m.packets.Load(), RetainedBytes: m.bytes.Load()}
}

func (f retransmissionFactory) NewInterceptor(string) (interceptor.Interceptor, error) {
	ctx, cancel := context.WithCancel(context.Background())
	value := &retransmissionInterceptor{ctx: ctx, cancel: cancel, streams: make(map[uint32]*retransmissionStream), pending: make(map[retransmissionKey]bool), requests: make(chan retransmissionKey, 64), refresh: f.refresh, deadline: f.deadline}
	value.metrics = f.metrics
	value.generation = f.generation
	if value.metrics == nil {
		value.metrics = &recoveryMetrics{}
	}
	go value.run()
	return value, nil
}

type retransmissionKey struct {
	ssrc     uint32
	sequence uint16
}
type cachedRTP struct {
	header       rtp.Header
	payload      []byte
	stored       time.Time
	frameStarted time.Time
	attempts     int
	stream       *retransmissionStream
	element      *list.Element
	bytes        int
}
type retransmissionStream struct {
	packets       [retransmissionPackets]*cachedRTP
	padding       [retransmissionPackets]uint32 // sequence+1 tombstones survive payload eviction
	writer        interceptor.RTPWriter
	timestamp     uint32
	frameStarted  time.Time
	generation    uint64
	firstSequence uint16
	written       uint32
}

// A single worker replaces per-NACK goroutines. Packet history, retry age,
// attempts and pending requests are all bounded; retransmits own their headers.
type retransmissionInterceptor struct {
	interceptor.NoOp
	mu         sync.Mutex
	streams    map[uint32]*retransmissionStream
	pending    map[retransmissionKey]bool
	requests   chan retransmissionKey
	ctx        context.Context
	cancel     context.CancelFunc
	refresh    func()
	deadline   func() (time.Duration, time.Duration)
	history    list.List // oldest first, mu; never more than retransmissionPackets
	bytes      int
	metrics    *recoveryMetrics
	generation func() uint64
}

func (r *retransmissionInterceptor) currentGeneration() uint64 {
	if r.generation != nil {
		return r.generation()
	}
	return 0
}

// evict releases every retained reference. An in-progress retransmission may
// still own one immutable packet, bounded by the single repair worker.
func (r *retransmissionInterceptor) evict(packet *cachedRTP) {
	if packet == nil || packet.element == nil {
		return
	}
	r.history.Remove(packet.element)
	packet.element = nil
	r.bytes -= packet.bytes
	if r.metrics != nil {
		r.metrics.packets.Store(uint64(r.history.Len()))
		r.metrics.bytes.Store(uint64(r.bytes))
	}
	slot := int(packet.header.SequenceNumber) % retransmissionPackets
	if packet.stream.packets[slot] == packet {
		packet.stream.packets[slot] = nil
	}
}

func (r *retransmissionInterceptor) retain(stream *retransmissionStream, packet *cachedRTP) {
	slot := int(packet.header.SequenceNumber) % retransmissionPackets
	r.evict(stream.packets[slot])
	packet.stream = stream
	packet.bytes = packet.header.MarshalSize() + len(packet.payload)
	packet.element = r.history.PushBack(packet)
	stream.packets[slot] = packet
	r.bytes += packet.bytes
	for oldest := r.history.Front(); oldest != nil; oldest = r.history.Front() {
		value := oldest.Value.(*cachedRTP)
		if r.history.Len() <= retransmissionPackets && r.bytes <= retransmissionBytes && packet.stored.Sub(value.stored) <= retransmissionAge {
			break
		}
		r.evict(value)
		if r.metrics != nil && packet.stored.Sub(value.stored) <= retransmissionAge {
			r.metrics.evicted.Add(1)
		}
	}
	if r.metrics != nil {
		r.metrics.packets.Store(uint64(r.history.Len()))
		r.metrics.bytes.Store(uint64(r.bytes))
	}
}

func (r *retransmissionInterceptor) BindLocalStream(info *interceptor.StreamInfo, writer interceptor.RTPWriter) interceptor.RTPWriter {
	stream := &retransmissionStream{writer: writer}
	r.mu.Lock()
	if previous := r.streams[info.SSRC]; previous != nil {
		for _, packet := range previous.packets {
			r.evict(packet)
		}
		delete(r.streams, info.SSRC)
	}
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
			if generation := r.currentGeneration(); stream.generation != generation {
				for _, old := range stream.packets {
					r.evict(old)
				}
				stream.padding = [retransmissionPackets]uint32{}
				stream.generation, stream.firstSequence = generation, h.SequenceNumber
				stream.written = 0
				stream.frameStarted = time.Time{}
			}
			stream.written = min(32768, stream.written+1)
			if stream.frameStarted.IsZero() || stream.timestamp != h.Timestamp {
				stream.timestamp, stream.frameStarted = h.Timestamp, packet.stored
			}
			packet.frameStarted = stream.frameStarted
			// Ignore a write racing unbind; it must not resurrect history.
			if r.streams[info.SSRC] == stream {
				stream.padding[int(h.SequenceNumber)%retransmissionPackets] = 0
				if h.Padding {
					stream.padding[int(h.SequenceNumber)%retransmissionPackets] = uint32(h.SequenceNumber) + 1
				}
				r.retain(stream, packet)
			}
			r.mu.Unlock()
		}
		return writer.Write(h, p, a)
	})
}
func (r *retransmissionInterceptor) UnbindLocalStream(info *interceptor.StreamInfo) {
	r.mu.Lock()
	if stream := r.streams[info.SSRC]; stream != nil {
		for _, packet := range stream.packets {
			r.evict(packet)
		}
	}
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
							r.metrics.duplicate.Add(1)
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
			if stream == nil {
				r.mu.Unlock()
				continue
			}
			generation := stream.generation
			if generation != r.currentGeneration() || generation != 0 && stream.written < 32768 && int16(key.sequence-stream.firstSequence) < 0 {
				r.mu.Unlock()
				continue
			}
			var packet *cachedRTP
			if stream != nil {
				packet = stream.packets[int(key.sequence)%retransmissionPackets]
			}
			valid := packet != nil && packet.header.SequenceNumber == key.sequence && time.Since(packet.stored) <= retransmissionAge && packet.attempts < 2
			if packet == nil || packet.header.SequenceNumber != key.sequence {
				r.metrics.misses.Add(1)
			} else {
				r.metrics.hits.Add(1)
				if packet.attempts >= 2 {
					r.metrics.duplicate.Add(1)
				}
				if time.Since(packet.stored) > retransmissionAge || !r.repairUseful(packet, time.Now()) {
					r.metrics.expired.Add(1)
				}
			}
			if valid {
				valid = r.repairUseful(packet, time.Now())
			}
			padding := stream.padding[int(key.sequence)%retransmissionPackets] == uint32(key.sequence)+1
			var header rtp.Header
			if valid {
				packet.attempts++
				header = packet.header.Clone()
			}
			r.mu.Unlock()
			if valid {
				attributes := interceptor.Attributes{repairGenerationAttribute: generation}
				if r.deadline != nil {
					window, transit := r.deadline()
					attributes[repairDeadlineAttribute] = packet.frameStarted.Add(window - transit)
				}
				_, err := stream.writer.Write(&header, packet.payload, attributes)
				if err == errRepairExpired {
					r.metrics.expired.Add(1)
				}
				if err == errRepairExpired && generation == r.currentGeneration() && r.refresh != nil && r.refreshDue(lastRefresh) {
					lastRefresh = time.Now()
					r.refresh()
				}
			} else if !padding && generation == r.currentGeneration() && r.refresh != nil && r.refreshDue(lastRefresh) {
				lastRefresh = time.Now()
				r.refresh()
			}
		}
	}
}

func (r *retransmissionInterceptor) refreshDue(last time.Time) bool {
	interval := 200 * time.Millisecond
	if r.deadline != nil {
		window, _ := r.deadline()
		interval = min(interval, max(50*time.Millisecond, window))
	}
	return time.Since(last) >= interval
}
func (r *retransmissionInterceptor) Close() error {
	r.cancel()
	r.mu.Lock()
	for r.history.Front() != nil {
		r.evict(r.history.Front().Value.(*cachedRTP))
	}
	r.streams = make(map[uint32]*retransmissionStream)
	r.mu.Unlock()
	return nil
}

func (r *retransmissionInterceptor) repairUseful(packet *cachedRTP, now time.Time) bool {
	if r.deadline == nil {
		return true
	}
	window, transit := r.deadline()
	started := packet.frameStarted
	if started.IsZero() {
		started = packet.stored
	}
	return now.Add(transit).Before(started.Add(window))
}
