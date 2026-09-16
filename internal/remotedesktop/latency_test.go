package remotedesktop

import (
	"bytes"
	"math"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
	"google.golang.org/protobuf/proto"
)

func TestImmediatePlayoutUsesOnlyNegotiatedExtension(t *testing.T) {
	for _, negotiated := range []bool{false, true} {
		info := &interceptor.StreamInfo{}
		if negotiated {
			info.RTPHeaderExtensions = []interceptor.RTPHeaderExtension{{URI: playoutDelayURI, ID: 7}}
		}
		writer := (&immediatePlayout{}).BindLocalStream(info, interceptor.RTPWriterFunc(func(h *rtp.Header, payload []byte, _ interceptor.Attributes) (int, error) {
			if got := h.GetExtension(7); negotiated != bytes.Equal(got, []byte{0, 0, 0}) {
				t.Fatalf("negotiated=%t extension=%v", negotiated, got)
			}
			if !bytes.Equal(h.GetExtension(3), []byte{1, 2}) {
				t.Fatal("playout extension overwrote TWCC")
			}
			return len(payload), nil
		}))
		h := &rtp.Header{Version: 2}
		if err := h.SetExtension(3, []byte{1, 2}); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(h, []byte{1}, nil); err != nil {
			t.Fatal(err)
		}
	}
}

func TestReceiverLatencyFeedbackIsValidatedAndExposed(t *testing.T) {
	s := &Session{inputEpoch: []byte("epoch"), status: &dieterv1.RemoteDesktopSessionState{}}
	feedback := &dieterv1.RemoteDesktopReceiverFeedback{ProtocolVersion: inputProtocolVersion, InputEpoch: s.inputEpoch, Sequence: 1, JitterBufferMs: 7, RenderMs: 11}
	raw, _ := proto.Marshal(feedback)
	s.receiveFeedback(raw)
	if s.status.JitterBufferMs != 7 || s.status.RenderMs != 11 {
		t.Fatal("receiver latency not exposed")
	}
	for i, invalid := range []float64{math.NaN(), math.Inf(1), -1, 10001} {
		feedback.Sequence = uint64(i + 2)
		feedback.RenderMs = invalid
		raw, _ = proto.Marshal(feedback)
		s.receiveFeedback(raw)
		if s.status.RenderMs != 11 {
			t.Fatal("invalid timing accepted")
		}
	}
}

func TestIdleProbeIsBoundedAndCongestionCancelsIt(t *testing.T) {
	p := newPacketPacer(4_000_000)
	defer p.Close()
	now := time.Now()
	p.EndFrame(now)
	p.ObserveNetwork(now, true)
	p.SetTargetBitrate(100_000)
	resume := now.Add(600 * time.Millisecond)
	p.BeginFrame(resume)
	if got := p.targetLocked(resume); got != 4_000_000 {
		t.Fatalf("idle resume rate: %d", got)
	}
	if got := p.targetLocked(resume.Add(251 * time.Millisecond)); got != 100_000 {
		t.Fatalf("unbounded probe: %d", got)
	}
	// A slow send is not an application idle interval.
	p.EndFrame(resume.Add(2 * time.Second))
	p.BeginFrame(resume.Add(2*time.Second + time.Millisecond))
	if p.probeBytes != 0 {
		t.Fatal("network backpressure re-armed idle probe")
	}
	// No route/address-based override: explicit congestion cancels any probe.
	p.probeBytes, p.probeRate, p.probeUntil = 65536, 4_000_000, resume.Add(time.Second)
	p.ObserveNetwork(resume, false)
	if got := p.targetLocked(resume); got != 100_000 {
		t.Fatalf("congestion ignored: %d", got)
	}
}

func TestIdleProbeByteBudgetAndStaleCapacity(t *testing.T) {
	p := newPacketPacer(100_000)
	defer p.Close()
	now := time.Now()
	p.recentRate, p.recentAt = 8_000_000, now
	p.lastFrameEnd, p.healthyUntil = now.Add(-time.Second), now.Add(time.Second)
	p.BeginFrame(now)
	p.AddStream(1, interceptor.RTPWriterFunc(func(_ *rtp.Header, payload []byte, _ interceptor.Attributes) (int, error) { return len(payload), nil }))
	for range 60 {
		if _, err := p.Write(&rtp.Header{Version: 2, SSRC: 1}, make([]byte, 1200), nil); err != nil {
			t.Fatal(err)
		}
	}
	if p.probeBytes != 0 || p.TargetBitrate() != 100_000 {
		t.Fatal("probe exceeded byte budget")
	}
	p.lastFrameEnd, p.lastProbe = now.Add(-time.Minute), time.Time{}
	p.recentAt = now.Add(-time.Minute)
	p.BeginFrame(now)
	if p.probeBytes != 0 {
		t.Fatal("stale capacity reused")
	}
}
