package remotedesktop

import (
	"context"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/sdp/v3"
	"strings"
	"sync"
	"time"
)

const genericDescriptorURI = "http://www.webrtc.org/experiments/rtp-hdrext/generic-frame-descriptor-00"

type referenceSource interface {
	AcknowledgeReference(context.Context, FrameMetadata) error
	RequestRecovery()
	ReferenceRecoveryEnabled() bool
}

func offerSupportsReferences(raw string) bool {
	var session sdp.SessionDescription
	if session.Unmarshal([]byte(raw)) != nil {
		return false
	}
	for _, media := range session.MediaDescriptions {
		if media.MediaName.Media != "video" {
			continue
		}
		for _, a := range media.Attributes {
			if a.Key == "extmap" {
				parts := strings.Fields(a.Value)
				if len(parts) >= 2 && parts[1] == genericDescriptorURI {
					return true
				}
			}
		}
	}
	return false
}
func requestRecovery(source ControlledFrameSource) {
	if value, ok := source.(referenceSource); ok && value.ReferenceRecoveryEnabled() {
		value.RequestRecovery()
	} else {
		source.RequestKeyFrame()
	}
}

func requestRecoveryWithin(source ControlledFrameSource, window time.Duration) {
	if value, ok := source.(interface{ RequestRecoveryWithin(time.Duration) }); ok {
		value.RequestRecoveryWithin(window)
	} else {
		requestRecovery(source)
	}
}

func recoveryCommand(window time.Duration) nativeCommand {
	return nativeCommand{Kind: "recover", RecoveryWindowMS: min(250, max(50, int(window/time.Millisecond)))}
}

func (s *nativeHelperSource) RequestRecoveryWithin(window time.Duration) {
	_ = s.send(context.Background(), recoveryCommand(window), false)
}
func (s *nativeRendition) RequestRecoveryWithin(window time.Duration) {
	_ = s.command(context.Background(), recoveryCommand(window), false)
}
func (s *sharedSource) RequestRecoveryWithin(window time.Duration) {
	s.pool.mu.Lock()
	source, ok := s.variant.source.(ControlledFrameSource)
	valid := ok && !s.closed
	s.pool.mu.Unlock()
	if valid {
		requestRecoveryWithin(source, window)
	}
}
func referenceCommand(m FrameMetadata) nativeCommand {
	kind := "ack_reference"
	if m.RecoveryReference != 0 {
		kind = "ack_recovery"
	}
	return nativeCommand{Kind: kind, FrameID: m.ID, Generation: m.NativeGeneration, LTRToken: m.LTRToken}
}
func (s *nativeHelperSource) ReferenceRecoveryEnabled() bool { return s.referenceRecovery }
func (s *nativeHelperSource) AcknowledgeReference(ctx context.Context, m FrameMetadata) error {
	return s.send(ctx, referenceCommand(m), true)
}
func (s *nativeHelperSource) RequestRecovery() {
	_ = s.send(context.Background(), nativeCommand{Kind: "recover"}, false)
}
func (s *nativeRendition) ReferenceRecoveryEnabled() bool { return s.template.referenceRecovery }
func (s *nativeRendition) AcknowledgeReference(ctx context.Context, m FrameMetadata) error {
	return s.command(ctx, referenceCommand(m), true)
}
func (s *nativeRendition) RequestRecovery() {
	_ = s.command(context.Background(), nativeCommand{Kind: "recover"}, false)
}
func (s *sharedSource) ReferenceRecoveryEnabled() bool { return s.options.RecoveryID != "" }
func (s *sharedSource) AcknowledgeReference(ctx context.Context, m FrameMetadata) error {
	s.pool.mu.Lock()
	valid := !s.closed && s.generation == m.Generation && s.nativeGeneration == m.NativeGeneration && len(s.variant.subscribers) == 1 && s.options.RecoveryID != ""
	source, _ := s.variant.source.(referenceSource)
	s.pool.mu.Unlock()
	if !valid || source == nil {
		return ErrNotFound
	}
	return source.AcknowledgeReference(ctx, m)
}
func (s *sharedSource) RequestRecovery() {
	s.pool.mu.Lock()
	source, ok := s.variant.source.(referenceSource)
	valid := ok && !s.closed && len(s.variant.subscribers) == 1 && s.options.RecoveryID != ""
	s.pool.mu.Unlock()
	if valid {
		source.RequestRecovery()
	} else {
		s.RequestKeyFrame()
	}
}

