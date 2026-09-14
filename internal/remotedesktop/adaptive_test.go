package remotedesktop

import (
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

func TestPacerAppliesBackpressureAndCancellation(t *testing.T) {
	pacer := newPacketPacer(100000)
	defer pacer.Close()
	writes := 0
	pacer.AddStream(1, interceptor.RTPWriterFunc(func(*rtp.Header, []byte, interceptor.Attributes) (int, error) { writes++; return 1200, nil }))
	h := &rtp.Header{Version: 2, SSRC: 1}
	if _, err := pacer.Write(h, make([]byte, 1200), nil); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, err := pacer.Write(h, make([]byte, 1200), nil); done <- err }()
	select {
	case err := <-done:
		t.Fatalf("packet bypassed pacing: %v", err)
	case <-time.After(10 * time.Millisecond):
	}
	pacer.Close()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled write succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("pacer did not cancel")
	}
	if writes != 1 {
		t.Fatalf("sent %d packets", writes)
	}
}

func TestPacerMeasuresSocketWorkWithoutCountingPacingDelay(t *testing.T) {
	pacer := newPacketPacer(100000)
	defer pacer.Close()
	pacer.AddStream(1, interceptor.RTPWriterFunc(func(*rtp.Header, []byte, interceptor.Attributes) (int, error) {
		time.Sleep(time.Millisecond)
		return 1200, nil
	}))
	started := time.Now()
	for range 3 {
		if _, err := pacer.Write(&rtp.Header{Version: 2, SSRC: 1}, make([]byte, 1200), nil); err != nil {
			t.Fatal(err)
		}
	}
	elapsed := time.Since(started)
	writing := time.Duration(pacer.writeNanoseconds.Load())
	if writing < 3*time.Millisecond || elapsed-writing < 40*time.Millisecond {
		t.Fatalf("socket work %s must exclude deliberate pacing (%s total)", writing, elapsed)
	}
}
