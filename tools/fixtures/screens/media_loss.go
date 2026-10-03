package main

import (
	"encoding/binary"
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
	"sync"
	"time"
)

// Drops only the disposable fixture's outgoing video, below parity generation
// and retransmission. Control/signaling are unaffected. No system network edits.
type heldMedia struct {
	timer      *time.Timer
	header     rtp.Header
	payload    []byte
	writer     interceptor.RTPWriter
	attributes interceptor.Attributes
}
type mediaLoss struct {
	held                   *heldMedia
	repairedTimestamp      uint32
	mu                     sync.Mutex
	mode                   string
	media, repair, dropped uint64
	timestamp              uint32
	armed                  bool
	missing                map[uint64]time.Time
}

func newMediaLoss() *mediaLoss { return &mediaLoss{missing: make(map[uint64]time.Time)} }
func (l *mediaLoss) NewInterceptor(string) (interceptor.Interceptor, error) {
	return &lossInterceptor{loss: l}, nil
}
func (l *mediaLoss) configure(mode string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.held != nil {
		l.held.timer.Stop()
		l.held = nil
	}
	l.mode = mode
	l.repairedTimestamp = 0
	l.media = 0
	l.repair = 0
	l.dropped = 0
	l.timestamp = 0
	l.armed = false
	l.missing = make(map[uint64]time.Time)
}
func (l *mediaLoss) snapshot() map[string]any {
	l.mu.Lock()
	defer l.mu.Unlock()
	return map[string]any{"mode": l.mode, "media": l.media, "repair": l.repair, "dropped": l.dropped, "repairedTimestamp": l.repairedTimestamp}
}

type lossInterceptor struct {
	interceptor.NoOp
	loss *mediaLoss
}

func (f *lossInterceptor) BindLocalStream(info *interceptor.StreamInfo, writer interceptor.RTPWriter) interceptor.RTPWriter {
	return interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, a interceptor.Attributes) (int, error) {
		l := f.loss
		l.mu.Lock()
		var flush *heldMedia
		if l.held != nil {
			held := l.held
			if held.timer != nil {
				held.timer.Stop()
			}
			l.held = nil
			diff := uint16(held.header.SequenceNumber - binaryBase(p))
			if h.SSRC == info.SSRCForwardErrorCorrection && len(p) >= 20 && diff < 15 && binary.BigEndian.Uint16(p[18:20])&(1<<(14-diff)) != 0 {
				l.dropped++
				l.repairedTimestamp = held.header.Timestamp
				l.mode = "proof-complete"
				l.missing[uint64(held.header.SSRC)<<16|uint64(held.header.SequenceNumber)] = time.Now()
			} else {
				flush = held
			}
		}
		drop := false
		hold := false
		if h.SSRC == info.SSRCForwardErrorCorrection {
			l.repair++
		} else if h.SSRC == info.SSRC && !h.Padding {
			l.media++
			switch l.mode {
			case "fec-proof":
				if h.Marker && len(p) <= 1500 {
					l.held = &heldMedia{header: h.Clone(), payload: append([]byte(nil), p...), writer: writer, attributes: a}
					hold = true
					held := l.held
					// Parity is paced after media. Four milliseconds can expire
					// before a repair packet is serialized on a reduced bitrate,
					// making a real protected packet impossible to select. Bound
					// this one fixture-only packet by the repair-history horizon.
					held.timer = time.AfterFunc(250*time.Millisecond, func() {
						l.mu.Lock()
						valid := l.held == held
						if valid {
							l.held = nil
						}
						l.mu.Unlock()
						if valid {
							_, _ = held.writer.Write(&held.header, held.payload, held.attributes)
						}
					})
				}
			case "proof-complete":
				_, drop = l.missing[uint64(h.SSRC)<<16|uint64(h.SequenceNumber)]
			case "burst":
				if !l.armed {
					l.armed = true
					l.timestamp = h.Timestamp
				}
				drop = h.Timestamp == l.timestamp
			case "random":
				drop = l.media%25 == 0

			}
		}
		if drop {
			l.dropped++
		}
		l.mu.Unlock()
		if flush != nil {
			if _, err := flush.writer.Write(&flush.header, flush.payload, flush.attributes); err != nil {
				return 0, err
			}
		}
		if drop || hold {
			return h.MarshalSize() + len(p), nil
		}
		return writer.Write(h, p, a)
	})
}

func (f *lossInterceptor) Close() error {
	f.loss.mu.Lock()
	defer f.loss.mu.Unlock()
	if f.loss.held != nil {
		f.loss.held.timer.Stop()
		f.loss.held = nil
	}
	return nil
}

func binaryBase(p []byte) uint16 {
	if len(p) < 20 {
		return 0
	}
	return binary.BigEndian.Uint16(p[16:18])
}
