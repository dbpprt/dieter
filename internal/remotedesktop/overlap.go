package remotedesktop

import (
	"time"

	"github.com/pion/webrtc/v4/pkg/media"
)

// Predict conservatively at the encoder rate (not the pacer's burst rate).
// The native side independently rechecks freshness and permits only one extra
// frame. A blocked/slow previous send immediately withdraws speculative work.
func overlapBudget(sample media.Sample, config StreamConfiguration, previousSend time.Duration) int {
	m, ok := sample.Metadata.(FrameMetadata)
	if !ok || len(sample.Data) > 2<<20 || config.FPS < 1 || config.BitrateKbps < 100 || m.EncodeTime <= 0 {
		return 0
	}
	deadline := min(50*time.Millisecond, 2*time.Second/time.Duration(config.FPS))
	serialization := time.Duration(float64(len(sample.Data)*8) / float64(config.BitrateKbps*1000) * float64(time.Second))
	age := m.CaptureDelay
	if !m.ReceivedAt.IsZero() {
		age += max(0, time.Since(m.ReceivedAt))
	}
	remaining := deadline - age - max(serialization, previousSend)
	if remaining <= m.EncodeTime || age < 0 {
		return 0
	}
	return int(remaining / time.Millisecond)
}
