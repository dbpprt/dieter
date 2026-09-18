package remotedesktop

import (
	"bytes"
	"context"
	"errors"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
	"google.golang.org/protobuf/proto"
	"os"
	"testing"
	"time"
)

func TestNativeReferenceRecovery(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("native helper not configured")
	}
	for _, codec := range []VideoCodec{VideoCodecH264, VideoCodecH265} {
		t.Run(string(codec), func(t *testing.T) {
			source, err := NewFrameSource(SourceOptions{Kind: "native-synthetic", HelperPath: helper, Codec: codec, RecoveryID: "test", FPS: 60, MaxWidth: 1280, MaxHeight: 720, Bitrate: 4000})
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 8*time.Second)
			defer cancel()
			var anchor uint64
			frames := 0
			recoveries := 0
			fallback := false
			var unacknowledgedAt time.Time
			done := errors.New("verified reference recovery")
			err = source.Stream(ctx, func(sample media.Sample) error {
				frames++
				m := sample.Metadata.(FrameMetadata)
				if frames < 4 {
					t.Logf("frame %+v", m)
				}
				if m.HasLTR && anchor == 0 {
					if err := source.(referenceSource).AcknowledgeReference(ctx, m); err != nil {
						return err
					}
					anchor = m.ID
				}
				if frames == 30 || frames == 60 {
					source.(referenceSource).RequestRecovery()
				}
				if m.RecoveryReference != 0 && !m.KeyFrame {
					if m.RecoveryReference != anchor {
						t.Fatalf("wrong anchor %d want %d", m.RecoveryReference, anchor)
					}
					recoveries++
					t.Logf("%s recovery frame %d from acknowledged frame %d, %d bytes", codec, m.ID, anchor, len(sample.Data))
					if recoveries == 1 {
						return source.(referenceSource).AcknowledgeReference(ctx, m)
					}
					// Withhold its ACK and send no further repair requests. The
					// bounded deadline must reset the dependency chain by itself.
					unacknowledgedAt = time.Now()
				}
				if !unacknowledgedAt.IsZero() && m.KeyFrame {
					if elapsed := time.Since(unacknowledgedAt); elapsed > 500*time.Millisecond {
						t.Fatalf("unacknowledged recovery took %s to fall back", elapsed)
					}
					fallback = true
					return done
				}
				return nil
			})
			if !errors.Is(err, done) || recoveries != 2 || !fallback {
				t.Fatalf("frames=%d anchor=%d recoveries=%d fallback=%t: %v", frames, anchor, recoveries, fallback, err)
			}
		})
	}
}

