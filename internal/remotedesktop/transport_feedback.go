package remotedesktop

import (
	"encoding/binary"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

const transportCCURI = "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
const transportHistorySize = 4096
const transportReferencePeriod = int64(1<<24) * 64000

type sentTransportPacket struct {
	sequence uint16
	sent     time.Time
	size     int
	probe    uint64
}
type probeAcknowledgments struct {
	count, bytes, firstSize   int
	firstSent, lastSent       time.Time
	firstArrival, lastArrival int64
	lost                      bool
}
type transportHealth struct {
	at             time.Time
	loss, growthMS float64
	deliveredRate  int
}

func (h transportHealth) congested() bool { return h.loss >= .02 || h.growthMS > 15 }
func (h transportHealth) fresh(now time.Time) bool {
	return !h.at.IsZero() && now.Sub(h.at) < 2*time.Second
}

type transportFeedbackFactory struct{ pacer *packetPacer }

func (f transportFeedbackFactory) NewInterceptor(string) (interceptor.Interceptor, error) {
	return &transportFeedbackInterceptor{pacer: f.pacer}, nil
}

type transportFeedbackInterceptor struct {
	interceptor.NoOp
	pacer *packetPacer
}

func (f *transportFeedbackInterceptor) BindLocalStream(info *interceptor.StreamInfo, writer interceptor.RTPWriter) interceptor.RTPWriter {
	for _, extension := range info.RTPHeaderExtensions {
		if extension.URI == transportCCURI && extension.ID > 0 && extension.ID < 256 {
			f.pacer.mu.Lock()
			f.pacer.transportID = uint8(extension.ID)
			f.pacer.mu.Unlock()
		}
	}
	return writer
}
func (f *transportFeedbackInterceptor) BindRTCPReader(reader interceptor.RTCPReader) interceptor.RTCPReader {
	return interceptor.RTCPReaderFunc(func(b []byte, a interceptor.Attributes) (int, interceptor.Attributes, error) {
		n, attributes, err := reader.Read(b, a)
		if err == nil {
			if packets, e := rtcp.Unmarshal(b[:n]); e == nil {
				for _, packet := range packets {
					if feedback, ok := packet.(*rtcp.TransportLayerCC); ok {
						f.pacer.observeTransport(time.Now(), feedback)
					}
				}
			}
		}
		return n, attributes, err
	})
}
func (p *packetPacer) recordTransport(now time.Time, h *rtp.Header, size int, probe uint64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	raw := h.GetExtension(p.transportID)
	if p.transportID == 0 || len(raw) != 2 {
		return
	}
	seq := binary.BigEndian.Uint16(raw)
	p.transportHistory[int(seq)%transportHistorySize] = sentTransportPacket{sequence: seq, sent: now, size: size, probe: probe}
}
func transportSpan(last, first int64) time.Duration {
	delta := last - first
	if delta < -transportReferencePeriod/2 {
		delta += transportReferencePeriod
	}
	if delta > transportReferencePeriod/2 {
		delta -= transportReferencePeriod
	}
	return time.Duration(delta) * time.Microsecond
}

// Only actual, recent packet acknowledgments can validate a recovery probe.
// The fixed ring tolerates TWCC sequence wrap and bounds every peer's history.
func (p *packetPacer) observeTransport(now time.Time, feedback *rtcp.TransportLayerCC) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if feedback.PacketStatusCount == 0 || int(feedback.PacketStatusCount) > transportHistorySize {
		return
	}
	seq, count, deltaIndex := feedback.BaseSequenceNumber, 0, 0
	arrival := int64(feedback.ReferenceTime) * 64000
	var window probeAcknowledgments
	known, lost := 0, 0
	visit := func(symbol uint16) {
		if count >= int(feedback.PacketStatusCount) {
			return
		}
		sequence := seq
		seq++
		count++
		received := symbol == rtcp.TypeTCCPacketReceivedSmallDelta || symbol == rtcp.TypeTCCPacketReceivedLargeDelta
		if received {
			if deltaIndex >= len(feedback.RecvDeltas) {
				return
			}
			arrival += feedback.RecvDeltas[deltaIndex].Delta
			deltaIndex++
		}
		packet := p.transportHistory[int(sequence)%transportHistorySize]
		if packet.sent.IsZero() || packet.sequence != sequence || now.Sub(packet.sent) > 2*time.Second {
			return
		}
		// Consuming the entry prevents duplicates/overlapping feedback from earning credit twice.
		p.transportHistory[int(sequence)%transportHistorySize] = sentTransportPacket{}
		known++
		if !received {
			lost++
			if packet.probe != 0 && packet.probe == p.probeID {
				p.probeACK.lost = true
			}
			return
		}
		window.add(packet, arrival)
		if packet.probe != 0 && packet.probe == p.probeID {
			p.probeACK.add(packet, arrival)
		}
	}
	for _, chunk := range feedback.PacketChunks {
		switch c := chunk.(type) {
		case *rtcp.RunLengthChunk:
			for i := 0; i < int(c.RunLength) && count < int(feedback.PacketStatusCount); i++ {
				visit(c.PacketStatusSymbol)
			}
		case *rtcp.StatusVectorChunk:
			for _, symbol := range c.SymbolList {
				visit(symbol)
			}
		}
	}
	if known == 0 {
		return
	}
	health := transportHealth{at: now, loss: float64(lost) / float64(known)}
	if window.count >= 2 {
		arrivalSpan := transportSpan(window.lastArrival, window.firstArrival)
		sendSpan := window.lastSent.Sub(window.firstSent)
		health.growthMS = float64(arrivalSpan-sendSpan) / float64(time.Millisecond)
		if arrivalSpan > 0 {
			health.deliveredRate = int(float64((window.bytes-window.firstSize)*8) / arrivalSpan.Seconds())
		}
	}
	p.transport = health
	if health.congested() {
		p.confirmedRate = 0
		p.probeBytes = 0
		p.probeACK.lost = true
		p.healthyUntil = time.Time{}
		return
	}
	if p.probeACK.lost {
		return
	}
	// Ordinary delivered media can also establish capacity. Use the slower of
	// send/arrival clocks and a meaningful interval, so ACK compression or one
	// tiny idle packet cannot manufacture bandwidth. Keep this proof across idle;
	// fresh loss/queue growth or receiver pressure revokes it above.
	span := max(transportSpan(window.lastArrival, window.firstArrival), window.lastSent.Sub(window.firstSent))
	if window.count >= 3 && span >= 20*time.Millisecond && now.Before(p.healthyUntil) {
		rate := int(float64((window.bytes-window.firstSize)*8) / span.Seconds() * .8)
		p.confirmedRate = max(p.confirmedRate, min(rate, max(p.bitrate, p.probeRate), p.probeCeiling))
	}
	a := p.probeACK
	if a.count < 3 || p.probeRate == 0 || now.Sub(p.lastProbe) > 2*time.Second || !now.Before(p.healthyUntil) {
		return
	}
	arrivalSpan := transportSpan(a.lastArrival, a.firstArrival)
	sendSpan := a.lastSent.Sub(a.firstSent)
	span = max(arrivalSpan, sendSpan)
	if span <= 0 || arrivalSpan-sendSpan > 15*time.Millisecond {
		return
	}
	delivered := int(float64((a.bytes-a.firstSize)*8) / span.Seconds())
	if delivered >= p.probeRate {
		p.confirmedRate = max(p.confirmedRate, p.probeRate)
	}
}
func (a *probeAcknowledgments) add(packet sentTransportPacket, arrival int64) {
	if a.count == 0 {
		a.firstSent = packet.sent
		a.firstArrival = arrival
		a.firstSize = packet.size
	}
	a.count++
	a.bytes += packet.size
	a.lastSent = packet.sent
	a.lastArrival = arrival
}
