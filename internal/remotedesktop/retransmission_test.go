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
