package remotedesktop

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"slices"
	"strings"
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

func TestNativeCaptureFrameProtocol(t *testing.T) {
	payload := []byte{0, 0, 0, 1, 0x65, 0xaa}
	header := make([]byte, nativeCaptureHeaderSize)
	binary.BigEndian.PutUint32(header[0:4], uint32(len(payload)))
	binary.BigEndian.PutUint32(header[4:8], 1)
	binary.BigEndian.PutUint64(header[8:16], uint64(33_333_333))
	binary.BigEndian.PutUint64(header[16:24], uint64(123_000_000_000))
	binary.BigEndian.PutUint64(header[24:32], uint64(4_000_000))
	sample, capturedAt, encodedIn, err := readNativeCaptureSample(bytes.NewReader(append(header, payload...)), 30)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(sample.Data, payload) || sample.Duration != 33_333_333 || capturedAt != 123_000_000_000 || encodedIn != 4_000_000 {
		t.Fatalf("sample=%#v capturedAt=%d encodedIn=%s", sample, capturedAt, encodedIn)
	}
}

func TestNativeCaptureFrameProtocolRejectsUnboundedPayload(t *testing.T) {
	header := make([]byte, nativeCaptureHeaderSize)
	binary.BigEndian.PutUint32(header[0:4], maxEncodedFrameBytes+1)
	if _, _, _, err := readNativeCaptureSample(bytes.NewReader(header), 30); err == nil {
		t.Fatal("expected oversized native frame to be rejected")
	}
}

func TestNativeCaptureControlsSurviveEncoderStartup(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	source := &nativeHelperSource{}
	source.RequestKeyFrame()
	source.SetBitrateKbps(2_500)
	source.installControl(writer)
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	raw, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "{\"keyframe\":true}\n{\"bitrate_kbps\":2500}\n" {
		t.Fatalf("controls=%q", raw)
	}
}

func TestNativeCaptureUserDeclinedHasActionablePermissionError(t *testing.T) {
	err := nativeCaptureFailure(errors.New("helper exited"), "SCStreamErrorDomain error -3801")
	if err == nil || !strings.Contains(err.Error(), "dieter daemon permissions") {
		t.Fatalf("permission error=%v", err)
	}
}
