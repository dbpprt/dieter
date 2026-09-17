package remotedesktop

import (
	"context"
	"errors"
	"sync"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
	"google.golang.org/protobuf/proto"
)

// Capture and encoders belong to the machine, not to a peer. Encoded payloads
// are immutable and shared; every subscriber retains its own transport worker.
type capturePool struct {
	mu       sync.Mutex
	factory  func(SourceOptions) (FrameSource, error)
	variants map[*captureVariant]struct{}
	closed   bool
	native   *nativeMultiplexer
}

type captureVariant struct {
	pool         *capturePool
	options      SourceOptions
	config       StreamConfiguration
	source       FrameSource
	subscribers  map[*sharedSource]struct{} // pool.mu
	ctx          context.Context
	cancel       context.CancelFunc
	once         sync.Once
	state        *dieterv1.RemoteDesktopSessionState
	cursor       *dieterv1.RemoteDesktopCursor
	refreshAt    time.Time
	refreshTimer *time.Timer
	changing     bool
}

type sharedFrame struct {
	sample        media.Sample
	variant       *captureVariant
	ack           chan struct{}
	discontinuity bool
}

type sharedSource struct {
	pool             *capturePool
	variant          *captureVariant // pool.mu
	options          SourceOptions
	frames           chan sharedFrame
	done             chan struct{}
	err              error             // pool.mu
	running          bool              // pool.mu
	closed           bool              // pool.mu
	onEvent          func(SourceEvent) // pool.mu
	generation       uint64            // pool.mu
	nativeGeneration uint64            // pool.mu
	ordinal          uint64            // pool.mu; only this subscriber's acknowledged input
	dropped          bool              // pool.mu
}

func newCapturePool(factory func(SourceOptions) (FrameSource, error)) *capturePool {
	return &capturePool{factory: factory, variants: make(map[*captureVariant]struct{}), native: newNativeMultiplexer()}
}

func sourceConfiguration(o SourceOptions) StreamConfiguration {
	return StreamConfiguration{DisplayID: normalizedDisplayID(o.Display), MaxWidth: o.MaxWidth, MaxHeight: o.MaxHeight,
		FPS: o.FPS, BitrateKbps: o.Bitrate, EmbeddedCursor: o.EmbeddedCursor}
}

func (p *capturePool) Subscribe(options SourceOptions) (FrameSource, error) {
	if options.Codec == "" {
		options.Codec = preferredVideoCodec(options)
	}
	if options.Codec == VideoCodecH265 {
		// H.264 fallback profiles in an offer must not duplicate HEVC Main.
		options.Profile = "main"
	}
	// Match the same defaults as requestConfiguration before constructing a key.
	normalized, err := normalizeConfiguration(&dieterv1.RemoteDesktopStreamConfiguration{DisplayId: options.Display,
		MaxWidth: int32(options.MaxWidth), MaxHeight: int32(options.MaxHeight), MaxFps: int32(options.FPS), MaxBitrateKbps: int32(options.Bitrate), EmbeddedCursor: options.EmbeddedCursor})
	if err != nil {
		return nil, err
	}
	config := nativeConfiguration(normalized)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil, errors.New("screen capture is shutting down")
	}
	variant, err := p.variantLocked(options, config)
	if err != nil {
		return nil, err
	}
	s := &sharedSource{pool: p, variant: variant, options: options, frames: make(chan sharedFrame, 1), done: make(chan struct{}), generation: 1, dropped: true}
	variant.subscribers[s] = struct{}{}
	return s, nil
}

