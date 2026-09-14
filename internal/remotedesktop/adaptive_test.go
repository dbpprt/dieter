package remotedesktop

import (
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

func TestAdaptiveQualityRespondsToCongestionAndRecoversWithHysteresis(t *testing.T) {
	limits, _ := normalizeConfiguration(&dieterv1.RemoteDesktopStreamConfiguration{})
	current := nativeConfiguration(limits)
	constrained := adaptiveConfiguration(current, limits, nil, 1500, 0, 2, true)
	if constrained.BitrateKbps != 1500 || constrained.FPS >= 60 || constrained.MaxWidth >= current.MaxWidth {
		t.Fatalf("congestion response: %+v", constrained)
	}
	stable := adaptiveConfiguration(constrained, limits, nil, 12000, 1, 0, false)
	if stable.FPS != constrained.FPS || stable.MaxWidth != constrained.MaxWidth {
		t.Fatalf("recovered too early: %+v", stable)
	}
	recovered := adaptiveConfiguration(constrained, limits, nil, 12000, 6, 0, true)
	if recovered.FPS <= constrained.FPS || recovered.MaxWidth <= constrained.MaxWidth {
		t.Fatalf("failed to recover: %+v", recovered)
	}
	limits.Quality = dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_DETAIL
	detail := adaptiveConfiguration(current, limits, nil, 8000, 6, 0, true)
	if detail.FPS > 30 {
		t.Fatalf("detail budget: %+v", detail)
	}
	limits.Quality = dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_MOTION
	slowDecoder := adaptiveConfiguration(current, limits, &dieterv1.RemoteDesktopReceiverFeedback{DecodeMs: 40}, 8000, 0, 2, true)
	if slowDecoder.FPS >= 60 {
		t.Fatalf("motion ignored overloaded decoder: %+v", slowDecoder)
	}
	limits.MaxFps = 5
	limits.MaxWidth = 320
	limits.MaxHeight = 180
	limits.MaxBitrateKbps = 100
	low := adaptiveConfiguration(nativeConfiguration(limits), limits, nil, 1, 0, 2, true)
	if low.FPS > 5 || low.MaxWidth > 320 || low.MaxHeight > 180 || low.BitrateKbps != 100 {
		t.Fatalf("ceiling exceeded: %+v", low)
	}
}

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
