package remotedesktop

import (
	"context"
	"errors"
	"strings"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/cc"
	"github.com/pion/interceptor/pkg/gcc"
	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"google.golang.org/protobuf/proto"
)

func normalizeConfiguration(c *dieterv1.RemoteDesktopStreamConfiguration) (*dieterv1.RemoteDesktopStreamConfiguration, error) {
	if c == nil {
		return nil, errors.New("stream configuration is required")
	}
	c = proto.Clone(c).(*dieterv1.RemoteDesktopStreamConfiguration)
	if c.DisplayId == "" {
		c.DisplayId = "primary"
	}
	if c.MaxWidth == 0 {
		c.MaxWidth = 3840
	}
	if c.MaxHeight == 0 {
		c.MaxHeight = 2160
	}
	if c.MaxFps == 0 {
		c.MaxFps = 60
	}
	if c.MaxBitrateKbps == 0 {
		c.MaxBitrateKbps = 12000
	}
	if len(c.DisplayId) > 64 || c.MaxWidth < 320 || c.MaxWidth > 3840 || c.MaxHeight < 180 || c.MaxHeight > 2160 || c.MaxFps < 1 || c.MaxFps > 60 || c.MaxBitrateKbps < 100 || c.MaxBitrateKbps > 100000 || c.Quality < 0 || c.Quality > 2 {
		return nil, errors.New("invalid stream configuration limits")
	}
	return c, nil
}
func requestConfiguration(r *dieterv1.StartRemoteDesktopRequest) *dieterv1.RemoteDesktopStreamConfiguration {
	return &dieterv1.RemoteDesktopStreamConfiguration{DisplayId: r.GetDisplayId(), MaxWidth: r.GetMaxWidth(), MaxHeight: r.GetMaxHeight(), MaxFps: r.GetMaxFps(), MaxBitrateKbps: r.GetMaxBitrateKbps(), Quality: r.GetQuality(), EmbeddedCursor: r.GetEmbeddedCursor()}
}
func nativeConfiguration(c *dieterv1.RemoteDesktopStreamConfiguration) StreamConfiguration {
	return StreamConfiguration{DisplayID: c.DisplayId, MaxWidth: int(c.MaxWidth), MaxHeight: int(c.MaxHeight), FPS: int(c.MaxFps), BitrateKbps: int(c.MaxBitrateKbps), EmbeddedCursor: c.EmbeddedCursor}
}
func (m *Manager) SessionState(id string) (*dieterv1.RemoteDesktopSessionState, error) {
	m.mu.Lock()
	s := m.session
	m.mu.Unlock()
	if s == nil || s.id != id {
		return nil, ErrNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, ErrNotFound
	}
	return proto.Clone(s.status).(*dieterv1.RemoteDesktopSessionState), nil
}
func (m *Manager) UpdateSession(ctx context.Context, r *dieterv1.UpdateRemoteDesktopSessionRequest) (*dieterv1.RemoteDesktopSessionState, error) {
	m.mu.Lock()
	s := m.session
	m.mu.Unlock()
	if s == nil || s.id != r.GetSessionId() {
		return nil, ErrNotFound
	}
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return nil, ErrNotFound
	}
	if r.Configuration != nil {
		config, err := normalizeConfiguration(r.Configuration)
		if err != nil {
			return nil, err
		}
		source, ok := s.source.(AdaptiveFrameSource)
		if !ok {
			return nil, errors.New("capture backend does not support live configuration")
		}
		s.configurationMu.Lock()
		s.releaseInput()
		err = source.Configure(ctx, nativeConfiguration(config))
		if err == nil {
			s.mu.Lock()
			s.status.Configuration = config
			s.applied = nativeConfiguration(config)
			s.configurationRevision++
			s.mu.Unlock()
		}
		s.configurationMu.Unlock()
		if err != nil {
			return nil, err
		}
	}
	if r.Refresh {
		if source, ok := s.source.(ControlledFrameSource); ok {
			source.RequestKeyFrame()
		}
	}
	return m.SessionState(s.id)
}

