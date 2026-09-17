package remotedesktop

import (
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

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
