package remotedesktop

import (
	"testing"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

func TestRecoveryRequiresActualBoundedAcknowledgments(t *testing.T) {
	for _, scenario := range []string{"healthy", "queued", "lost", "duplicate", "stale"} {
		t.Run(scenario, func(t *testing.T) {
			p := newPacketPacer(100000)
			defer p.Close()
			p.transportID = 3
			now := time.Now()
			p.ObserveNetwork(now, true)
			p.BeginFrame(now)
			for i := 0; i < 3; i++ {
				seq := uint16(65534 + i)
				h := &rtp.Header{Version: 2}
				ext, _ := (&rtp.TransportCCExtension{TransportSequence: seq}).Marshal()
				if err := h.SetExtension(3, ext); err != nil {
					t.Fatal(err)
				}
				p.recordTransport(now.Add(time.Duration(i)*20*time.Millisecond), h, 1250, p.probeID)
			}
			symbols := []uint16{rtcp.TypeTCCPacketReceivedSmallDelta, rtcp.TypeTCCPacketReceivedSmallDelta, rtcp.TypeTCCPacketReceivedSmallDelta}
			deltas := []*rtcp.RecvDelta{{Type: rtcp.TypeTCCPacketReceivedSmallDelta, Delta: 0}, {Type: rtcp.TypeTCCPacketReceivedSmallDelta, Delta: 20000}, {Type: rtcp.TypeTCCPacketReceivedSmallDelta, Delta: 20000}}
			if scenario == "queued" {
				for i := 1; i < 3; i++ {
					symbols[i] = rtcp.TypeTCCPacketReceivedLargeDelta
					deltas[i].Type = symbols[i]
					deltas[i].Delta = 150000
				}
			}
			if scenario == "lost" {
				symbols[1] = rtcp.TypeTCCPacketNotReceived
				deltas = deltas[:2]
			}
			feedback := &rtcp.TransportLayerCC{BaseSequenceNumber: 65534, PacketStatusCount: 3, ReferenceTime: 16, PacketChunks: []rtcp.PacketStatusChunk{&rtcp.StatusVectorChunk{SymbolSize: rtcp.TypeTCCSymbolSizeTwoBit, SymbolList: symbols}}, RecvDeltas: deltas}
			at := now.Add(400 * time.Millisecond)
			if scenario == "stale" {
				at = now.Add(3 * time.Second)
			}
			p.observeTransport(at, feedback)
			if scenario == "healthy" || scenario == "duplicate" {
				if p.TargetBitrate() != 200000 {
					t.Fatalf("acknowledged probe did not recover rate: %d", p.TargetBitrate())
				}
			} else if p.TargetBitrate() != 100000 {
				t.Fatal("unproven probe raised bandwidth")
			}
			if scenario == "duplicate" {
				count := p.probeACK.count
				p.observeTransport(at.Add(time.Millisecond), feedback)
				if p.probeACK.count != count {
					t.Fatal("duplicate feedback earned capacity twice")
				}
			}
		})
	}
}

func TestTransportReferenceWrapAndUnknownFeedback(t *testing.T) {
	if span := transportSpan(1000, transportReferencePeriod-1000); span != 2*time.Millisecond {
		t.Fatalf("reference wrap: %s", span)
	}
	p := newPacketPacer(100000)
	defer p.Close()
	p.observeTransport(time.Now(), &rtcp.TransportLayerCC{BaseSequenceNumber: 100, PacketStatusCount: 65535})
	if !p.transport.at.IsZero() || p.confirmedRate != 0 {
		t.Fatal("unknown or excessive feedback earned capacity")
	}
}

func TestCongestionRevokesOldProbeProofPermanently(t *testing.T) {
	p := newPacketPacer(100000)
	defer p.Close()
	now := time.Now()
	p.probeRate = 1000000
	p.confirmedRate = 1000000
	p.lastProbe = now
	p.probeACK = probeAcknowledgments{count: 3, bytes: 3000, firstSize: 1000, firstSent: now, lastSent: now.Add(time.Millisecond), firstArrival: 0, lastArrival: 1000}
	p.ObserveNetwork(now, false)
	p.ObserveNetwork(now.Add(time.Millisecond), true)
	p.transportHistory[10] = sentTransportPacket{sequence: 10, sent: now, size: 1000}
	p.observeTransport(now.Add(10*time.Millisecond), &rtcp.TransportLayerCC{BaseSequenceNumber: 10, PacketStatusCount: 1, ReferenceTime: 1, PacketChunks: []rtcp.PacketStatusChunk{&rtcp.RunLengthChunk{PacketStatusSymbol: rtcp.TypeTCCPacketReceivedSmallDelta, RunLength: 1}}, RecvDeltas: []*rtcp.RecvDelta{{Type: rtcp.TypeTCCPacketReceivedSmallDelta, Delta: 1000}}})
	if p.TargetBitrate() != 100000 {
		t.Fatal("new healthy feedback resurrected a revoked probe")
	}
}