func newMediaAPI(settings webrtc.SettingEngine, source FrameSource) (*webrtc.API, *packetPacer, *cc.BandwidthEstimator, error) {
	engine := &webrtc.MediaEngine{}
	capability := codecCapability(source.Codec())
	if native, ok := source.(interface{ CodecParameters() string }); ok {
		capability.SDPFmtpLine = native.CodecParameters()
	}
	if err := engine.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: capability, PayloadType: 102}, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, nil, nil, err
	}
	registry := &interceptor.Registry{}
	pacer := newPacketPacer(4_000_000)
	var estimator cc.BandwidthEstimator
	controller, err := cc.NewInterceptor(func() (cc.BandwidthEstimator, error) {
		return gcc.NewSendSideBWE(gcc.SendSideBWEInitialBitrate(4_000_000), gcc.SendSideBWEMinBitrate(100_000), gcc.SendSideBWEMaxBitrate(100_000_000), gcc.SendSideBWEPacer(pacer))
	})
	if err != nil {
		pacer.Close()
		return nil, nil, nil, err
	}
	controller.OnNewPeerConnection(func(_ string, value cc.BandwidthEstimator) { estimator = value })
	registry.Add(controller)
	var refresh func()
	if controlled, ok := source.(ControlledFrameSource); ok {
		refresh = controlled.RequestKeyFrame
	}
	engine.RegisterFeedback(webrtc.RTCPFeedback{Type: "nack"}, webrtc.RTPCodecTypeVideo)
	engine.RegisterFeedback(webrtc.RTCPFeedback{Type: "nack", Parameter: "pli"}, webrtc.RTPCodecTypeVideo)
	if err = webrtc.ConfigureTWCCHeaderExtensionSender(engine, registry); err == nil {
		registry.Add(retransmissionFactory{refresh: refresh})
		err = webrtc.ConfigureRTCPReports(registry)
	}
	if err == nil {
		err = webrtc.ConfigureSimulcastExtensionHeaders(engine)
	}
	if err == nil {
		err = webrtc.ConfigureStatsInterceptor(registry)
	}
	if err == nil {
		err = webrtc.ConfigureTWCCSender(engine, registry)
	}
	if err != nil {
		pacer.Close()
		return nil, nil, nil, err
	}
	return webrtc.NewAPI(webrtc.WithSettingEngine(settings), webrtc.WithMediaEngine(engine), webrtc.WithInterceptorRegistry(registry)), pacer, &estimator, nil
}

func (s *Session) nativeEvent(event SourceEvent) {
	if event.State != nil {
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			return
		}
		old := s.status
		v := event.State
		generationChanged := old.DisplayGeneration != v.DisplayGeneration
		old.Width, old.Height, old.Fps, old.BitrateKbps = v.Width, v.Height, v.Fps, v.BitrateKbps
		old.DisplayId, old.DisplayGeneration, old.Encoder, old.EmbeddedCursor = v.DisplayId, v.DisplayGeneration, v.Encoder, v.EmbeddedCursor
		state := proto.Clone(old).(*dieterv1.RemoteDesktopSessionState)
		cursor := s.cursor
		s.mu.Unlock()
		if generationChanged {
			s.hostSendMu.Lock()
			s.lastCursorShapeSent = ""
			s.hostSendMu.Unlock()
		}
		s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_State{State: state}})
		if generationChanged && cursor.GetDisplayGeneration() == state.DisplayGeneration {
			s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_Cursor{Cursor: cursor}})
		}
	}
	if event.Cursor != nil {
		s.mu.Lock()
		if s.cursor != nil && s.cursor.ShapeId == event.Cursor.ShapeId && len(event.Cursor.Png) == 0 {
			event.Cursor.Png = s.cursor.Png
		}
		s.cursor = event.Cursor
		s.mu.Unlock()
		s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_Cursor{Cursor: event.Cursor}})
	}
}

