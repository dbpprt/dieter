package remotedesktop

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/interceptor/pkg/flexfec"
	"github.com/pion/rtp"
	"testing"
	"time"
)

func TestFECRepairsExactRTPAndBoundsWireOverhead(t *testing.T) {
	for _, percent := range []int{0, 10, 20} {
		t.Run(string(rune('a'+percent)), func(t *testing.T) {
			f := &fecStream{mediaSSRC: 7, encoder: flexfec.NewFlexEncoder03(118, 8)}
			now := time.Now()
			mediaBytes, repairBytes, repairs := 0, 0, 0
			for i := 0; i < 600; i++ {
				h := rtp.Header{Version: 2, SSRC: 7, SequenceNumber: uint16(65500 + i), Timestamp: uint32(i * 1500), PayloadType: 96, Marker: true}
				_ = h.SetExtension(3, []byte{byte(i >> 8), byte(i)})
				_ = h.SetExtension(4, []byte{0, 0, 0})
				payload := bytes.Repeat([]byte{byte(i)}, 50+i%1100)
				original, _ := (&rtp.Packet{Header: h, Payload: payload}).Marshal()
				mediaBytes += len(original) + 48
				for _, repair := range f.protect(now.Add(time.Duration(i)*time.Millisecond), &h, payload, percent) {
					repairs++
					repairBytes += repair.MarshalSize() + 48
					// Single-packet FlexFEC group: its repair payload is the exact packet
					// after the fixed RTP header. Validate wire bits, not an encoder mock.
					if len(repair.Payload) < 20 || binary.BigEndian.Uint16(repair.Payload[16:18]) != h.SequenceNumber {
						t.Fatal("wrong protected sequence")
					}
					restored := append([]byte(nil), original[:12]...)
					restored = append(restored, repair.Payload[20:]...)
					if !bytes.Equal(restored, original) {
						t.Fatal("FEC changed protected header extensions or pixels")
					}
				}
				if len(f.packets) != 0 {
					t.Fatal("frame marker retained a group")
				}
				if repairBytes*100 > mediaBytes*percent {
					t.Fatal("repair exceeded reserved wire-byte budget")
				}
			}
			if percent > 0 && repairs == 0 {
				t.Fatal("no repairs")
			}
		})
	}
}
func TestFECExpiresBlocksSkipsRetriesAndOwnsBytes(t *testing.T) {
	f := &fecStream{mediaSSRC: 7, encoder: flexfec.NewFlexEncoder03(118, 8)}
	h := rtp.Header{Version: 2, SSRC: 7, SequenceNumber: 1, Timestamp: 1, PayloadType: 96}
	p := []byte{1, 2, 3}
	now := time.Now()
	f.protect(now, &h, p, 20)
	p[0] = 9
	if f.packets[0].Payload[0] != 1 {
		t.Fatal("borrowed mutable payload")
	}
	f.protect(now, &h, p, 20)
	if len(f.packets) != 1 {
		t.Fatal("protected retransmission twice")
	}
	h.SequenceNumber = 2
	f.protect(now.Add(fecBlockAge+time.Millisecond), &h, p, 20)
	if len(f.packets) != 1 || f.packets[0].SequenceNumber != 2 {
		t.Fatal("retained expired group")
	}
	h.SequenceNumber = 3
	h.Timestamp = 2
	f.protect(now, &h, p, 20)
	if len(f.packets) != 1 || f.packets[0].Timestamp != 2 {
		t.Fatal("crossed frame boundary")
	}
	f.protect(now, &h, p, 0)
	if len(f.packets) != 0 || f.credit != 0 {
		t.Fatal("disabled protection retained state")
	}
}
func TestFECRequiresFreshLossAndWithdrawsOnQueueGrowth(t *testing.T) {
	now := time.Now()
	var c fecController
	rate := 0
	for i := 0; i < 25; i++ {
		at := now.Add(time.Duration(i) * 100 * time.Millisecond)
		rate = c.next(at, rate, transportHealth{at: at, packets: 8, span: 100 * time.Millisecond, loss: .04})
	}
	if rate != 20 {
		t.Fatalf("loss did not enable protection: %d", rate)
	}
	at := now.Add(3 * time.Second)
	rate = c.next(at, rate, transportHealth{at: at, packets: 8, span: 100 * time.Millisecond, loss: .04, growthMS: 20})
	if rate != 0 {
		t.Fatal("added repair to a growing queue")
	}
	if c.next(at.Add(2*time.Second), 20, transportHealth{at: at}) != 0 {
		t.Fatal("stale feedback retained protection")
	}
}
func TestFECReservesEncoderBudgetBeforeActivation(t *testing.T) {
	source := &fastTestSource{err: errors.New("configure failed")}
	p := newPacketPacer(10_000_000)
	defer p.Close()
	p.fecNegotiated.Store(true)
	now := time.Now()
	c := fecController{window: now.Add(-time.Second), packets: 80, lost: 4}
	s := &Session{source: source, pacer: p, ctx: context.Background(), applied: StreamConfiguration{BitrateKbps: 6000, FPS: 60}, status: &dieterv1.RemoteDesktopSessionState{Configuration: &dieterv1.RemoteDesktopStreamConfiguration{MaxBitrateKbps: 6000}}}
	h := transportHealth{at: now, packets: 8, span: 100 * time.Millisecond, loss: .04}
	s.adaptFEC(now, &c, h)
	if p.fecPercent.Load() != 0 || s.applied.BitrateKbps != 6000 {
		t.Fatal("enabled repair without encoder reserve")
	}
	source.err = nil
	c = fecController{window: now.Add(-time.Second), packets: 80, lost: 4}
	s.adaptFEC(now, &c, h)
	if p.fecPercent.Load() != 20 || s.applied.BitrateKbps != 5000 {
		t.Fatalf("budget not reserved: %d %+v", p.fecPercent.Load(), s.applied)
	}
}

