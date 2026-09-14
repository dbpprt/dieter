package remotedesktop

import (
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

type qualitySimulation struct {
	now        time.Time
	controller *qualityController
	limits     *dieterv1.RemoteDesktopStreamConfiguration
	current    StreamConfiguration
	sequence   uint64
	changes    []StreamConfiguration
}

func newQualitySimulation(t *testing.T) *qualitySimulation {
	t.Helper()
	limits, err := normalizeConfiguration(&dieterv1.RemoteDesktopStreamConfiguration{MaxWidth: 1920, MaxHeight: 1080, MaxFps: 60, MaxBitrateKbps: 12000})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1000, 0)
	return &qualitySimulation{now: now, controller: newQualityController(now), limits: limits, current: nativeConfiguration(limits)}
}

func (s *qualitySimulation) step(budget int, encode, decode, loss float64, bytes uint64, active bool) string {
	s.now = s.now.Add(time.Second)
	s.sequence++
	frames := frameMeasurements{}
	if active {
		frames = frameMeasurements{frames: 30, interFrames: 30, bytes: bytes, encodeMS: encode * 30, writeMS: .1 * 30}
	}
	w, h := fitVideo(s.current.MaxWidth, s.current.MaxHeight, 16.0/9)
	after, reason := s.controller.next(s.now, s.current, s.limits, adaptationSample{
		frames: frames, budget: budget, width: w, height: h, elapsed: time.Second, feedbackAt: s.now,
		feedback: &dieterv1.RemoteDesktopReceiverFeedback{Sequence: s.sequence, DecodeMs: decode, FramesPerSecond: 30, LossFraction: loss},
	})
	if after != s.current {
		s.changes = append(s.changes, after)
		s.controller.applied(s.now, s.current, after)
		s.current = after
	}
	return reason
}

func TestQualityConstantDecoderCapacityDoesNotOscillate(t *testing.T) {
	s := newQualitySimulation(t)
	for range 120 {
		s.step(12000, 5, 15, 0, 400000, true)
	}
	if s.current.FPS != 45 || s.current.MaxWidth != 1920 || len(s.changes) != 1 {
		t.Fatalf("constant LAN conditions must settle once: %+v", s.changes)
	}
}

func TestQualityIdleAndKeyframeSamplesCannotRatchetDown(t *testing.T) {
	s := newQualitySimulation(t)
	for range 20 {
		s.step(12000, 5, 4, 0, 150000, true)
	}
	before := s.current
	for i := 0; i < 90; i++ {
		s.now = s.now.Add(time.Second)
		after, _ := s.controller.next(s.now, s.current, s.limits, adaptationSample{
			frames: frameMeasurements{frames: 1, bytes: 200000}, budget: 100, width: 1920, height: 1080, elapsed: time.Second,
			feedbackAt: s.now, feedback: &dieterv1.RemoteDesktopReceiverFeedback{Sequence: uint64(100 + i), DecodeMs: 900, LossFraction: .5},
		})
		if after != before {
			t.Fatalf("idle/keyframe-only interval changed quality: %+v", after)
		}
	}
}

func TestQualityLowTrafficAndEstimateNoisePreserveResolution(t *testing.T) {
	s := newQualitySimulation(t)
	for i := 0; i < 120; i++ {
		s.step(2800+(i%3)*800, 4, 5, 0, 10000, true)
	}
	if s.current.MaxWidth != 1920 || s.current.FPS != 60 {
		t.Fatalf("unsaturated desktop shrank: %+v", s.current)
	}
}

func TestQualityBudgetsActualPixelsWhenViewportExceedsDisplay(t *testing.T) {
	s := newQualitySimulation(t)
	s.limits.MaxWidth, s.limits.MaxHeight = 3840, 2160
	s.current = nativeConfiguration(s.limits)
	for i := uint64(1); i <= 90; i++ {
		s.now = s.now.Add(time.Second)
		after, _ := s.controller.next(s.now, s.current, s.limits, adaptationSample{
			frames: frameMeasurements{frames: 60, interFrames: 60, encodeMS: 240, bytes: 600000},
			budget: 6000, width: 1600, height: 900, elapsed: time.Second, feedbackAt: s.now,
			feedback: &dieterv1.RemoteDesktopReceiverFeedback{Sequence: i, DecodeMs: 4, FramesPerSecond: 60},
		})
		s.controller.applied(s.now, s.current, after)
		s.current = after
	}
	if s.current.FPS != 60 || s.current.MaxWidth != 3840 {
		t.Fatalf("charged a 1600x900 display for uncaptured 4K pixels: %+v", s.current)
	}
}

