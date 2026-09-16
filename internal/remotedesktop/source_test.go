package remotedesktop

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"strings"
	"testing"
)

func TestProbeCaptureDiscardsSyntheticFrame(t *testing.T) {
	if err := ProbeCapture(context.Background(), SourceOptions{Kind: "synthetic", FPS: 30}); err != nil {
		t.Fatal(err)
	}
}

func TestNativeCaptureFrameProtocol(t *testing.T) {
	payload := []byte{0, 0, 0, 1, 0x65, 0xaa}
	header := make([]byte, nativeCaptureHeaderSize)
	binary.BigEndian.PutUint32(header[0:4], uint32(len(payload)))
	binary.BigEndian.PutUint32(header[4:8], 1)
	binary.BigEndian.PutUint64(header[8:16], uint64(1))
	binary.BigEndian.PutUint64(header[16:24], uint64(1))
	binary.BigEndian.PutUint64(header[24:32], uint64(123_000_000_000))
	binary.BigEndian.PutUint64(header[32:40], uint64(4_000_000))
	binary.BigEndian.PutUint32(header[48:52], 1920)
	binary.BigEndian.PutUint32(header[52:56], 1080)
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

func TestNativeCaptureUserDeclinedHasActionablePermissionError(t *testing.T) {
	err := nativeCaptureFailure(errors.New("helper exited"), "SCStreamErrorDomain error -3801")
	if err == nil || !strings.Contains(err.Error(), "dieter daemon permissions") {
		t.Fatalf("permission error=%v", err)
	}
}
