package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4/pkg/media"
)

func TestSyntheticSourceEmitsVP8Frame(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var sample media.Sample
	err := (syntheticSource{interval: time.Millisecond}).Stream(ctx, func(value media.Sample) error {
		sample = value
		cancel()
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(sample.Data) == 0 || sample.Duration != time.Millisecond {
		t.Fatalf("unexpected sample: bytes=%d duration=%s", len(sample.Data), sample.Duration)
	}
}

func TestFFmpegArgsForSupportedPlatforms(t *testing.T) {
	tests := []struct {
		platform string
		display  string
		environ  map[string]string
		contains []string
	}{
		{platform: "darwin", contains: []string{"avfoundation", "-pixel_format nv12", "0:none", "libvpx", "pipe:1"}},
		{platform: "windows", contains: []string{"gdigrab", "desktop", "libvpx", "pipe:1"}},
		{platform: "linux", environ: map[string]string{"DISPLAY": ":1.0"}, contains: []string{"x11grab", ":1.0", "libvpx", "pipe:1"}},
	}
	for _, test := range tests {
		t.Run(test.platform, func(t *testing.T) {
			arguments, err := ffmpegArgs(test.platform, test.display, 30, 4_000, test.environ)
			if err != nil {
				t.Fatal(err)
			}
			joined := strings.Join(arguments, " ")
			for _, expected := range test.contains {
				if !strings.Contains(joined, expected) {
					t.Fatalf("arguments %q do not contain %q", joined, expected)
				}
			}
		})
	}
}

func TestFFmpegArgsRejectUnsupportedWaylandAutomation(t *testing.T) {
	_, err := ffmpegArgs("linux", "", 30, 4_000, map[string]string{"WAYLAND_DISPLAY": "wayland-0"})
	if err == nil || !strings.Contains(err.Error(), "Wayland") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestParseICEServers(t *testing.T) {
	servers, err := parseICEServers(
		"stun:stun.example.com:3478",
		"turn:turn.example.com:3478?transport=udp,turns:turn.example.com:443?transport=tcp",
		"user",
		"secret",
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(servers) != 2 || len(servers[1].URLs) != 2 || servers[1].Username != "user" {
		t.Fatalf("unexpected ICE servers: %#v", servers)
	}
	if _, err := parseICEServers("", "turn:turn.example.com:3478", "", ""); err == nil {
		t.Fatal("expected TURN credentials to be required")
	}
}
