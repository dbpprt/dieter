package remotedesktop

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4/pkg/media"
)

// Hardware encoder -> RFC 7798 packetization -> reassembly, including VPS/SPS/PPS
// and fragmented slices. Optional output is consumed by the native decoder probe.
func TestNativeHelperHEVCRoundTrip(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("native helper not configured")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	source, err := NewFrameSource(SourceOptions{Kind: "native-synthetic", HelperPath: helper, Codec: VideoCodecH265, FPS: 60, MaxWidth: 1920, MaxHeight: 1080, Bitrate: 6000})
	if err != nil {
		t.Fatal(err)
	}
	if source.Codec() != VideoCodecH265 {
		t.Fatal("HEVC silently changed codec")
	}
	var output *os.File
	if path := os.Getenv("DIETER_TEST_HEVC_FRAMES"); path != "" {
		output, err = os.Create(path)
		if err != nil {
			t.Fatal(err)
		}
		defer output.Close()
	}
	payloader := &codecs.H265Payloader{}
	frames, packets, wireBytes := 0, 0, 0
	var totalEncode time.Duration
	var first, last time.Duration
	complete := errors.New("verified HEVC frames")
	err = source.Stream(ctx, func(sample media.Sample) error {
		metadata := sample.Metadata.(FrameMetadata)
		if frames == 0 {
			first = metadata.PTS
			if !metadata.KeyFrame {
				t.Fatal("missing initial random access frame")
			}
		}
		last = metadata.PTS
		totalEncode += metadata.EncodeTime
		if metadata.Width != 1920 || metadata.Height != 1080 {
			t.Fatalf("geometry %+v", metadata)
		}
		var rebuilt []byte
		dep := &codecs.H265Depacketizer{}
		for _, payload := range payloader.Payload(128, sample.Data) {
			packets++
			wireBytes += len(payload) + 40 // minimum IPv4/UDP/RTP; excludes SRTP/retries
			data, e := dep.Unmarshal(payload)
			if e != nil {
				return e
			}
			rebuilt = append(rebuilt, data...)
		}
		if !bytes.Equal(sample.Data, rebuilt) {
			t.Fatalf("RTP round trip changed frame %d: %d -> %d bytes", frames, len(sample.Data), len(rebuilt))
		}
		if frames == 0 {
			for _, typ := range []byte{32, 33, 34} {
				if !bytes.Contains(rebuilt, []byte{0, 0, 0, 1, typ << 1, 1}) {
					t.Fatalf("missing HEVC parameter set %d", typ)
				}
			}
		}
		if output != nil {
			if e := binary.Write(output, binary.BigEndian, uint32(len(rebuilt))); e != nil {
				return e
			}
			if _, e := output.Write(rebuilt); e != nil {
				return e
			}
		}
		frames++
		if frames >= 120 {
			return complete
		}
		return nil
	})
	if !errors.Is(err, complete) {
		t.Fatalf("HEVC failed after %d frames: %v", frames, err)
	}
	t.Logf("HEVC 1080p60: %d frames, %.1f fps, mean encode %s, %d packets, %d minimum wire bytes (synthetic; not matched-quality savings)", frames, float64(frames-1)/(last-first).Seconds(), totalEncode/time.Duration(frames), packets, wireBytes)
}

func TestNativeHEVCAndH264ShareCaptureWithoutSharingEncoder(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("native helper not configured")
	}
	pool := newCapturePool(NewFrameSource)
	defer pool.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	opts := SourceOptions{Kind: "native-synthetic", HelperPath: helper, FPS: 60, MaxWidth: 1280, MaxHeight: 720, Bitrate: 4000}
	inputs := make(map[VideoCodec]FrameSource)
	frames := make(map[VideoCodec]chan media.Sample)
	failures := make(chan error, 2)
	for _, codec := range []VideoCodec{VideoCodecH264, VideoCodecH265} {
		opts.Codec = codec
		source, err := pool.Subscribe(opts)
		if err != nil {
			t.Fatal(err)
		}
		inputs[codec] = source
		frames[codec] = make(chan media.Sample, 4)
		if source.Codec() != codec {
			t.Fatal("codec identity changed")
		}
		ch := frames[codec]
		go func() {
			failures <- source.Stream(ctx, func(s media.Sample) error {
				select {
				case ch <- s:
				default:
				}
				return nil
			})
		}()
	}
	wait := func(codec VideoCodec, width int, key bool) media.Sample {
		t.Helper()
		for {
			select {
			case s := <-frames[codec]:
				m := s.Metadata.(FrameMetadata)
				if m.Width == width && (!key || m.KeyFrame) {
					return s
				}
			case err := <-failures:
				t.Fatalf("native variant stopped: %v", err)
			case <-ctx.Done():
				t.Fatal("mixed codec frame deadline exceeded")
			}
		}
	}
	h264 := wait(VideoCodecH264, 1280, true)
	hevc := wait(VideoCodecH265, 1280, true)
	if len(h264.Data) < 6 || h264.Data[4]&31 != 7 {
		t.Fatal("H.264 SPS missing")
	}
	if len(hevc.Data) < 6 || (hevc.Data[4]>>1)&63 != 32 {
		t.Fatal("HEVC VPS missing")
	}
	config := sourceConfiguration(opts)
	config.MaxWidth = 640
	config.MaxHeight = 360
	if err := inputs[VideoCodecH265].(AdaptiveFrameSource).Configure(ctx, config); err != nil {
		t.Fatal(err)
	}
	wait(VideoCodecH265, 640, true)
	wait(VideoCodecH264, 1280, false)
	if err := inputs[VideoCodecH265].(AdaptiveFrameSource).Configure(ctx, sourceConfiguration(opts)); err != nil {
		t.Fatal(err)
	}
	wait(VideoCodecH265, 1280, true)
	wait(VideoCodecH264, 1280, false)
	if _, variants := pool.Counts(); variants != 2 {
		t.Fatalf("mixed codec variants: %d", variants)
	}
}