func TestQualityCongestionLowersCadenceBeforePixelsAndRecoversSlowly(t *testing.T) {
	s := newQualitySimulation(t)
	lastSize := s.now
	resizes := 0
	for range 80 {
		before := s.current
		s.step(450, 4, 4, .08, 60000, true)
		if s.current.MaxWidth != before.MaxWidth {
			if before.FPS > 15 {
				t.Fatal("reduced resolution before frame rate")
			}
			if s.now.Sub(lastSize) < 12*time.Second {
				t.Fatal("resized too frequently")
			}
			lastSize = s.now
			resizes++
		}
	}
	if resizes == 0 || s.current.MaxWidth >= 1920 || s.current.MaxWidth < 640 {
		t.Fatalf("no bounded congestion response: %+v", s.current)
	}
	width := s.current.MaxWidth
	for range 5 {
		s.step(12000, 4, 4, 0, 200000, true)
	}
	if s.current.MaxWidth != width {
		t.Fatal("a short recovery immediately resized")
	}
	for range 240 {
		s.step(12000, 4, 4, 0, 200000, true)
	}
	if s.current.MaxWidth != 1920 || s.current.MaxHeight != 1080 || s.current.FPS != 60 {
		t.Fatalf("failed to recover full quality: %+v", s.current)
	}
}

func TestQualitySingleStaleReceiverSampleCannotBecomeSustainedOverload(t *testing.T) {
	s := newQualitySimulation(t)
	for range 10 {
		s.step(12000, 4, 4, 0, 200000, true)
	}
	before := s.current
	sample := adaptationSample{frames: frameMeasurements{frames: 30, interFrames: 30, encodeMS: 120, bytes: 10000}, budget: 12000, width: 1920, height: 1080, elapsed: time.Second, feedbackAt: s.now, feedback: &dieterv1.RemoteDesktopReceiverFeedback{Sequence: 11, DecodeMs: 100, FramesPerSecond: 30}}
	for range 10 {
		s.now = s.now.Add(time.Second)
		after, _ := s.controller.next(s.now, s.current, s.limits, sample)
		if after != before {
			t.Fatalf("reused old feedback: %+v", after)
		}
	}
}

func TestQualityRespectsModesAndSmallUserCeilings(t *testing.T) {
	for _, quality := range []dieterv1.RemoteDesktopQuality{0, 1, 2} {
		s := newQualitySimulation(t)
		s.limits = &dieterv1.RemoteDesktopStreamConfiguration{DisplayId: "primary", MaxWidth: 320, MaxHeight: 180, MaxFps: 5, MaxBitrateKbps: 100, Quality: quality}
		s.current = nativeConfiguration(s.limits)
		for range 90 {
			s.step(100, 2, 2, 0, 10000, true)
		}
		if s.current.MaxWidth > 320 || s.current.MaxHeight > 180 || s.current.FPS > 5 || s.current.BitrateKbps > 100 {
			t.Fatalf("mode %v exceeded ceilings: %+v", quality, s.current)
		}
	}
	s := newQualitySimulation(t)
	s.limits.Quality = dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_DETAIL
	for range 30 {
		s.step(12000, 4, 4, 0, 200000, true)
	}
	if s.current.FPS > 30 {
		t.Fatal("detail mode did not preserve resolution before cadence")
	}
}

func TestReceiverBudgetExpiresOldREMB(t *testing.T) {
	now := time.Now()
	if got := receiverBudget(now, 12000, 14000000, 100, now.Add(-6*time.Second).UnixNano()); got != 11900 {
		t.Fatalf("stale REMB pinned bandwidth: %d", got)
	}
	if got := receiverBudget(now, 12000, 14000000, 100, now.UnixNano()); got != 100 {
		t.Fatalf("fresh REMB ignored: %d", got)
	}
}