// Heartbeats/state remain responsive, while adaptation consumes independent
// one-second windows and never counts the same frame or receiver report twice.
func (s *Session) adapt() {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	var controller *qualityController
	var revision, previousDrops uint64
	evaluated := time.Now()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
		}
		now := time.Now()
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			return
		}
		state := proto.Clone(s.status).(*dieterv1.RemoteDesktopSessionState)
		feedback, lastFeedback, current, currentRevision := s.receiver, s.lastFeedback, s.applied, s.configurationRevision
		s.mu.Unlock()
		if s.pc.ConnectionState() != webrtc.PeerConnectionStateConnected {
			continue
		}
		if s.control && !lastFeedback.IsZero() && now.Sub(lastFeedback) > 3*time.Second {
			s.close("receiver input heartbeat expired")
			return
		}
		source, ok := s.source.(AdaptiveFrameSource)
		if !ok || state.Configuration == nil {
			continue
		}
		s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_State{State: state}})
		if controller == nil || currentRevision != revision {
			controller = newQualityController(now)
			revision = currentRevision
			evaluated = now
			previousDrops = state.FramesDropped
			s.mu.Lock()
			s.measurements = frameMeasurements{}
			s.mu.Unlock()
			continue
		}
		elapsed := now.Sub(evaluated)
		if elapsed < time.Second {
			continue
		}
		evaluated = now
		s.mu.Lock()
		frames := s.measurements
		s.measurements = frameMeasurements{}
		s.mu.Unlock()
		estimate := 0
		if s.estimator != nil {
			estimate = s.estimator.GetTargetBitrate()
		}
		budget := receiverBudget(now, int(state.Configuration.MaxBitrateKbps), estimate, int(s.remb.Load()), s.rembAt.Load())
		drops := uint64(0)
		if state.FramesDropped >= previousDrops {
			drops = state.FramesDropped - previousDrops
		}
		previousDrops = state.FramesDropped
		desired, reason := controller.next(now, current, state.Configuration, adaptationSample{
			frames: frames, feedback: feedback, feedbackAt: lastFeedback, budget: budget,
			width: int(state.Width), height: int(state.Height), drops: drops, elapsed: elapsed,
		})
		if desired == current {
			continue
		}
		s.configurationMu.Lock()
		s.mu.Lock()
		unchanged := s.configurationRevision == currentRevision && !s.closed
		s.mu.Unlock()
		if unchanged {
			ctx, cancel := context.WithTimeout(s.ctx, 2*time.Second)
			err := source.Configure(ctx, desired)
			cancel()
			if err == nil {
				controller.applied(now, current, desired)
				s.mu.Lock()
				s.applied = desired
				s.mu.Unlock()
				if logger := s.manager.options.Logger; logger != nil {
					logger.Info("remote desktop quality", "session", s.id, "reason", reason,
						"width", desired.MaxWidth, "height", desired.MaxHeight, "fps", desired.FPS,
						"bitrate_kbps", desired.BitrateKbps, "estimate_kbps", estimate/1000,
						"encode_ms", controller.encodeMS, "decode_ms", controller.decodeMS,
						"write_ms", controller.writeMS, "loss", feedback.GetLossFraction())
				}
			} else if logger := s.manager.options.Logger; logger != nil {
				logger.Warn("remote desktop configuration failed", "session", s.id, "error", err)
			}
		}
		s.configurationMu.Unlock()
	}
}

func receiverBudget(now time.Time, ceiling, estimate, remb int, rembAt int64) int {
	budget := ceiling
	if estimate > 0 {
		budget = min(budget, estimate*85/100/1000)
	}
	// A one-off legacy REMB must not permanently pin a recovered TWCC session.
	if remb > 0 && rembAt > 0 && now.Sub(time.Unix(0, rembAt)) < 5*time.Second {
		budget = min(budget, remb)
	}
	return max(100, budget)
}

