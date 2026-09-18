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

func TestRTPTrafficCountersSeparatePayloadClassesAndExcludeFailedWrites(t *testing.T) {
	p := newPacketPacer(100_000_000)
	defer p.Close()
	p.AddStream(1, interceptor.RTPWriterFunc(func(h *rtp.Header, b []byte, _ interceptor.Attributes) (int, error) {
		return h.MarshalSize() + len(b) + int(h.PaddingSize), nil
	}))
	header := &rtp.Header{Version: 2, SSRC: 1}
	for _, attributes := range []interceptor.Attributes{nil, {fecPacketAttribute: true}, {repairDeadlineAttribute: time.Now().Add(time.Second)}} {
		if _, err := p.Write(header, make([]byte, 100), attributes); err != nil {
			t.Fatal(err)
		}
	}
	header.Padding, header.PaddingSize = true, 255
	if _, err := p.Write(header, nil, nil); err != nil {
		t.Fatal(err)
	}
	if p.mediaRTPBytes.Load() != 112 || p.fecRTPBytes.Load() != 112 || p.repairRTPBytes.Load() != 112 || p.probeRTPBytes.Load() != 267 {
		t.Fatal("RTP classes or byte units changed")
	}
	if _, err := p.Write(header, nil, interceptor.Attributes{repairDeadlineAttribute: time.Now().Add(-time.Second)}); err != errRepairExpired || p.repairRTPBytes.Load() != 112 {
		t.Fatal("expired repair counted as sent")
	}
}

func TestReceiverLatencyFeedbackIsValidatedAndExposed(t *testing.T) {
	s := &Session{inputEpoch: []byte("epoch"), status: &dieterv1.RemoteDesktopSessionState{}}
	feedback := &dieterv1.RemoteDesktopReceiverFeedback{ProtocolVersion: inputProtocolVersion, InputEpoch: s.inputEpoch, Sequence: 1, JitterBufferMs: 7, RenderMs: 11}
	feedback.RenderMeasurement = dieterv1.RemoteDesktopRenderMeasurement_REMOTE_DESKTOP_RENDER_MEASUREMENT_EGL_SUBMITTED
	feedback.DecoderImplementation = "actual.codec"
	feedback.DecoderHardware = proto.Bool(true)
	feedback.DecoderLowLatencyAccepted = proto.Bool(false)
	raw, _ := proto.Marshal(feedback)
	s.receiveFeedback(raw)
	if s.status.JitterBufferMs != 7 || s.status.RenderMs != 11 {
		t.Fatal("receiver latency not exposed")
	}
	if s.status.RenderMeasurement != feedback.RenderMeasurement || s.status.DecoderImplementation != "actual.codec" ||
		s.status.DecoderHardware == nil || !*s.status.DecoderHardware || s.status.DecoderLowLatencyAccepted == nil || *s.status.DecoderLowLatencyAccepted {
		t.Fatal("endpoint or explicit false decoder capability lost")
	}
	for i, invalid := range []float64{math.NaN(), math.Inf(1), -1, 10001} {
		before := s.lastFeedback
		measuredAt := s.receiverMeasuredAt
		feedback.Sequence = uint64(i + 2)
		feedback.RenderMs = invalid
		raw, _ = proto.Marshal(feedback)
		s.receiveFeedback(raw)
		if s.status.RenderMs != 11 {
			t.Fatal("invalid timing accepted")
		}
		if !s.lastFeedback.After(before) || s.feedbackSequence.Load() != feedback.Sequence {
			t.Fatal("invalid optional statistics suppressed an authenticated heartbeat")
		}
		if !s.receiverMeasuredAt.Equal(measuredAt) {
			t.Fatal("invalid statistics refreshed the measurement timestamp")
		}
	}
	before := s.lastFeedback
	feedback.InputEpoch = []byte("different-session")
	feedback.Sequence++
	feedback.RenderMs = 11
	raw, _ = proto.Marshal(feedback)
	s.receiveFeedback(raw)
	if !s.lastFeedback.Equal(before) {
		t.Fatal("wrong-epoch heartbeat was accepted")
	}
}

func TestRecoveryProbeIsBoundedAndCongestionCancelsIt(t *testing.T) {
	p := newPacketPacer(100000)
	defer p.Close()
	p.transportID = 3
	now := time.Now()
	p.EndFrame(now.Add(-time.Minute))
	p.ObserveNetwork(now, true)
	p.BeginFrame(now)
	if p.probeBytes == 0 || p.targetLocked(now) != 200000 {
		t.Fatal("long idle did not permit a bounded recovery probe")
	}
	if p.TargetBitrate() != 100000 {
		t.Fatal("unacknowledged probe raised encoder budget")
	}
	if got := p.targetLocked(now.Add(251 * time.Millisecond)); got != 100000 {
		t.Fatalf("probe exceeded time budget: %d", got)
	}
	p.ObserveNetwork(now, false)
	if p.confirmedRate != 0 || p.probeBytes != 0 {
		t.Fatal("congestion did not cancel recovery")
	}
	p.BeginFrame(now.Add(time.Second))
	if p.probeBytes != 0 {
		t.Fatal("probe bypassed feedback/cooldown")
	}
}

func TestRecoveryProbeByteBudget(t *testing.T) {
	p := newPacketPacer(100000)
	defer p.Close()
	p.transportID = 3
	now := time.Now()
	p.ObserveNetwork(now, true)
	p.BeginFrame(now)
	if p.probeBytes > 64<<10 {
		t.Fatal("unbounded byte budget")
	}
	p.AddStream(1, interceptor.RTPWriterFunc(func(_ *rtp.Header, payload []byte, _ interceptor.Attributes) (int, error) { return len(payload), nil }))
	for range 4 {
		if _, err := p.Write(&rtp.Header{Version: 2, SSRC: 1}, make([]byte, 1200), nil); err != nil {
			t.Fatal(err)
		}
	}
	if p.probeBytes != 0 || p.TargetBitrate() != 100000 {
		t.Fatal("probe exceeded budget or bypassed acknowledgment")
	}
}

func TestReceiverMeasurementAgeIsIndependentOfHeartbeat(t *testing.T) {
	s := &Session{inputEpoch: []byte("epoch"), status: &dieterv1.RemoteDesktopSessionState{}}
	value := &dieterv1.RemoteDesktopReceiverFeedback{ProtocolVersion: inputProtocolVersion, InputEpoch: s.inputEpoch, Sequence: 1, MeasurementSequence: 2, MeasurementAgeMs: 1500, DecodeMs: 4}
	raw, _ := proto.Marshal(value)
	s.receiveFeedback(raw)
	first := s.receiverMeasuredAt
	if age := time.Since(first); age < 1500*time.Millisecond || age > 1600*time.Millisecond {
		t.Fatalf("sample age not retained: %s", age)
	}
	value.Sequence = 2
	value.MeasurementAgeMs = 2000
	raw, _ = proto.Marshal(value)
	s.receiveFeedback(raw)
	if !s.receiverMeasuredAt.Equal(first) || s.lastFeedback.Before(first.Add(1500*time.Millisecond)) {
		t.Fatal("heartbeat refreshed the statistics timestamp")
	}
	value.Sequence = 3
	value.MeasurementSequence = 3
	value.MeasurementAgeMs = 0
	raw, _ = proto.Marshal(value)
	s.receiveFeedback(raw)
	if time.Since(s.receiverMeasuredAt) > 100*time.Millisecond {
		t.Fatal("new measurement did not refresh statistics")
	}
}
