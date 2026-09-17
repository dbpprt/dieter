package remotedesktop

import (
	"context"
	"errors"
	"github.com/pion/webrtc/v4/pkg/media"
	"os"
	"sync"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func TestFastBitrateRequiresNewSustainedEvidence(t *testing.T) {
	now := time.Now()
	h := transportHealth{at: now, sentAt: now, packets: 30, span: 80 * time.Millisecond, growthMS: 40, deliveredRate: 3_000_000}
	var c fastBitrateController
	if got := c.next(now, 12000, 12000, 12_000_000, h); got != 12000 {
		t.Fatal("one jitter burst reduced rate", got)
	}
	if got := c.next(now.Add(time.Second), 12000, 12000, 12_000_000, h); got != 12000 {
		t.Fatal("replayed/stale feedback reduced rate", got)
	}
	h.at = now.Add(100 * time.Millisecond)
	if got := c.next(h.at, 12000, 12000, 12_000_000, h); got != 2550 {
		t.Fatal("12 -> 3 Mbps capacity drop was not applied", got)
	}
	if got := c.next(h.at, 2550, 12000, 12_000_000, h); got != 2550 {
		t.Fatal("same report reduced rate twice", got)
	}
	h.at = now.Add(200 * time.Millisecond)
	h.growthMS = 0
	h.deliveredRate = 100_000
	if got := c.next(h.at, 2550, 12000, 100_000, h); got != 2550 {
		t.Fatal("quiet desktop/old GCC estimate reduced rate", got)
	}
	h.at = now.Add(300 * time.Millisecond)
	h.growthMS = 30
	if got := c.next(h.at, 2550, 12000, 12_000_000, h); got != 2550 {
		t.Fatal("separate jitter accumulated", got)
	}
}

func TestFastBitrateLossFloorsAndSparseFeedback(t *testing.T) {
	for _, tc := range []struct {
		name                             string
		packets, current, estimate, want int
		age                              time.Duration
	}{
		{"loss", 30, 12000, 12_000_000, 10200, 0},
		{"GCC reduction", 30, 12000, 3_000_000, 2550, 0},
		{"floor", 30, 200, 1, 100, 0},
		{"already at floor", 30, 100, 1, 100, 0},
		{"sparse", 1, 12000, 100_000, 12000, 0},
		{"stale", 30, 12000, 100_000, 12000, time.Second},
		{"future", 30, 12000, 100_000, 12000, -time.Second},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			var c fastBitrateController
			h := transportHealth{at: now.Add(-tc.age), sentAt: now, packets: tc.packets, span: 30 * time.Millisecond, loss: .05, deliveredRate: 100_000}
			if got := c.next(now, tc.current, 12000, tc.estimate, h); got != tc.want {
				t.Fatalf("got %d, want %d", got, tc.want)
			}
		})
	}
}

type fastTestSource struct {
	pooledTestSource
	mu      sync.Mutex
	configs []StreamConfiguration
	err     error
}

func (s *fastTestSource) Configure(_ context.Context, c StreamConfiguration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.configs = append(s.configs, c)
	return s.err
}

func TestFastBitrateConfiguresOnlyRateAndPreservesRevision(t *testing.T) {
	for _, failure := range []bool{false, true} {
		t.Run(map[bool]string{false: "success", true: "failure"}[failure], func(t *testing.T) {
			p := newPacketPacer(3_000_000)
			p.SetTargetBitrate(3_000_000)
			defer p.Close()
			source := &fastTestSource{}
			if failure {
				source.err = errors.New("encoder unavailable")
			}
			config := StreamConfiguration{DisplayID: "primary", MaxWidth: 1920, MaxHeight: 1080, FPS: 60, BitrateKbps: 12000}
			s := &Session{manager: &Manager{}, source: source, pacer: p, ctx: t.Context(), applied: config, configurationRevision: 4}
			state := &dieterv1.RemoteDesktopSessionState{Configuration: &dieterv1.RemoteDesktopStreamConfiguration{MaxBitrateKbps: 12000}}
			now := time.Now()
			var fast fastBitrateController
			slow := newQualityController(now)
			h := transportHealth{at: now, sentAt: now, packets: 30, span: 30 * time.Millisecond, loss: .05}
			s.reduceBitrate(now, &fast, slow, state, config, 3, h)
			if len(source.configs) != 0 {
				t.Fatal("stale configuration revision applied")
			}
			h.at = now.Add(time.Millisecond)
			s.reduceBitrate(h.at, &fast, slow, state, config, 4, h)
			want := config
			want.BitrateKbps = 2550
			if len(source.configs) != 1 || source.configs[0] != want {
				t.Fatalf("unexpected configuration: %+v", source.configs)
			}
			if failure {
				if s.applied != config || !fast.holdUntil.IsZero() {
					t.Fatal("failed command committed")
				}
			} else {
				if s.applied != want || s.configurationRevision != 4 || slow.budget != 2550 || !now.Before(fast.holdUntil) {
					t.Fatal("recovery state or configuration lost")
				}
			}
		})
	}
}

func TestFastBitrateWakeupsAreBoundedAndNonblocking(t *testing.T) {
	p := newPacketPacer(12_000_000)
	defer p.Close()
	for i := 0; i < 10000; i++ {
		p.SetTargetBitrate(3_000_000 + i)
	}
	if len(p.feedbackReady) != 1 || p.TargetBitrate() != 3_009_999 {
		t.Fatal("feedback queued or latest estimate lost")
	}
}

