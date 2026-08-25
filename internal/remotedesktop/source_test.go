package remotedesktop

import (
	"context"
	"errors"
	"slices"
	"testing"
)

func TestProbeCaptureDiscardsSyntheticFrame(t *testing.T) {
	if err := ProbeCapture(context.Background(), SourceOptions{Kind: "synthetic", FPS: 30}); err != nil {
		t.Fatal(err)
	}
}

func TestCaptureFailureExplainsMacScreenRecordingPermission(t *testing.T) {
	err := captureFailure("darwin", errors.New("read FFmpeg IVF header: EOF"), "Not authorized to capture video")
	if err == nil || err.Error() != "macOS Screen Recording permission is not granted to FFmpeg; run `dieter daemon permissions` on the host: read FFmpeg IVF header: EOF" {
		t.Fatalf("permission error=%v", err)
	}
}

func TestFFmpegMacCaptureSelectsScreenByName(t *testing.T) {
	arguments, err := ffmpegArgs("darwin", "primary", 30, 4_000, map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	input := slices.Index(arguments, "-i")
	if input < 0 || input+1 >= len(arguments) || arguments[input+1] != "Capture screen 0:none" {
		t.Fatalf("FFmpeg input arguments=%q", arguments)
	}
	if arguments[input+1] == "0:none" {
		t.Fatal("screen capture must not use AVFoundation camera index 0")
	}
}

func TestFFmpegCaptureBounds(t *testing.T) {
	if _, err := ffmpegArgs("darwin", "primary", 0, 4_000, nil); err == nil {
		t.Fatal("expected zero FPS to be rejected")
	}
	if _, err := ffmpegArgs("darwin", "primary", 30, 99, nil); err == nil {
		t.Fatal("expected undersized bitrate to be rejected")
	}
}