func (p *capturePool) variantLocked(options SourceOptions, config StreamConfiguration) (*captureVariant, error) {
	for v := range p.variants {
		if !v.changing && v.config == config && v.options.Profile == options.Profile && v.options.Codec == options.Codec && v.options.RecoveryID == options.RecoveryID {
			return v, nil
		}
	}
	if len(p.variants) >= maxClients {
		return nil, errors.New("screen hardware encoder limit reached")
	}
	options.Display, options.MaxWidth, options.MaxHeight = config.DisplayID, config.MaxWidth, config.MaxHeight
	options.FPS, options.Bitrate, options.EmbeddedCursor = config.FPS, config.BitrateKbps, config.EmbeddedCursor
	// The manager is the sole input authority. Sharing with a viewer never grants
	// it input, and the helper does not need replacement when the owner changes.
	options.Control = true
	source, err := p.factory(options)
	if err != nil {
		return nil, err
	}
	if native, ok := source.(*nativeHelperSource); ok {
		source, err = p.native.Source(native)
		if err != nil {
			return nil, err
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	v := &captureVariant{pool: p, options: options, config: config, source: source, subscribers: make(map[*sharedSource]struct{}), ctx: ctx, cancel: cancel}
	p.variants[v] = struct{}{}
	return v, nil
}

func (v *captureVariant) start() { v.once.Do(func() { go v.run() }) }
func (v *captureVariant) run() {
	if adaptive, ok := v.source.(AdaptiveFrameSource); ok {
		adaptive.SetEventHandler(v.event)
	}
	err := v.source.Stream(v.ctx, func(sample media.Sample) error {
		ack := make(chan struct{}, 1)
		v.pool.mu.Lock()
		active := 0
		for s := range v.subscribers {
			if !s.running || s.closed {
				continue
			}
			active++
			frame := sharedFrame{sample: sample, variant: v, ack: ack, discontinuity: s.dropped}
			select {
			case s.frames <- frame:
				s.dropped = false
			default:
				select {
				case previous := <-s.frames:
					acknowledgeFrame(previous)
				default:
				}
				frame.discontinuity = true
				select {
				case s.frames <- frame:
				default:
				}
			}
		}
		v.pool.mu.Unlock()
		// The fastest live viewer returns the encoder credit. A single viewer keeps
		// the existing low-latency raw-frame replacement behavior; a slow spectator
		// never holds up the capture or the other peer's socket/pacer.
		if active > 0 {
			select {
			case <-ack:
			case <-v.ctx.Done():
				return v.ctx.Err()
			}
		}
		return nil
	})
	v.pool.mu.Lock()
	defer v.pool.mu.Unlock()
	if err == nil {
		err = errors.New("native capture ended")
	}
	for s := range v.subscribers {
		if !s.closed {
			s.err = err
			s.closeLocked()
		}
	}
}

func acknowledgeFrame(frame sharedFrame) {
	select {
	case frame.ack <- struct{}{}:
	default:
	}
}
func (s *sharedSource) Description() string { return "Shared native desktop capture" }
func (s *sharedSource) Codec() VideoCodec {
	s.pool.mu.Lock()
	defer s.pool.mu.Unlock()
	return s.variant.source.Codec()
}
func (s *sharedSource) CodecParameters() string {
	s.pool.mu.Lock()
	defer s.pool.mu.Unlock()
	if source, ok := s.variant.source.(interface{ CodecParameters() string }); ok {
		return source.CodecParameters()
	}
	return ""
}

func (s *sharedSource) Stream(ctx context.Context, emit func(media.Sample) error) error {
	s.pool.mu.Lock()
	if s.closed {
		err := s.err
		s.pool.mu.Unlock()
		return err
	}
	s.running = true
	v := s.variant
	s.pool.mu.Unlock()
	v.start()
	s.RequestKeyFrame()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.done:
			s.pool.mu.Lock()
			err := s.err
			s.pool.mu.Unlock()
			return err
		case frame := <-s.frames:
			s.pool.mu.Lock()
			valid := !s.closed && s.variant == frame.variant
			if meta, ok := frame.sample.Metadata.(FrameMetadata); ok && valid {
				if meta.Generation < s.nativeGeneration {
					valid = false
				}
				if valid && s.nativeGeneration != 0 && s.nativeGeneration != meta.Generation {
					s.generation++
				}
				if valid {
					s.nativeGeneration = meta.Generation
				}
				meta.Generation, meta.Discontinuity = s.generation, meta.Discontinuity || frame.discontinuity
				frame.sample.Metadata = meta
			}
			s.pool.mu.Unlock()
			var err error
			if valid {
				err = emit(frame.sample)
			}
			acknowledgeFrame(frame)
			if err != nil {
				return err
			}
		}
	}
}

