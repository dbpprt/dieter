package remotedesktop

import (
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

func TestRepairCannotCrossDisplayGenerationOrResurrectExpiredChain(t *testing.T) {
	var generation atomic.Uint64
	generation.Store(1)
	var refresh atomic.Int32
	repaired := make(chan uint16, 4)
	v, err := (retransmissionFactory{generation: generation.Load, refresh: func() { refresh.Add(1) }}).NewInterceptor("test")
	if err != nil {
		t.Fatal(err)
	}
	r := v.(*retransmissionInterceptor)
	defer r.Close()
	w := r.BindLocalStream(&interceptor.StreamInfo{SSRC: 1}, interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, a interceptor.Attributes) (int, error) {
		if _, ok := a[repairGenerationAttribute]; ok {
			repaired <- h.SequenceNumber
		}
		return len(p), nil
	}))
	write := func(sequence uint16) {
		t.Helper()
		if _, err := w.Write(&rtp.Header{Version: 2, SSRC: 1, SequenceNumber: sequence}, []byte{1}, nil); err != nil {
			t.Fatal(err)
		}
	}
	write(65534)
	generation.Store(2)
	write(65535)
	write(0)
	r.requests <- retransmissionKey{1, 65534}
	r.requests <- retransmissionKey{1, 0}
	select {
	case sequence := <-repaired:
		if sequence != 0 || refresh.Load() != 0 {
			t.Fatal("old generation triggered repair or refresh")
		}
	case <-time.After(time.Second):
		t.Fatal("new generation repair missing at sequence wrap")
	}
	// The same generation may emit more than half a sequence space. Its
	// initial-boundary guard must not reject legitimate wrapped requests.
	r.mu.Lock()
	r.streams[1].written = 32768
	r.mu.Unlock()
	write(40000)
	r.requests <- retransmissionKey{1, 40000}
	select {
	case sequence := <-repaired:
		if sequence != 40000 {
			t.Fatal(sequence)
		}
	case <-time.After(time.Second):
		t.Fatal("long-running generation lost repairs")
	}
	p := newPacketPacer(1000000)
	defer p.Close()
	p.mediaGeneration.Store(2)
	if _, err := p.Write(&rtp.Header{SSRC: 1}, []byte{1}, interceptor.Attributes{repairGenerationAttribute: uint64(1)}); err != errRepairObsolete {
		t.Fatal("pacer accepted obsolete repair", err)
	}
}

func TestExpiredProbePaddingDoesNotRequestKeyframe(t *testing.T) {
	refresh := make(chan struct{}, 2)
	value, err := (retransmissionFactory{refresh: func() { refresh <- struct{}{} }}).NewInterceptor("test")
	if err != nil {
		t.Fatal(err)
	}
	r := value.(*retransmissionInterceptor)
	defer r.Close()
	writer := r.BindLocalStream(&interceptor.StreamInfo{SSRC: 1}, interceptor.RTPWriterFunc(func(_ *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) { return len(p), nil }))
	for _, h := range []*rtp.Header{{Version: 2, SSRC: 1, SequenceNumber: 1, Padding: true, PaddingSize: 255}, {Version: 2, SSRC: 1, SequenceNumber: 2}} {
		if _, err := writer.Write(h, nil, nil); err != nil {
			t.Fatal(err)
		}
		r.mu.Lock()
		r.streams[1].packets[int(h.SequenceNumber)].stored = time.Now().Add(-time.Second)
		r.mu.Unlock()
	}
	r.requests <- retransmissionKey{ssrc: 1, sequence: 1}
	select {
	case <-refresh:
		t.Fatal("lost probe padding requested a wasteful keyframe")
	case <-time.After(50 * time.Millisecond):
	}
	r.requests <- retransmissionKey{ssrc: 1, sequence: 2}
	select {
	case <-refresh:
	case <-time.After(time.Second):
		t.Fatal("lost video did not request a keyframe")
	}
}

func TestRepairHistoryBoundsBytesAcrossStreamsAndRetainsHighRateWindow(t *testing.T) {
	r := &retransmissionInterceptor{streams: make(map[uint32]*retransmissionStream)}
	now := time.Now()
	for ssrc := uint32(1); ssrc <= 4; ssrc++ {
		stream := &retransmissionStream{}
		r.streams[ssrc] = stream
		for sequence := 0; sequence < 1200; sequence++ {
			r.retain(stream, &cachedRTP{header: rtp.Header{Version: 2, SSRC: ssrc, SequenceNumber: uint16(sequence)}, payload: make([]byte, 1200), stored: now})
			if r.bytes > retransmissionBytes || r.history.Len() > retransmissionPackets {
				t.Fatal("history exceeded the session-wide bound")
			}
		}
	}
	if r.streams[4].packets[0] == nil {
		t.Fatal("high-rate history still limited to 512 packets")
	}
	r.UnbindLocalStream(&interceptor.StreamInfo{SSRC: 4})
	for e := r.history.Front(); e != nil; e = e.Next() {
		if e.Value.(*cachedRTP).header.SSRC == 4 {
			t.Fatal("unbound stream retained payload")
		}
	}
	stream := r.streams[1]
	r.retain(stream, &cachedRTP{header: rtp.Header{Version: 2, SSRC: 1, SequenceNumber: 65535}, payload: []byte{1}, stored: now.Add(time.Second)})
	if r.history.Len() != 1 {
		t.Fatal("expired payload retained")
	}
	r.retain(stream, &cachedRTP{header: rtp.Header{Version: 2, SSRC: 1, SequenceNumber: 0}, payload: []byte{2}, stored: now.Add(time.Second)})
	if r.history.Len() != 2 || stream.packets[0].payload[0] != 2 {
		t.Fatal("sequence wrap corrupted history")
	}
}