func TestFECStopsAfterCleanFeedbackAndSevereLoss(t *testing.T) {
	for _, loss := range []float64{0, .20} {
		now := time.Now()
		var c fecController
		rate := 20
		for i := 0; i < 45; i++ {
			at := now.Add(time.Duration(i) * 100 * time.Millisecond)
			rate = c.next(at, rate, transportHealth{at: at, packets: 8, span: 100 * time.Millisecond, loss: loss})
		}
		if rate != 0 {
			t.Fatalf("loss %v retained repair %d", loss, rate)
		}
	}
}

func TestLiveConfigurationPreservesFECReserveAndEncoderFloor(t *testing.T) {
	source := &fastTestSource{}
	p := newPacketPacer(10_000_000)
	defer p.Close()
	p.fecPercent.Store(20)
	s := &Session{id: "test", source: source, pacer: p, status: &dieterv1.RemoteDesktopSessionState{}}
	manager := &Manager{sessions: map[string]*Session{s.id: s}}
	for _, ceiling := range []int32{6000, 100} {
		state, err := manager.UpdateSession(t.Context(), &dieterv1.UpdateRemoteDesktopSessionRequest{SessionId: s.id, Configuration: &dieterv1.RemoteDesktopStreamConfiguration{MaxBitrateKbps: ceiling}})
		if err != nil {
			t.Fatal(err)
		}
		want := int(ceiling)
		if ceiling == 6000 {
			want = 5000
		}
		if s.applied.BitrateKbps != want || state.Configuration.MaxBitrateKbps != ceiling {
			t.Fatalf("applied=%d ceiling=%d", s.applied.BitrateKbps, state.Configuration.MaxBitrateKbps)
		}
	}
	if p.fecPercent.Load() != 0 {
		t.Fatal("FEC exceeded the 100 kbps floor")
	}
}
