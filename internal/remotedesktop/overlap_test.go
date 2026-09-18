package remotedesktop

import (
	"testing"
	"time"

	"github.com/pion/webrtc/v4/pkg/media"
)

func TestOverlapAdmissionRejectsOldFramesAndSlowTransport(t *testing.T) {
	config := StreamConfiguration{FPS: 60, BitrateKbps: 12000}
	metadata := FrameMetadata{EncodeTime: 4 * time.Millisecond, CaptureDelay: 5 * time.Millisecond}
	sample := media.Sample{Data: make([]byte, 16000), Metadata: metadata}
	if budget := overlapBudget(sample, config, time.Millisecond); budget < 5 || budget > 50 {
		t.Fatal(budget)
	}
	if overlapBudget(sample, config, 50*time.Millisecond) != 0 {
		t.Fatal("slow sender admitted speculation")
	}
	metadata.CaptureDelay = 50 * time.Millisecond
	sample.Metadata = metadata
	if overlapBudget(sample, config, 0) != 0 {
		t.Fatal("stale frame admitted speculation")
	}
	metadata.CaptureDelay = 0
	sample.Metadata = metadata
	config.BitrateKbps = 100
	if overlapBudget(sample, config, 0) != 0 {
		t.Fatal("serialization budget ignored")
	}
}