func TestPacerDoesNotTransmitRepairAfterQueueDeadline(t *testing.T) {
	p := newPacketPacer(100000)
	defer p.Close()
	p.next = time.Now().Add(time.Second)
	wrote := false
	writer := interceptor.RTPWriterFunc(func(_ *rtp.Header, _ []byte, _ interceptor.Attributes) (int, error) { wrote = true; return 1, nil })
	_, err := p.writePacket(&rtp.Header{Version: 2}, []byte{1}, interceptor.Attributes{repairDeadlineAttribute: time.Now().Add(10 * time.Millisecond)}, writer)
	if err != errRepairExpired || wrote {
		t.Fatalf("obsolete repair transmitted: %v, %v", err, wrote)
	}
}

func TestRecoveryRTTUsesFreshNominatedConsentOnly(t *testing.T) {
	now := time.Now()
	timestamp := func(at time.Time) webrtc.StatsTimestamp {
		return webrtc.StatsTimestamp(float64(at.UnixNano()) / float64(time.Millisecond))
	}
	pair := webrtc.ICECandidatePairStats{Nominated: true, State: webrtc.StatsICECandidatePairStateSucceeded, CurrentRoundTripTime: .004, LastResponseTimestamp: timestamp(now.Add(-time.Millisecond))}
	rtt, at := recoveryRTTFromStats(now, webrtc.StatsReport{"pair": pair})
	if rtt != 4*time.Millisecond || at.IsZero() {
		t.Fatal("valid consent ignored")
	}
	pair.LastResponseTimestamp = timestamp(now.Add(-3 * time.Second))
	if rtt, _ := recoveryRTTFromStats(now, webrtc.StatsReport{"pair": pair}); rtt != 0 {
		t.Fatal("stale consent refreshed RTT")
	}
	pair.LastResponseTimestamp = timestamp(now.Add(time.Second))
	if rtt, _ := recoveryRTTFromStats(now, webrtc.StatsReport{"pair": pair}); rtt != 0 {
		t.Fatal("future consent accepted")
	}
	pair.LastResponseTimestamp, pair.Nominated = timestamp(now), false
	if rtt, _ := recoveryRTTFromStats(now, webrtc.StatsReport{"pair": pair}); rtt != 0 {
		t.Fatal("unused route affected repair")
	}
}

func TestFrameRepairDeadlineIncludesEarlierPacketsAndTransit(t *testing.T) {
	now := time.Now()
	r := &retransmissionInterceptor{deadline: func() (time.Duration, time.Duration) { return 50 * time.Millisecond, 5 * time.Millisecond }}
	// A recently sent last packet does not extend an already old frame's deadline.
	packet := &cachedRTP{stored: now.Add(-time.Millisecond), frameStarted: now.Add(-46 * time.Millisecond)}
	if r.repairUseful(packet, now) {
		t.Fatal("late tail packet extended the frame deadline")
	}
	packet.frameStarted = now.Add(-20 * time.Millisecond)
	if !r.repairUseful(packet, now) {
		t.Fatal("useful repair rejected")
	}
}

func TestRepairDeadlineAdaptsToRTTAndExpiresEvidence(t *testing.T) {
	p := newPacketPacer(4000000)
	defer p.Close()
	if window, transit := p.RecoveryDeadline(); window != retransmissionAge || transit != 0 {
		t.Fatal("missing measurements changed legacy recovery")
	}
	p.recoveryFPS, p.recoveryRTT, p.recoveryMeasured = 120, 4*time.Millisecond, time.Now()
	if window, transit := p.RecoveryDeadline(); window != 50*time.Millisecond || transit != 2*time.Millisecond {
		t.Fatalf("LAN deadline: %v %v", window, transit)
	}
	p.recoveryRTT = 80 * time.Millisecond
	if window, transit := p.RecoveryDeadline(); window < 170*time.Millisecond || transit != 40*time.Millisecond {
		t.Fatalf("WAN deadline: %v %v", window, transit)
	}
	p.recoveryMeasured = time.Now().Add(-3 * time.Second)
	if window, transit := p.RecoveryDeadline(); window != retransmissionAge || transit != 0 {
		t.Fatal("stale RTT affected repair")
	}
}

func TestLateFrameRepairRequestsRefresh(t *testing.T) {
	refresh := make(chan struct{}, 1)
	value, err := (retransmissionFactory{refresh: func() { refresh <- struct{}{} }, deadline: func() (time.Duration, time.Duration) { return 50 * time.Millisecond, 5 * time.Millisecond }}).NewInterceptor("test")
	if err != nil {
		t.Fatal(err)
	}
	r := value.(*retransmissionInterceptor)
	defer r.Close()
	sent := make(chan uint16, 4)
	writer := r.BindLocalStream(&interceptor.StreamInfo{SSRC: 1}, interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
		sent <- h.SequenceNumber
		return len(p), nil
	}))
	if _, err := writer.Write(&rtp.Header{Version: 2, SSRC: 1, SequenceNumber: 1, Timestamp: 90}, []byte{1}, nil); err != nil {
		t.Fatal(err)
	}
	<-sent
	r.mu.Lock()
	r.streams[1].packets[1].frameStarted = time.Now().Add(-60 * time.Millisecond)
	r.mu.Unlock()
	r.requests <- retransmissionKey{ssrc: 1, sequence: 1}
	select {
	case <-refresh:
	case sequence := <-sent:
		t.Fatalf("retransmitted expired frame packet %d", sequence)
	case <-time.After(time.Second):
		t.Fatal("no refresh after expired repair")
	}
}