func TestFastBitrateRejectsNewReportAboutOldPackets(t *testing.T) {
	now := time.Now()
	var c fastBitrateController
	h := transportHealth{at: now, sentAt: now.Add(-time.Second), packets: 30, span: 30 * time.Millisecond, loss: .1}
	if got := c.next(now, 12000, 12000, 100_000, h); got != 12000 {
		t.Fatal("a delayed report after a stall reduced the encoder", got)
	}
}

// Real hardware/IPC through the production reduction path. Run on both codecs
// to catch accidental encoder resets, forced IDRs, or deferred rate application.
func TestNativeFastBitratePreservesHardwareStream(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("native helper not configured")
	}
	for _, codec := range []VideoCodec{VideoCodecH264, VideoCodecH265} {
		t.Run(string(codec), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			source, err := NewFrameSource(SourceOptions{Kind: "native-synthetic", HelperPath: helper, Codec: codec, Profile: "high", FPS: 60, MaxWidth: 1920, MaxHeight: 1080, Bitrate: 12000})
			if err != nil {
				t.Fatal(err)
			}
			frames := make(chan FrameMetadata, 1)
			done := make(chan error, 1)
			go func() {
				done <- source.Stream(ctx, func(sample media.Sample) error {
					select {
					case frames <- sample.Metadata.(FrameMetadata):
					case <-ctx.Done():
						return ctx.Err()
					}
					return nil
				})
			}()
			defer func() {
				cancel()
				select {
				case <-done:
				case <-time.After(4 * time.Second):
					t.Error("native helper did not stop")
				}
			}()
			next := func() FrameMetadata {
				t.Helper()
				select {
				case f := <-frames:
					return f
				case <-ctx.Done():
					t.Fatal("frame deadline")
					return FrameMetadata{}
				}
			}
			first := next()
			for range 6 {
				next()
			}
			p := newPacketPacer(12_000_000)
			defer p.Close()
			config := StreamConfiguration{DisplayID: "primary", MaxWidth: 1920, MaxHeight: 1080, FPS: 60, BitrateKbps: 12000}
			session := &Session{manager: &Manager{}, source: source, pacer: p, ctx: ctx, applied: config}
			state := &dieterv1.RemoteDesktopSessionState{Configuration: &dieterv1.RemoteDesktopStreamConfiguration{MaxBitrateKbps: 12000}}
			now := time.Now()
			var fast fastBitrateController
			slow := newQualityController(now)
			// Initial jitter observation, followed by sustained 3 Mbps delivery.
			health := transportHealth{at: now, sentAt: now, packets: 30, span: 80 * time.Millisecond, growthMS: 40, deliveredRate: 3_000_000}
			session.reduceBitrate(now, &fast, slow, state, config, 0, health)
			time.Sleep(fastBitrateInterval)
			health.at = time.Now()
			started := time.Now()
			session.reduceBitrate(health.at, &fast, slow, state, config, 0, health)
			elapsed := time.Since(started)
			if session.applied.BitrateKbps != 2550 {
				t.Fatalf("rate not applied: %+v", session.applied)
			}
			if elapsed > 250*time.Millisecond {
				t.Fatalf("feedback-to-native configuration took %s", elapsed)
			}
			for range 30 {
				f := next()
				if f.Generation != first.Generation || f.KeyFrame || f.Width != 1920 || f.Height != 1080 {
					t.Fatalf("bitrate cut disrupted hardware stream: %+v", f)
				}
			}
			t.Logf("%s: 12000 -> 2550 kbps, feedback-to-native ACK %s; 30 subsequent frames, unchanged generation, no forced IDR", codec, elapsed)
		})
	}
}

func TestFastBitrateDoesNotReduceOtherViewers(t *testing.T) {
	pool := newCapturePool(func(options SourceOptions) (FrameSource, error) { return &fastTestSource{}, nil })
	defer pool.Close()
	opts := SourceOptions{Kind: "native-synthetic", Codec: VideoCodecH264, FPS: 60, MaxWidth: 1920, MaxHeight: 1080, Bitrate: 12000}
	a, err := pool.Subscribe(opts)
	if err != nil {
		t.Fatal(err)
	}
	b, err := pool.Subscribe(opts)
	if err != nil {
		t.Fatal(err)
	}
	config := sourceConfiguration(opts)
	p := newPacketPacer(12_000_000)
	defer p.Close()
	s := &Session{manager: &Manager{}, source: b, pacer: p, ctx: t.Context(), applied: config}
	state := &dieterv1.RemoteDesktopSessionState{Configuration: &dieterv1.RemoteDesktopStreamConfiguration{MaxBitrateKbps: 12000}}
	now := time.Now()
	var fast fastBitrateController
	s.reduceBitrate(now, &fast, newQualityController(now), state, config, 0, transportHealth{at: now, sentAt: now, packets: 30, span: 30 * time.Millisecond, loss: .05})
	pool.mu.Lock()
	defer pool.mu.Unlock()
	if a.(*sharedSource).variant == b.(*sharedSource).variant || a.(*sharedSource).variant.config.BitrateKbps != 12000 || b.(*sharedSource).variant.config.BitrateKbps != 10200 {
		t.Fatal("one viewer's loss changed the other encoder")
	}
}
