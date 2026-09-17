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

func TestQualityLowEstimateWithoutCongestionCannotRemovePixels(t *testing.T) {
	s := newQualitySimulation(t)
	for range 120 {
		s.step(100, 4, 4, 0, 10000, true)
	}
	if s.current.MaxWidth != 1920 || s.current.FPS != 60 {
		t.Fatalf("a low estimate alone degraded healthy video: %+v", s.current)
	}
}

func TestQualitySparseActivityRecoversWithoutCountingIdleAsEvidence(t *testing.T) {
	s := newQualitySimulation(t)
	for range 80 {
		s.step(100, 4, 4, .08, 10000, true)
	}
	degraded := s.current
	if degraded.MaxWidth != 640 {
		t.Fatalf("fixture did not degrade: %+v", degraded)
	}
	for range 5 {
		s.step(12000, 4, 4, 0, 10000, true)
	}
	beforeIdle := s.current
	for range 120 {
		s.step(12000, 4, 4, 0, 0, false)
	}
	if s.current != beforeIdle {
		t.Fatal("idle invented recovery evidence")
	}
	for i := 0; i < 600; i++ {
		s.step(12000, 4, 4, 0, 10000, i%2 == 0)
	}
	if s.current.MaxWidth != 1920 || s.current.MaxHeight != 1080 || s.current.FPS != 60 {
		t.Fatalf("sparse desktop never recovered: %+v", s.current)
	}
}

func TestQualityHeartbeatDoesNotRefreshAnOldMeasurement(t *testing.T) {
	s := newQualitySimulation(t)
	for range 20 {
		s.step(12000, 4, 4, 0, 10000, true)
	}
	before := s.current
	for i := uint64(21); i < 60; i++ {
		s.now = s.now.Add(time.Second)
		after, _ := s.controller.next(s.now, s.current, s.limits, adaptationSample{
			frames: frameMeasurements{frames: 30, interFrames: 30, encodeMS: 120, bytes: 10000}, budget: 12000, width: 1920, height: 1080, elapsed: time.Second, feedbackAt: s.now,
			feedback: &dieterv1.RemoteDesktopReceiverFeedback{Sequence: i, MeasurementSequence: 21, DecodeMs: 100, FramesPerSecond: 30},
		})
		if after != before {
			t.Fatalf("heartbeats turned one sample into sustained overload: %+v", after)
		}
	}
}

func TestMotionSacrificesPixelsBeforeCadence(t *testing.T) {
	s := newQualitySimulation(t)
	s.limits.Quality = dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_MOTION
	resized := false
	for range 40 {
		before := s.current
		s.step(900, 3, 3, .08, 120000, true)
		if s.current.MaxWidth < before.MaxWidth && !resized {
			resized = true
			if s.current.FPS != 60 {
				t.Fatalf("motion lost cadence before pixels: %+v", s.current)
			}
		}
	}
	if !resized || s.current.MaxWidth < 640 {
		t.Fatalf("unbounded or missing response: %+v", s.current)
	}
	for range 240 {
		s.step(16000, 3, 3, 0, 200000, true)
	}
	if s.current.MaxWidth != 1920 || s.current.FPS != 60 {
		t.Fatalf("motion did not recover: %+v", s.current)
	}
}

func TestHighRefreshConfigurationAndRecovery(t *testing.T) {
	c, err := normalizeConfiguration(&dieterv1.RemoteDesktopStreamConfiguration{MaxFps: 120, MaxWidth: 3840, MaxHeight: 2160})
	if err != nil || c.MaxFps != 120 || c.MaxWidth != 1920 || c.MaxHeight != 1080 {
		t.Fatalf("high refresh H.264 limit: %v %v", c, err)
	}
	if _, err := normalizeConfiguration(&dieterv1.RemoteDesktopStreamConfiguration{MaxFps: 121}); err == nil {
		t.Fatal("unbounded refresh accepted")
	}
	s := newQualitySimulation(t)
	s.limits = c
	s.current = nativeConfiguration(c)
	s.current.FPS = 60
	for range 120 {
		s.step(12000, 3, 3, 0, 200000, true)
	}
	if s.current.FPS != 120 {
		t.Fatalf("cannot recover through 90 to 120: %+v", s.current)
	}
}

func TestIdleBitrateRecoveryRequiresConfirmedCapacityAndFreshHealthyFeedback(t *testing.T) {
	for _, scenario := range []string{"confirmed", "unproven", "stale", "congested", "loss"} {
		t.Run(scenario, func(t *testing.T) {
			s := newQualitySimulation(t)
			s.current.BitrateKbps = 148
			sample := adaptationSample{elapsed: time.Second, budget: 12000, confirmedBudget: 6000,
				feedbackAt: s.now.Add(time.Second), feedback: &dieterv1.RemoteDesktopReceiverFeedback{MeasurementSequence: 1}}
			switch scenario {
			case "unproven":
				sample.confirmedBudget = 0
			case "stale":
				sample.feedbackAt = s.now.Add(-5 * time.Second)
			case "congested":
				sample.networkPressure = true
			case "loss":
				sample.feedback.LossFraction = .05
			}
			after, _ := s.controller.next(s.now.Add(time.Second), s.current, s.limits, sample)
			if scenario == "confirmed" {
				if after.BitrateKbps != 6000 {
					t.Fatalf("idle desktop remained blurry despite acknowledged capacity: %+v", after)
				}
			} else if after != s.current {
				t.Fatalf("invalid recovery evidence changed idle quality: %+v", after)
			}
			if after.FPS != s.current.FPS || after.MaxWidth != s.current.MaxWidth {
				t.Fatal("idle feedback invented decoder capacity")
			}
		})
	}
}

func TestIdleRedrawSurvivesBitrateRecoveryUntilTheRefreshCooldownEnds(t *testing.T) {
	var refresh idleRefreshController
	now := time.Unix(1000, 0)
	if !refresh.due(now, true, true, true) {
		t.Fatal("degraded desktop did not probe")
	}
	refresh.configured(StreamConfiguration{BitrateKbps: 148}, StreamConfiguration{BitrateKbps: 12000}, true)
	if refresh.due(now.Add(time.Second), true, true, false) {
		t.Fatal("redraw bypassed refresh cooldown")
	}
	if refresh.due(now.Add(3*time.Second), true, false, false) {
		t.Fatal("redraw bypassed missing/pressured feedback")
	}
	if !refresh.due(now.Add(4*time.Second), true, true, false) {
		t.Fatal("reaching the bitrate ceiling lost the pending sharp redraw")
	}
	if refresh.due(now.Add(10*time.Second), true, true, false) {
		t.Fatal("healthy idle desktop kept requesting refreshes")
	}
	if refresh.due(now.Add(20*time.Second), false, true, true) {
		t.Fatal("active desktop requested an idle refresh")
	}
}