func TestReferenceAcknowledgmentsAreExactBoundedAndGenerationScoped(t *testing.T) {
	now := time.Now()
	var r referenceTracker
	m := FrameMetadata{ID: 1, Generation: 1, NativeGeneration: 10, HasLTR: true, LTRToken: 0, KeyFrame: true}
	first := r.offer(now, m, 100)
	for i := 2; i < 100; i++ {
		m.ID = uint64(i)
		m.KeyFrame = false
		r.offer(now, m, uint32(i*100))
	}
	if len(r.pending) != 8 {
		t.Fatal("unbounded reference challenges")
	}
	forged := dieterv1.RemoteDesktopReference{Generation: first.Generation, FrameId: first.FrameId, RtpTimestamp: first.RtpTimestamp}
	forged.RtpTimestamp++
	if _, ok := r.acknowledge(now, &forged); ok {
		t.Fatal("accepted wrong decoded timestamp")
	}
	ack, ok := r.acknowledge(now.Add(150*time.Millisecond), first)
	if !ok || ack.NativeGeneration != 10 || ack.ID != 1 {
		t.Fatal("slow receiver lost its original challenge")
	}
	if _, ok = r.acknowledge(now, first); ok {
		t.Fatal("replayed anchor ack")
	}
	recovery := FrameMetadata{ID: 100, Generation: 1, NativeGeneration: 10, RecoveryReference: 1}
	challenge := r.offer(now, recovery, 10000)
	if _, ok = r.acknowledge(now, challenge); !ok {
		t.Fatal("decoded recovery did not rearm repair")
	}
	m.ID = 101
	m.KeyFrame = true
	m.Generation = 2
	m.NativeGeneration = 11
	challenge = r.offer(now, m, 11000)
	if _, ok = r.acknowledge(now, first); ok {
		t.Fatal("old generation acknowledged")
	}
	if _, ok = r.acknowledge(now.Add(3*time.Second), challenge); ok {
		t.Fatal("stale acknowledgment")
	}
}
func TestReferenceEncodersNeverMergeAcrossViewers(t *testing.T) {
	pool := newCapturePool(func(SourceOptions) (FrameSource, error) { return &pooledTestSource{}, nil })
	defer pool.Close()
	opts := SourceOptions{Kind: "test", RecoveryID: "viewer-a", FPS: 60, Bitrate: 6000, MaxWidth: 1280, MaxHeight: 720}
	a, err := pool.Subscribe(opts)
	if err != nil {
		t.Fatal(err)
	}
	opts.RecoveryID = "viewer-b"
	opts.Bitrate = 5000
	b, err := pool.Subscribe(opts)
	if err != nil {
		t.Fatal(err)
	}
	config := sourceConfiguration(opts)
	if err = a.(AdaptiveFrameSource).Configure(t.Context(), config); err != nil {
		t.Fatal(err)
	}
	if a.(*sharedSource).variant == b.(*sharedSource).variant {
		t.Fatal("viewer-specific references leaked into a shared encoder")
	}
	if _, encoders := pool.Counts(); encoders != 2 {
		t.Fatalf("encoders=%d", encoders)
	}
}
func TestReferenceDependencyDescriptorUsesAnchorAndWraps(t *testing.T) {
	m := FrameMetadata{ID: 65538, RecoveryReference: 65500}
	data := frameDescriptor(m, true, true)
	if !bytes.Equal(data, []byte{0xf8, 1, 2, 0, 38 << 2}) {
		t.Fatalf("descriptor=%x", data)
	}
	m.RecoveryReference = 1
	if frameDescriptor(m, true, true) != nil {
		t.Fatal("encoded unrepresentable reference age")
	}
	m.KeyFrame = true
	m.Width = 1920
	m.Height = 1080
	if len(frameDescriptor(m, true, true)) != 8 {
		t.Fatal("key frame lacks dimensions")
	}
}

func TestReferenceFeedbackRequiresSessionEpochAndIncreasingSequence(t *testing.T) {
	now := time.Now()
	s := &Session{inputEpoch: bytes.Repeat([]byte{7}, 16), referenceQueue: make(chan FrameMetadata, 8)}
	challenge := s.references.offer(now, FrameMetadata{ID: 1, Generation: 1, HasLTR: true}, 100)
	send := func(epoch []byte, sequence uint64, values ...*dieterv1.RemoteDesktopReference) {
		raw, err := proto.Marshal(&dieterv1.RemoteDesktopReceiverFeedback{ProtocolVersion: inputProtocolVersion, InputEpoch: epoch, Sequence: sequence, DecodedReferences: values})
		if err != nil {
			t.Fatal(err)
		}
		s.receiveFeedback(raw)
	}
	send(bytes.Repeat([]byte{8}, 16), 1, challenge)
	if len(s.referenceQueue) != 0 {
		t.Fatal("accepted another session's acknowledgment")
	}
	send(s.inputEpoch, 1, challenge)
	if len(s.referenceQueue) != 1 {
		t.Fatal("valid decoder acknowledgement not delivered")
	}
	<-s.referenceQueue
	next := s.references.offer(now, FrameMetadata{ID: 2, Generation: 1, RecoveryReference: 1}, 200)
	send(s.inputEpoch, 1, next)
	if len(s.referenceQueue) != 0 {
		t.Fatal("accepted replayed feedback sequence")
	}
	send(s.inputEpoch, 2, next)
	if len(s.referenceQueue) != 1 {
		t.Fatal("fresh recovery acknowledgment rejected")
	}
}
