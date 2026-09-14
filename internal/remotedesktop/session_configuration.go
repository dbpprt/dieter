package remotedesktop

import (
	"context"
	"errors"
	"math"
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

// This controller uses network budget plus encode/receiver evidence. Spatial
// changes require sustained evidence and are slower than bitrate updates.
func (s *Session) adapt() {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	good, bad := 0, 0
	lastChange := time.Now()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
		}
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			return
		}
		state := proto.Clone(s.status).(*dieterv1.RemoteDesktopSessionState)
		feedback := s.receiver
		lastFeedback := s.lastFeedback
		current := s.applied
		s.mu.Unlock()
		if s.pc.ConnectionState() != webrtc.PeerConnectionStateConnected {
			continue
		}
		if s.control && !lastFeedback.IsZero() && time.Since(lastFeedback) > 3*time.Second {
			s.close("receiver input heartbeat expired")
			return
		}
		source, ok := s.source.(AdaptiveFrameSource)
		if !ok {
			continue
		}
		maxConfig := state.Configuration
		if maxConfig == nil {
			continue
		}
		budget := int(maxConfig.MaxBitrateKbps)
		if s.estimator != nil {
			budget = min(budget, int(float64(s.estimator.GetTargetBitrate())*.85/1000))
		}
		if remb := s.remb.Load(); remb > 0 {
			budget = min(budget, int(remb))
		}
		budget = max(100, budget)
		overloaded := state.EncodeMs > 1000/float64(max(1, current.FPS))*.85 || state.QueueMs > 80 || feedback.GetLossFraction() > .05 || feedback.GetJitterMs() > 80
		if overloaded {
			bad++
			good = 0
		} else {
			good++
			bad = 0
		}
		desired := adaptiveConfiguration(current, maxConfig, feedback, budget, good, bad, time.Since(lastChange) > 3*time.Second)

		if desired != current {
			s.configurationMu.Lock()
			// Reject a policy calculation superseded by a user's configuration update.
			s.mu.Lock()
			unchanged := proto.Equal(s.status.Configuration, maxConfig)
			s.mu.Unlock()
			if unchanged {
				ctx, cancel := context.WithTimeout(s.ctx, 2*time.Second)
				err := source.Configure(ctx, desired)
				cancel()
				if err == nil {
					if desired.MaxWidth != current.MaxWidth || desired.MaxHeight != current.MaxHeight {
						lastChange = time.Now()
					}
					s.mu.Lock()
					s.applied = desired
					s.mu.Unlock()
				}
			}
			s.configurationMu.Unlock()
		}
		state, _ = s.manager.SessionState(s.id)
		if state != nil {
			s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_State{State: state}})
		}
	}
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
	started := time.Now()
	for _, packet := range packets {
		packet.Timestamp = timestamp
		if err := s.rtpTrack.WriteRTP(packet); err != nil {
			return err
		}
	}
	s.mu.Lock()
	s.status.FramesSent++
	s.status.QueueMs = float64(time.Since(started)) / float64(time.Millisecond)
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

func adaptiveConfiguration(current StreamConfiguration, maxConfig *dieterv1.RemoteDesktopStreamConfiguration, feedback *dieterv1.RemoteDesktopReceiverFeedback, budget, good, bad int, resize bool) StreamConfiguration {
	budget = max(100, min(budget, int(maxConfig.MaxBitrateKbps)))
	desired := current
	desired.BitrateKbps = budget
	if bad >= 2 {
		desired.FPS = max(10, current.FPS*3/4)
	} else if good >= 4 {
		desired.FPS = min(int(maxConfig.MaxFps), current.FPS+10)
	}
	// Pixel-rate budget provides a baseline; detail mode spends it on resolution.
	bpp := .075
	if maxConfig.Quality == dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_DETAIL {
		desired.FPS = min(desired.FPS, 30)
		bpp = .065
	}
	if maxConfig.Quality == dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_MOTION && good >= 4 {
		desired.FPS = int(maxConfig.MaxFps)
	}
	if feedback.GetDecodeMs() > 1000/float64(max(1, desired.FPS))*.8 {
		desired.FPS = max(10, desired.FPS*3/4)
	}
	desired.FPS = min(int(maxConfig.MaxFps), desired.FPS)
	if resize {
		scale := math.Min(1, math.Sqrt(float64(budget*1000)/(float64(maxConfig.MaxWidth)*float64(maxConfig.MaxHeight)*float64(max(1, desired.FPS))*bpp)))
		// Quantized dimensions avoid encoder restarts on every estimate fluctuation.
		width := max(640, int(float64(maxConfig.MaxWidth)*scale)/160*160)
		width = min(width, int(maxConfig.MaxWidth))
		height := max(180, int(float64(maxConfig.MaxHeight)*float64(width)/float64(maxConfig.MaxWidth))) &^ 1
		if width < current.MaxWidth*4/5 || (good >= 6 && width > current.MaxWidth*5/4) {
			desired.MaxWidth, desired.MaxHeight = width, min(height, int(maxConfig.MaxHeight))
		}
	}
	if abs64(int64(desired.BitrateKbps-current.BitrateKbps)) < int64(max(100, current.BitrateKbps/10)) {
		desired.BitrateKbps = current.BitrateKbps
	}
	return desired
}
