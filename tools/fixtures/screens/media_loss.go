package main

import (
	"encoding/binary"
	"fmt"
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
	started    time.Time
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
	proofTrace             []string
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
	l.proofTrace = nil
	l.missing = make(map[uint64]time.Time)
}
func (l *mediaLoss) snapshot() map[string]any {
	l.mu.Lock()
	defer l.mu.Unlock()
	return map[string]any{"mode": l.mode, "media": l.media, "repair": l.repair, "dropped": l.dropped, "repairedTimestamp": l.repairedTimestamp, "proofTrace": append([]string(nil), l.proofTrace...)}
}

// Keep packet diagnostics bounded and credential-free. Native failure evidence
// needs the actual protected range and hold age, not only aggregate loss.
func (l *mediaLoss) trace(format string, values ...any) {
	if len(l.proofTrace) >= 64 {
		copy(l.proofTrace, l.proofTrace[1:])
		l.proofTrace = l.proofTrace[:63]
	}
	l.proofTrace = append(l.proofTrace, fmt.Sprintf(format, values...))
}

type lossInterceptor struct {
	interceptor.NoOp
	loss *mediaLoss
}

func (f *lossInterceptor) BindLocalStream(info *interceptor.StreamInfo, writer interceptor.RTPWriter) interceptor.RTPWriter {
	// Sequence history survives fault-mode changes. A retransmission from
	// the preceding random-loss interval is never eligible for fresh parity.
	var latest uint16
	var seen bool
	return interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, a interceptor.Attributes) (int, error) {
		l := f.loss
		l.mu.Lock()
		var release *heldMedia
		if l.held != nil && h.SSRC == info.SSRCForwardErrorCorrection {
			held := l.held
			if len(p) >= 20 {
				l.trace("parity base=%d mask=%04x candidate=%d ts=%d age_ms=%d", binaryBase(p), binary.BigEndian.Uint16(p[18:20]), held.header.SequenceNumber, held.header.Timestamp, time.Since(held.started).Milliseconds())
			}
			diff := uint16(held.header.SequenceNumber - binaryBase(p))
			if len(p) >= 20 && diff < 15 && binary.BigEndian.Uint16(p[18:20])&(1<<(14-diff)) != 0 {
				if held.timer != nil {
					held.timer.Stop()
				}
				l.held = nil
				l.dropped++
				l.repairedTimestamp = held.header.Timestamp
				l.mode = "proof-complete"
				l.trace("discard original seq=%d ts=%d", held.header.SequenceNumber, held.header.Timestamp)
				l.missing[uint64(held.header.SSRC)<<16|uint64(held.header.SequenceNumber)] = time.Now()
			} else if len(p) >= 20 && int16(binaryBase(p)-held.header.SequenceNumber) > 0 {
				// Protection never spans frames. A newer repair group proves
				// this candidate was not protected; release it and try the
				// next media packet instead of repeatedly holding the same
				// unprotected position in the repair-credit cycle.
				held.timer.Stop()
				l.held = nil
				release = held
			}
		}
		drop := false
		hold := false
		if h.SSRC == info.SSRCForwardErrorCorrection {
			l.repair++
		} else if h.SSRC == info.SSRC && !h.Padding {
			l.media++
			fresh := !seen || int16(h.SequenceNumber-latest) > 0
			if fresh {
				latest, seen = h.SequenceNumber, true
			}
			switch l.mode {
			case "fec-proof":
				if l.held != nil && h.SSRC == l.held.header.SSRC && h.SequenceNumber == l.held.header.SequenceNumber {
					drop = true // A retransmission must not reveal the held original.
				} else if fresh && len(p) <= 1500 {
					// The real sender emits parity immediately after the final
					// packet in a protected group. Keep that newest candidate;
					// retaining an unprotected earlier packet across the group
					// creates artificial decoder dependencies and misses parity.
					if l.held != nil {
						l.held.timer.Stop()
						release = l.held
					}
					l.held = &heldMedia{header: h.Clone(), payload: append([]byte(nil), p...), writer: writer, attributes: a, started: time.Now()}
					l.trace("hold seq=%d ts=%d marker=%t size=%d", h.SequenceNumber, h.Timestamp, h.Marker, len(p))
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
							l.trace("expired seq=%d ts=%d", held.header.SequenceNumber, held.header.Timestamp)
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
		if release != nil {
			if _, err := release.writer.Write(&release.header, release.payload, release.attributes); err != nil {
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