func (v *captureVariant) event(event SourceEvent) {
	v.pool.mu.Lock()
	if event.State != nil {
		v.state = proto.Clone(event.State).(*dieterv1.RemoteDesktopSessionState)
	}
	if event.Cursor != nil {
		cursor := proto.Clone(event.Cursor).(*dieterv1.RemoteDesktopCursor)
		if cursor.ShapeId == v.cursor.GetShapeId() && len(cursor.Png) == 0 {
			cursor.Png = v.cursor.GetPng()
		}
		v.cursor = cursor
	}
	callbacks := make([]func(), 0, len(v.subscribers))
	for s := range v.subscribers {
		if callback := s.eventLocked(event); callback != nil {
			callbacks = append(callbacks, callback)
		}
	}
	v.pool.mu.Unlock()
	for _, callback := range callbacks {
		callback()
	}
}

func (s *sharedSource) eventLocked(event SourceEvent) func() {
	if s.onEvent == nil || s.closed {
		return nil
	}
	var output SourceEvent
	if event.State != nil && event.State.DisplayGeneration >= s.nativeGeneration {
		output.State = proto.Clone(event.State).(*dieterv1.RemoteDesktopSessionState)
		if s.nativeGeneration != 0 && s.nativeGeneration != output.State.DisplayGeneration {
			s.generation++
		}
		s.nativeGeneration = output.State.DisplayGeneration
		output.State.DisplayGeneration = s.generation
		output.State.DisplayId = s.variant.config.DisplayID
	}
	if event.Cursor != nil {
		output.Cursor = proto.Clone(event.Cursor).(*dieterv1.RemoteDesktopCursor)
		output.Cursor.DisplayGeneration, output.Cursor.LastInputOrdinal = s.generation, s.ordinal
	}
	callback := s.onEvent
	return func() { callback(output) }
}

func (s *sharedSource) SetEventHandler(callback func(SourceEvent)) {
	s.pool.mu.Lock()
	s.onEvent = callback
	replay := s.eventLocked(SourceEvent{State: s.variant.state, Cursor: s.variant.cursor})
	s.pool.mu.Unlock()
	if replay != nil {
		replay()
	}
}

func (s *sharedSource) RequestKeyFrame() {
	s.pool.mu.Lock()
	v := s.variant
	if s.closed {
		s.pool.mu.Unlock()
		return
	}
	delay := 250*time.Millisecond - time.Since(v.refreshAt)
	if delay > 0 {
		if v.refreshTimer == nil {
			v.refreshTimer = time.AfterFunc(delay, func() {
				v.pool.mu.Lock()
				v.refreshTimer = nil
				active := len(v.subscribers) > 0 && v.ctx.Err() == nil
				if active {
					v.refreshAt = time.Now()
				}
				v.pool.mu.Unlock()
				if active {
					if source, ok := v.source.(ControlledFrameSource); ok {
						source.RequestKeyFrame()
					}
				}
			})
		}
		s.pool.mu.Unlock()
		return
	}
	v.refreshAt = time.Now()
	s.pool.mu.Unlock()
	if source, ok := v.source.(ControlledFrameSource); ok {
		source.RequestKeyFrame()
	}
}

func (s *sharedSource) SetBitrateKbps(value int) {
	s.pool.mu.Lock()
	config := s.variant.config
	s.pool.mu.Unlock()
	config.BitrateKbps = value
	_ = s.Configure(context.Background(), config)
}