type referenceChallenge struct {
	wire  *dieterv1.RemoteDesktopReference
	frame FrameMetadata
	at    time.Time
}
type referenceTracker struct {
	mu           sync.Mutex
	generation   uint64
	pending      []referenceChallenge
	acknowledged bool
}

func (r *referenceTracker) offer(now time.Time, m FrameMetadata, timestamp uint32) *dieterv1.RemoteDesktopReference {
	r.mu.Lock()
	defer r.mu.Unlock()
	if m.KeyFrame || r.generation != m.Generation {
		r.pending = nil
		r.acknowledged = false
		r.generation = m.Generation
	}
	if (!m.HasLTR || r.acknowledged) && m.RecoveryReference == 0 {
		return nil
	}
	// Metadata from the native encoder is trusted only within a bounded lifetime.
	fresh := r.pending[:0]
	for _, p := range r.pending {
		if now.Sub(p.at) < 2*time.Second {
			fresh = append(fresh, p)
		}
	}
	r.pending = fresh
	if len(r.pending) >= 8 {
		return nil
	}
	value := &dieterv1.RemoteDesktopReference{Generation: m.Generation, FrameId: m.ID, RtpTimestamp: timestamp}
	r.pending = append(r.pending, referenceChallenge{wire: value, frame: m, at: now})
	return value
}
func (r *referenceTracker) acknowledge(now time.Time, v *dieterv1.RemoteDesktopReference) (FrameMetadata, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if v == nil || v.Generation != r.generation {
		return FrameMetadata{}, false
	}
	for index, p := range r.pending {
		if r.acknowledged && p.frame.RecoveryReference == 0 {
			continue
		}
		if now.Sub(p.at) >= 0 && now.Sub(p.at) < 2*time.Second && v.Generation == p.wire.Generation && v.FrameId == p.wire.FrameId && v.RtpTimestamp == p.wire.RtpTimestamp {
			r.acknowledged = true
			r.pending = append(r.pending[:index], r.pending[index+1:]...)
			return p.frame, true
		}
	}
	return FrameMetadata{}, false
}
func (s *Session) referenceWorker() {
	for {
		select {
		case <-s.ctx.Done():
			return
		case m := <-s.referenceQueue:
			source, ok := s.source.(referenceSource)
			if !ok {
				continue
			}
			ctx, cancel := context.WithTimeout(s.ctx, nativeCommandTimeout)
			err := source.AcknowledgeReference(ctx, m)
			cancel()
			if err == nil {
				s.mu.Lock()
				s.status.ReferenceAcks++
				if m.RecoveryReference != 0 {
					s.status.ReferenceRecoveries++
				}
				s.mu.Unlock()
			}
		}
	}
}

// RFC draft generic-frame-descriptor-00. Native WebRTC otherwise treats every
// H264/H265 frame as depending on all intervening RTP sequence numbers and
// would withhold a valid LTR recovery frame after a gap. Name the actual anchor.
func frameDescriptor(m FrameMetadata, first, last bool) []byte {
	flags := byte(0x30)
	if last {
		flags |= 0x40
	}
	if !first {
		return []byte{flags}
	}
	flags |= 0x80
	value := []byte{flags, 1, byte(m.ID), byte(m.ID >> 8)}
	if m.KeyFrame {
		return append(value, byte(m.Width>>8), byte(m.Width), byte(m.Height>>8), byte(m.Height))
	}
	diff := uint64(1)
	if m.RecoveryReference != 0 {
		diff = m.ID - m.RecoveryReference
	}
	if diff == 0 || diff >= 1<<14 {
		return nil
	}
	value[0] |= 8
	if diff < 64 {
		return append(value, byte(diff<<2))
	}
	return append(value, byte((diff&63)<<2)|2, byte(diff>>6))
}
