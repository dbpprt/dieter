package remotedesktop

import (
	"context"
	"errors"
	"os"
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
	if len(c.DisplayId) > 64 || c.MaxWidth < 320 || c.MaxWidth > 3840 || c.MaxHeight < 180 || c.MaxHeight > 2160 || c.MaxFps < 1 || c.MaxFps > 120 || c.MaxBitrateKbps < 100 || c.MaxBitrateKbps > 100000 || c.Quality < 0 || c.Quality > 2 {
		return nil, errors.New("invalid stream configuration limits")
	}
	// H.264 level 5.2 supports 4K60, but not 4K120. High refresh is
	// negotiated as at most 1080p; preserve aspect ratio in the capture backend.
	if c.MaxFps > 60 {
		c.MaxWidth, c.MaxHeight = min(c.MaxWidth, 1920), min(c.MaxHeight, 1080)
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
	s := m.sessionFor(id)
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
	s := m.sessionFor(r.GetSessionId())
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
		if err == nil && s.codec == VideoCodecH265 && !hevcModeSupported(config) {
			return nil, errors.New("HEVC mode exceeds 1080p60/40000 kbps; reconnect using H.264")
		}
		if err != nil {
			return nil, err
		}
		source, ok := s.source.(AdaptiveFrameSource)
		if !ok {
			return nil, errors.New("capture backend does not support live configuration")
		}
		s.configurationMu.Lock()
		s.mu.Lock()
		displayChanged := s.status.Configuration.GetDisplayId() != config.DisplayId
		s.mu.Unlock()
		if displayChanged {
			m.controlMu.Lock()
			var restoreErr error
			if m.displayOwner == s {
				_, restoreErr = m.restoreDisplayLocked(ctx)
			}
			m.controlMu.Unlock()
			if restoreErr != nil {
				s.configurationMu.Unlock()
				return nil, restoreErr
			}
		}
		s.releaseInput()
		applied := nativeConfiguration(config)
		if s.pacer != nil {
			percent := int(s.pacer.fecPercent.Load())
			if applied.BitrateKbps*100/(100+percent) < 100 {
				// The encoder floor leaves no room for repair at this ceiling.
				s.pacer.fecPercent.Store(0)
			} else {
				applied.BitrateKbps = fecMediaBudget(applied.BitrateKbps, percent)
			}
		}
		err = source.Configure(ctx, applied)
		if err == nil {
			s.mu.Lock()
			s.status.Configuration = config
			s.applied = applied
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

func newMediaAPI(settings webrtc.SettingEngine, source FrameSource, instrumentation ...interceptor.Factory) (*webrtc.API, *packetPacer, *cc.BandwidthEstimator, error) {
	engine := &webrtc.MediaEngine{}
	capability := codecCapability(source.Codec())
	if native, ok := source.(interface{ CodecParameters() string }); ok {
		capability.SDPFmtpLine = native.CodecParameters()
	}
	if err := engine.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: capability, PayloadType: 102}, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, nil, nil, err
	}
	if err := engine.RegisterHeaderExtension(webrtc.RTPHeaderExtensionCapability{URI: playoutDelayURI}, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, nil, nil, err
	}
	if capable, ok := source.(referenceSource); ok && capable.ReferenceRecoveryEnabled() {
		if err := engine.RegisterHeaderExtension(webrtc.RTPHeaderExtensionCapability{URI: genericDescriptorURI}, webrtc.RTPCodecTypeVideo); err != nil {
			return nil, nil, nil, err
		}
	}
	registry := &interceptor.Registry{}
	for _, factory := range instrumentation {
		registry.Add(factory)
	}
	pacer := newPacketPacer(4_000_000)
	if os.Getenv("DIETER_SCREEN_FEC") != "0" {
		if err := registerFEC(engine); err != nil {
			pacer.Close()
			return nil, nil, nil, err
		}
		registry.Add(fecBindingFactory{pacer: pacer})
	}
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
	registry.Add(immediatePlayoutFactory{})
	registry.Add(transportFeedbackFactory{pacer: pacer})
	var refresh func()
	if controlled, ok := source.(ControlledFrameSource); ok {
		refresh = func() { window, _ := pacer.RecoveryDeadline(); requestRecoveryWithin(controlled, window) }
	}
	engine.RegisterFeedback(webrtc.RTCPFeedback{Type: "nack"}, webrtc.RTPCodecTypeVideo)
	engine.RegisterFeedback(webrtc.RTCPFeedback{Type: "nack", Parameter: "pli"}, webrtc.RTPCodecTypeVideo)
	if err = webrtc.ConfigureTWCCHeaderExtensionSender(engine, registry); err == nil {
		registry.Add(retransmissionFactory{refresh: refresh, deadline: pacer.RecoveryDeadline, metrics: &pacer.recoveryMetrics, generation: pacer.mediaGeneration.Load})
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
		old.EncoderConfiguration = v.EncoderConfiguration
		if generationChanged {
			old.ContentChangedFraction = nil
			old.ContentSamples, old.ContentMeasurementSequence = 0, 0
			s.contentMeasuredAt = time.Time{}
		}
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
	if v := event.Content; v != nil && v.Samples > 0 && v.Sequence > 0 && finiteBound(v.ChangedFraction, 1) && v.ChangedFraction >= 0 {
		s.mu.Lock()
		if !s.closed && s.status != nil && v.Generation == s.status.DisplayGeneration && v.Sequence > s.status.ContentMeasurementSequence {
			s.status.ContentChangedFraction = proto.Float64(v.ChangedFraction)
			s.status.ContentSamples, s.status.ContentMeasurementSequence = v.Samples, v.Sequence
			s.contentMeasuredAt = time.Now()
		}
		s.mu.Unlock()
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
	fastTimer := time.NewTimer(time.Hour)
	fastTimer.Stop()
	defer fastTimer.Stop()
	fastEnabled := os.Getenv("DIETER_SCREEN_FAST_BITRATE") != "0"
	var fast fastBitrateController
	var repair fecController
	var lastFast time.Time
	var controller *qualityController
	var revision, previousDrops uint64
	var idleRefresh idleRefreshController
	evaluated := time.Now()
	for {
		fastWake := false
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
		case <-s.pacer.feedbackReady:
			if !fastEnabled {
				continue
			}
			fastWake = true
		case <-fastTimer.C:
			fastWake = true
		}
		if fastWake {
			// A timer and a fresh notification can become ready together. Apply
			// the same interval gate to both and cancel any obsolete timer.
			if delay := fastBitrateInterval - time.Since(lastFast); delay > 0 {
				fastTimer.Reset(delay)
				continue
			}
			fastTimer.Stop()
		}
		now := time.Now()
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			return
		}
		s.status.FecPercent = uint32(s.pacer.fecPercent.Load())
		s.status.FecPackets = s.pacer.fecPackets.Load()
		s.status.FecBytes = s.pacer.fecBytes.Load()
		s.status.MediaRtpBytes = s.pacer.mediaRTPBytes.Load()
		s.status.RepairRtpBytes = s.pacer.repairRTPBytes.Load()
		s.status.ProbeRtpBytes = s.pacer.probeRTPBytes.Load()
		s.status.FecRtpBytes = s.pacer.fecRTPBytes.Load()
		s.status.RecoveryDiagnostics = s.pacer.recoveryMetrics.snapshot()
		state := proto.Clone(s.status).(*dieterv1.RemoteDesktopSessionState)
		feedback, measuredAt, current, currentRevision := s.receiver, s.receiverMeasuredAt, s.applied, s.configurationRevision
		contentAt := s.contentMeasuredAt
		s.mu.Unlock()
		if s.pc.ConnectionState() != webrtc.PeerConnectionStateConnected {
			continue
		}
		if controller == nil || currentRevision != revision {
			if controller != nil {
				fast = fastBitrateController{observed: now}
			}
			controller = newQualityController(now)
			revision, evaluated, previousDrops = currentRevision, now, state.FramesDropped
			s.mu.Lock()
			s.measurements = frameMeasurements{}
			s.mu.Unlock()
		}
		fresh := feedback != nil && !measuredAt.IsZero() && now.Sub(measuredAt) < 2*time.Second
		if fresh && feedback.RttMs > 0 {
			s.pacer.observeRecoveryRTT(now, time.Duration(feedback.RttMs*float64(time.Millisecond)), measuredAt, current.FPS)
		} else if !fastWake {
			rtt, at := recoveryRTTFromStats(now, s.pc.GetStats())
			s.pacer.observeRecoveryRTT(now, rtt, at, current.FPS)
		}
		s.pacer.mu.Lock()
		transport := s.pacer.transport
		s.pacer.probeCeiling = int(state.GetConfiguration().GetMaxBitrateKbps()) * 1000 * 100 / 85
		s.pacer.mu.Unlock()
		s.adaptFEC(now, &repair, transport)
		s.mu.Lock()
		current = s.applied
		s.mu.Unlock()
		if fastWake {
			lastFast = now
			s.reduceBitrate(now, &fast, controller, state, current, currentRevision, transport)
			continue
		}
		// RTT measures round-trip latency, not available throughput. A route or
		// Wi-Fi latency change alone must not erase acknowledged capacity.
		// Fresh TWCC queue growth/loss and receiver loss govern congestion.
		networkPressure := (transport.fresh(now) && transport.pressure) || now.Before(fast.holdUntil)
		// GCC can retain an old delay-overuse classification through application
		// idle. Fresh packet delivery and receiver measurements gate recovery.
		s.pacer.ObserveNetwork(now, fresh && feedback.LossFraction < .02 && !networkPressure)
		source, ok := s.source.(AdaptiveFrameSource)
		if !ok || state.Configuration == nil {
			continue
		}
		s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_State{State: state}})
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
			estimate = s.pacer.TargetBitrate()
		}
		budget := fecMediaBudget(receiverBudget(now, int(state.Configuration.MaxBitrateKbps), estimate, int(s.remb.Load()), s.rembAt.Load()), int(s.pacer.fecPercent.Load()))
		confirmed := min(budget, s.pacer.ConfirmedBitrate()*85/100/1000)
		// Probe a degraded static desktop, and redraw after a confirmed bitrate
		// increase. Keep the pending redraw until the new encoder configuration
		// is applied; refreshing first could preserve the same blurry picture.
		refreshIdle := func(configuration StreamConfiguration) {
			if idleRefresh.due(now, frames.interFrames < 2, fresh && !networkPressure && feedback.LossFraction < .02,
				configuration.BitrateKbps < int(state.Configuration.MaxBitrateKbps)*4/5) {
				if controlled, ok := s.source.(ControlledFrameSource); ok {
					controlled.RequestKeyFrame()
				}
			}
		}
		drops := uint64(0)
		if state.FramesDropped >= previousDrops {
			drops = state.FramesDropped - previousDrops
		}
		previousDrops = state.FramesDropped
		desired, reason := controller.next(now, current, state.Configuration, adaptationSample{
			frames: frames, feedback: feedback, feedbackAt: measuredAt, budget: budget,
			width: int(state.Width), height: int(state.Height), drops: drops, elapsed: elapsed,
			networkPressure: networkPressure, confirmedBudget: confirmed,
			changedFraction: state.ContentChangedFraction, contentAt: contentAt,
			contentSequence: state.ContentMeasurementSequence, generation: state.DisplayGeneration, inputOrdinal: state.LastInputOrdinal,
		})
		s.mu.Lock()
		s.status.ContentClass = controller.content.class
		s.mu.Unlock()
		desired.BitrateKbps = min(desired.BitrateKbps, fecMediaBudget(int(state.Configuration.MaxBitrateKbps), int(s.pacer.fecPercent.Load())))
		if now.Before(fast.holdUntil) {
			desired.BitrateKbps = min(desired.BitrateKbps, fast.ceiling)
		}
		if desired == current {
			refreshIdle(current)
			continue
		}
		s.configurationMu.Lock()
		s.mu.Lock()
		unchanged := s.configurationRevision == currentRevision && !s.closed
		s.mu.Unlock()
		if unchanged {
			ctx, cancel := context.WithTimeout(s.ctx, nativeStartupTimeout)
			err := source.Configure(ctx, desired)
			cancel()
			if err == nil {
				controller.applied(now, current, desired)
				idleRefresh.configured(current, desired, frames.interFrames < 2)
				current = desired
				s.mu.Lock()
				s.applied = desired
				s.mu.Unlock()
				if logger := s.manager.options.Logger; logger != nil {
					var gccStats map[string]any
					gccRate := 0
					if s.estimator != nil {
						gccStats, gccRate = s.estimator.GetStats(), s.estimator.GetTargetBitrate()
					}
					logger.Info("remote desktop quality", "session", s.id, "reason", reason,
						"width", desired.MaxWidth, "height", desired.MaxHeight, "fps", desired.FPS,
						"bitrate_kbps", desired.BitrateKbps, "estimate_kbps", estimate/1000,
						"encode_ms", controller.encodeMS, "decode_ms", controller.decodeMS,
						"write_ms", controller.writeMS, "loss", feedback.GetLossFraction(),
						"measurement_age_ms", now.Sub(measuredAt).Milliseconds(), "measurement_sequence", feedback.GetMeasurementSequence(),
						"network_pressure", networkPressure, "transport_growth_ms", transport.growthMS,
						"delivered_kbps", transport.deliveredRate/1000, "rtt_ms", feedback.GetRttMs(),
						"gcc_kbps", gccRate/1000, "gcc_usage", gccStats["usage"],
						"media_kbps", float64(frames.bytes*8)/elapsed.Seconds()/1000)
				}
			} else if logger := s.manager.options.Logger; logger != nil {
				logger.Warn("remote desktop configuration failed", "session", s.id, "error", err)
			}
		}
		s.configurationMu.Unlock()
		refreshIdle(current)
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
	if s.packetizer == nil {
		var payloader rtp.Payloader = &codecs.H264Payloader{}
		if s.codec == VideoCodecH265 {
			payloader = &codecs.H265Payloader{}
		}
		s.packetizer = rtp.NewPacketizerWithOptions(1180, payloader, rtp.NewRandomSequencer(), 90000)
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
		s.pacer.mediaGeneration.Store(metadata.Generation)
		s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_State{State: boundary}})
	}
	sendStarted := time.Now()
	s.pacer.BeginFrame(sendStarted)
	defer func() { s.pacer.EndFrame(time.Now()) }()
	writeBefore := s.pacer.writeNanoseconds.Load()
	for index, packet := range packets {
		if id := s.pacer.descriptorID.Load(); id != 0 {
			descriptor := frameDescriptor(metadata, index == 0, index == len(packets)-1)
			if descriptor == nil {
				if source, ok := s.source.(ControlledFrameSource); ok {
					source.RequestKeyFrame()
				}
				return nil
			}
			if err := packet.SetExtension(uint8(id), descriptor); err != nil {
				return err
			}
		}
		packet.Timestamp = timestamp
		if err := s.rtpTrack.WriteRTP(packet); err != nil {
			return err
		}
	}
	s.mu.Lock()
	s.status.FramesSent++
	if metadata.HasLTR {
		s.status.ReferenceRecovery = true
	}
	if metadata.RecoveryReference != 0 && !metadata.KeyFrame {
		s.status.ReferenceRecoveryFrames++
	}
	s.status.SendMs = float64(time.Since(sendStarted)) / float64(time.Millisecond)
	s.status.CaptureToSendMs = float64(metadata.CaptureDelay+time.Since(metadata.ReceivedAt)) / float64(time.Millisecond)
	s.status.PacingBitrateKbps = uint32(s.pacer.TargetBitrate() * 5 / 2 / 1000)
	s.status.QueueMs = float64(s.pacer.writeNanoseconds.Load()-writeBefore) / float64(time.Millisecond)
	s.measurements.frames++
	s.measurements.bytes += uint64(len(sample.Data))
	if !metadata.KeyFrame {
		s.measurements.interFrames++
		s.measurements.encodeMS += s.status.EncodeMs
		s.measurements.writeMS += s.status.QueueMs
		s.measurements.sendMS += s.status.SendMs
		s.measurements.interBytes += uint64(len(sample.Data))
	}
	s.mu.Unlock()
	if s.pacer.descriptorID.Load() != 0 {
		if challenge := s.references.offer(time.Now(), metadata, timestamp); challenge != nil {
			s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_Reference{Reference: challenge}})
		}
	}
	for i := 0; i < 256 && s.pacer.needsProbePadding(time.Now()); i++ {
		padding := s.packetizer.GeneratePadding(1)[0]
		padding.Timestamp = timestamp
		if err := s.rtpTrack.WriteRTP(padding); err != nil {
			return err
		}
	}
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