func (s *sharedSource) Configure(ctx context.Context, config StreamConfiguration) error {
	p := s.pool
	p.mu.Lock()
	if s.closed {
		p.mu.Unlock()
		return errors.New("screen subscription closed")
	}
	old := s.variant
	if old.config == config {
		p.mu.Unlock()
		return nil
	}
	// Reconfigure an exclusively owned encoder in place; shared encoders split
	// into a separate rendition so another viewer's ceilings are never changed.
	var next *captureVariant
	for v := range p.variants {
		if v != old && !v.changing && v.config == config && v.options.Profile == s.options.Profile && v.options.Codec == s.options.Codec && v.options.RecoveryID == s.options.RecoveryID {
			next = v
			break
		}
	}
	if len(old.subscribers) == 1 && next == nil {
		old.changing = true
		// Locking across native configuration would deadlock its state callback.
		p.mu.Unlock()
		adaptive, ok := old.source.(AdaptiveFrameSource)
		var err error
		if !ok {
			err = errors.New("capture backend does not support live configuration")
		} else {
			err = adaptive.Configure(ctx, config)
		}
		p.mu.Lock()
		old.changing = false
		if err != nil {
			p.mu.Unlock()
			return err
		}
		if s.variant == old && !s.closed {
			old.config = config
		}
		replay := s.eventLocked(SourceEvent{State: old.state, Cursor: old.cursor})
		p.mu.Unlock()
		if replay != nil {
			replay()
		}
		return nil
	}
	if next == nil {
		var err error
		next, err = p.variantLocked(s.options, config)
		if err != nil {
			p.mu.Unlock()
			return err
		}
	}
	delete(old.subscribers, s)
	if len(old.subscribers) == 0 {
		delete(p.variants, old)
		old.cancel()
		if old.refreshTimer != nil {
			old.refreshTimer.Stop()
		}
		if closer, ok := old.source.(interface{ Close() }); ok {
			closer.Close()
		}
	}
	next.subscribers[s] = struct{}{}
	s.variant = next
	s.generation++
	s.nativeGeneration = 0
	s.dropped = true
	select {
	case frame := <-s.frames:
		acknowledgeFrame(frame)
	default:
	}
	replay := s.eventLocked(SourceEvent{State: next.state, Cursor: next.cursor})
	running := s.running
	p.mu.Unlock()
	if replay != nil {
		replay()
	}
	if running {
		next.start()
	}
	s.RequestKeyFrame()
	return nil
}

func (s *sharedSource) SendInput(ctx context.Context, input *dieterv1.RemoteDesktopInput) error {
	s.pool.mu.Lock()
	v := s.variant
	copy := proto.Clone(input).(*dieterv1.RemoteDesktopInput)
	copy.DisplayGeneration = s.nativeGeneration
	s.pool.mu.Unlock()
	sink, ok := v.source.(InputSink)
	if !ok {
		return errors.New("native input is unavailable")
	}
	if err := sink.SendInput(ctx, copy); err != nil {
		return err
	}
	s.pool.mu.Lock()
	s.ordinal = input.EventOrdinal
	s.pool.mu.Unlock()
	return nil
}
func (s *sharedSource) ReleaseInput(ctx context.Context) { _ = s.ReleaseInputChecked(ctx) }
func (s *sharedSource) InputCapable() bool {
	s.pool.mu.Lock()
	defer s.pool.mu.Unlock()
	_, ok := s.variant.source.(InputSink)
	return ok
}
func (s *sharedSource) ReleaseInputChecked(ctx context.Context) error {
	s.pool.mu.Lock()
	source := s.variant.source
	s.pool.mu.Unlock()
	if checked, ok := source.(interface{ ReleaseInputChecked(context.Context) error }); ok {
		return checked.ReleaseInputChecked(ctx)
	}
	if sink, ok := source.(InputSink); ok {
		sink.ReleaseInput(ctx)
	}
	return nil
}

func (s *sharedSource) Close() { s.pool.mu.Lock(); defer s.pool.mu.Unlock(); s.closeLocked() }
func (s *sharedSource) closeLocked() {
	if s.closed {
		return
	}
	s.closed = true
	close(s.done)
	select {
	case frame := <-s.frames:
		acknowledgeFrame(frame)
	default:
	}
	v := s.variant
	delete(v.subscribers, s)
	if len(v.subscribers) == 0 {
		delete(s.pool.variants, v)
		v.cancel()
		if v.refreshTimer != nil {
			v.refreshTimer.Stop()
		}
		if closer, ok := v.source.(interface{ Close() }); ok {
			closer.Close()
		}
	}
}
func (p *capturePool) Counts() (uint32, uint32) {
	p.mu.Lock()
	defer p.mu.Unlock()
	displays := make(map[string]bool)
	for v := range p.variants {
		display := v.config.DisplayID
		if v.state.GetDisplayId() != "" {
			display = v.state.GetDisplayId()
		}
		displays[display] = true
	}
	return uint32(len(displays)), uint32(len(p.variants))
}
func (p *capturePool) Close() {
	p.mu.Lock()
	p.closed = true
	for v := range p.variants {
		for s := range v.subscribers {
			s.closeLocked()
		}
	}
	p.mu.Unlock()
	p.native.Close()
}