func (s *Session) streamMedia(sample media.Sample) error {
	metadata, native := sample.Metadata.(FrameMetadata)
	if !native {
		return s.track.WriteSample(sample)
	}
	s.mu.Lock()
	s.status.EncodeMs = float64(metadata.EncodeTime) / float64(time.Millisecond)
	s.status.CaptureDelayMs = float64(metadata.CaptureDelay) / float64(time.Millisecond)
	s.status.FramesDropped = metadata.Dropped + s.transportDrops
	s.status.LastFrameId = metadata.ID
	s.mu.Unlock()
	if s.rtpTrack == nil {
		return errors.New("native RTP track is missing")
	}
	if metadata.Discontinuity && !metadata.KeyFrame {
		s.waitKeyframe = true
		if source, ok := s.source.(ControlledFrameSource); ok {
			source.RequestKeyFrame()
		}
	}
	if s.waitKeyframe && !metadata.KeyFrame {
		return nil
	}
	if metadata.KeyFrame {
		s.waitKeyframe = false
	}
	// Discard only at access-unit boundaries. After a discard, discard dependents
	// until a requested IDR arrives. No unbounded encoded-frame or packet queue.
	age := metadata.CaptureDelay + time.Since(metadata.ReceivedAt)
	if age > 100*time.Millisecond && !metadata.KeyFrame {
		s.waitKeyframe = true
		s.transportDrops++
		if source, ok := s.source.(ControlledFrameSource); ok {
			source.RequestKeyFrame()
		}
		return nil
	}
	if s.packetizer == nil {
		s.packetizer = rtp.NewPacketizerWithOptions(1180, &codecs.H264Payloader{}, rtp.NewRandomSequencer(), 90000)
	}
	packets := s.packetizer.Packetize(sample.Data, 0)
	timestamp := uint32((uint64(metadata.PTS/time.Millisecond) * 90) + (uint64(metadata.PTS%time.Millisecond) * 90 / uint64(time.Millisecond)))
	s.mu.Lock()
	boundaryChanged := metadata.KeyFrame && s.status.MediaGeneration != metadata.Generation
	var boundary *dieterv1.RemoteDesktopSessionState
	if boundaryChanged {
		s.status.MediaGeneration, s.status.MediaTimestamp = metadata.Generation, timestamp
		boundary = proto.Clone(s.status).(*dieterv1.RemoteDesktopSessionState)
	}
	s.mu.Unlock()
	if boundary != nil {
		s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_State{State: boundary}})
	}
	writeBefore := s.pacer.writeNanoseconds.Load()
	for _, packet := range packets {
		packet.Timestamp = timestamp
		if err := s.rtpTrack.WriteRTP(packet); err != nil {
			return err
		}
	}
	s.mu.Lock()
	s.status.FramesSent++
	s.status.QueueMs = float64(s.pacer.writeNanoseconds.Load()-writeBefore) / float64(time.Millisecond)
	s.measurements.frames++
	s.measurements.bytes += uint64(len(sample.Data))
	if !metadata.KeyFrame {
		s.measurements.interFrames++
		s.measurements.encodeMS += s.status.EncodeMs
		s.measurements.writeMS += s.status.QueueMs
	}
	s.mu.Unlock()
	return nil
}

func offerSupportsHigh(sdp string) bool {
	return strings.Contains(strings.ToLower(sdp), "profile-level-id=6400")
}

func (m *Manager) nativeCapabilities(force bool) (*dieterv1.RemoteDesktopCapabilities, error) {
	m.capabilityMu.Lock()
	defer m.capabilityMu.Unlock()
	if !force && m.cachedCapabilities != nil && time.Since(m.capabilitiesAt) < 5*time.Second {
		return proto.Clone(m.cachedCapabilities).(*dieterv1.RemoteDesktopCapabilities), nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	value, err := m.options.CapabilityProbe(ctx, m.options.Source)
	if err != nil {
		return nil, err
	}
	m.cachedCapabilities = proto.Clone(value).(*dieterv1.RemoteDesktopCapabilities)
	m.capabilitiesAt = time.Now()
	return value, nil
}
