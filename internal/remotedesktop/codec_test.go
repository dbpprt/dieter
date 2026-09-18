package remotedesktop

import (
	"errors"
	"strings"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const hevcTestOffer = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=video 9 UDP/TLS/RTP/SAVPF 104\r\na=recvonly\r\na=rtpmap:104 H265/90000\r\na=fmtp:104 profile-id=1;tier-flag=0;level-id=153;tx-mode=SRST\r\n"

func TestHEVCOfferRequiresCompatibleVideoPayload(t *testing.T) {
	for _, tt := range []struct {
		name, offer string
		want        bool
	}{
		{"main", hevcTestOffer, true},
		{"main10", strings.Replace(hevcTestOffer, "profile-id=1", "profile-id=2", 1), false},
		{"low level", strings.Replace(hevcTestOffer, "level-id=153", "level-id=93", 1), false},
		{"invalid level", strings.Replace(hevcTestOffer, "level-id=153", "level-id=999", 1), false},
		{"audio", strings.Replace(hevcTestOffer, "m=video", "m=audio", 1), false},
		{"disabled", strings.Replace(hevcTestOffer, "video 9", "video 0", 1), false},
		{"wrong payload", strings.Replace(hevcTestOffer, "SAVPF 104", "SAVPF 105", 1), false},
		{"interleaving", strings.Replace(hevcTestOffer, "tx-mode=SRST", "tx-mode=MRST", 1), false},
		{"decoding order", strings.Replace(hevcTestOffer, "tx-mode=SRST", "sprop-max-don-diff=1", 1), false},
		{"duplicate profile", strings.Replace(hevcTestOffer, "profile-id=1", "profile-id=2;profile-id=1", 1), false},
		{"string in junk", "H265/90000", false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := hevcOffered(tt.offer); got != tt.want {
				t.Fatalf("got %v want %v", got, tt.want)
			}
		})
	}
}

func TestHEVCPreferenceCompatibilityAndModeLimits(t *testing.T) {
	caps := &dieterv1.RemoteDesktopCapabilities{CodecModes: []*dieterv1.RemoteDesktopCodecMode{{Codec: "H265", Profile: "main", MaxWidth: 1920, MaxHeight: 1080, MaxFps: 60}}}
	config := &dieterv1.RemoteDesktopStreamConfiguration{MaxWidth: 1920, MaxHeight: 1080, MaxFps: 60, MaxBitrateKbps: 12000}
	for _, tt := range []struct {
		name       string
		preference dieterv1.RemoteDesktopCodecPreference
		offer      string
		caps       *dieterv1.RemoteDesktopCapabilities
		fps        int32
		want       VideoCodec
		fail       bool
	}{
		{"auto", 0, hevcTestOffer, caps, 60, VideoCodecH265, false},
		{"forced h264", 1, hevcTestOffer, caps, 60, VideoCodecH264, false},
		{"strict hevc", 2, hevcTestOffer, caps, 60, VideoCodecH265, false},
		{"old client", 0, "", caps, 60, VideoCodecH264, false},
		{"old host", 0, hevcTestOffer, nil, 60, VideoCodecH264, false},
		{"strict old host", 2, hevcTestOffer, nil, 60, "", true},
		{"120fps auto", 0, hevcTestOffer, caps, 120, VideoCodecH264, false},
		{"120fps strict", 2, hevcTestOffer, caps, 120, "", true},
		{"unknown preference", 3, hevcTestOffer, caps, 60, "", true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			config.MaxFps = tt.fps
			got, err := selectVideoCodec(tt.preference, tt.offer, config, tt.caps, SourceOptions{Kind: "native-synthetic"})
			if (err != nil) != tt.fail || got != tt.want {
				t.Fatalf("got %q, %v", got, err)
			}
		})
	}
}

func TestCapturePoolKeepsCodecsSeparateDuringReconfiguration(t *testing.T) {
	pool := newCapturePool(func(o SourceOptions) (FrameSource, error) {
		return &pooledTestSource{config: sourceConfiguration(o)}, nil
	})
	defer pool.Close()
	opts := SourceOptions{Kind: "screen", Codec: VideoCodecH264, FPS: 60, MaxWidth: 1920, MaxHeight: 1080, Bitrate: 6000}
	a, err := pool.Subscribe(opts)
	if err != nil {
		t.Fatal(err)
	}
	opts.Codec = VideoCodecH265
	b, err := pool.Subscribe(opts)
	if err != nil {
		t.Fatal(err)
	}
	if a.(*sharedSource).variant == b.(*sharedSource).variant {
		t.Fatal("mixed codecs shared an encoder")
	}
	opts.Profile = "baseline"
	c, err := pool.Subscribe(opts)
	if err != nil {
		t.Fatal(err)
	}
	if c.(*sharedSource).variant != b.(*sharedSource).variant {
		t.Fatal("H.264 fallback profile duplicated HEVC Main")
	}
	c.(*sharedSource).Close()
	changed := sourceConfiguration(opts)
	changed.BitrateKbps = 4000
	if err := a.(*sharedSource).Configure(t.Context(), changed); err != nil {
		t.Fatal(err)
	}
	if err := b.(*sharedSource).Configure(t.Context(), changed); err != nil {
		t.Fatal(err)
	}
	if a.(*sharedSource).variant == b.(*sharedSource).variant {
		t.Fatal("reconfiguration migrated across codecs")
	}
}

func TestHEVCFallbackClassifiesOnlyCodecInitialization(t *testing.T) {
	for _, reason := range []string{"HEVC encoder unavailable: failed", "EOF: HEVC encoder unavailable: failed", "native capture helper stopped: HEVC encoder unavailable: failed"} {
		if !hevcEncoderUnavailable(errors.New(reason)) {
			t.Errorf("missed %s", reason)
		}
	}
	for _, reason := range []string{"EOF", "native capture helper stopped", "permission denied", "identity verification failed", "No route to host"} {
		if hevcEncoderUnavailable(errors.New(reason)) {
			t.Errorf("misclassified %s", reason)
		}
	}
}
