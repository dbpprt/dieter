package remotedesktop

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/protocol"
	"github.com/pion/webrtc/v4/pkg/media"
)

const (
	nativeCaptureMagic      = "DTH2"
	nativeCaptureHeaderSize = 64
	maxEncodedFrameBytes    = 16 << 20
	nativeCommandTimeout    = 750 * time.Millisecond
	nativeLivenessTimeout   = 3 * time.Second
)

var nativeStartupTimeout = func() time.Duration {
	if runtime.GOOS == "linux" {
		// Portal source selection is deliberately human-mediated. The helper's
		// command and frame bounds still apply after local authorization. Leave
		// bounded time after the portal's two-minute limit for encoder fallback.
		return 150 * time.Second
	}
	return 10 * time.Second
}()

// FrameMetadata preserves the native monotonic media timeline across idle gaps,
// raw-frame replacement and encoder reconfiguration. ReceivedAt is Go monotonic.
type FrameMetadata struct {
	Overlapped                                    bool // Native encode began while the preceding frame still held its send credit.
	LTRToken, RecoveryReference, NativeGeneration uint64
	HasLTR                                        bool
	ID, Generation                                uint64
	StreamID                                      uint64
	PTS                                           time.Duration
	EncodeTime, CaptureDelay                      time.Duration
	Width, Height                                 int
	Dropped                                       uint64
	KeyFrame                                      bool
	Discontinuity                                 bool
	ReceivedAt                                    time.Time
}

type StreamConfiguration struct {
	DisplayID      string `json:"display_id"`
	MaxWidth       int    `json:"max_width"`
	MaxHeight      int    `json:"max_height"`
	FPS            int    `json:"fps"`
	BitrateKbps    int    `json:"bitrate_kbps"`
	EmbeddedCursor bool   `json:"embedded_cursor"`
}

type AdaptiveFrameSource interface {
	ControlledFrameSource
	Configure(context.Context, StreamConfiguration) error
	SetEventHandler(func(SourceEvent))
}

type nativeInputPayload struct {
	Kind          string  `json:"kind"`
	X             int32   `json:"x"`
	Y             int32   `json:"y"`
	Button        int32   `json:"button"`
	Down          bool    `json:"down"`
	Repeat        bool    `json:"repeat"`
	ClickCount    int32   `json:"click_count"`
	DeltaX        float64 `json:"delta_x"`
	DeltaY        float64 `json:"delta_y"`
	Precise       bool    `json:"precise"`
	Phase         uint32  `json:"phase"`
	MomentumPhase uint32  `json:"momentum_phase"`
	PhysicalKey   uint32  `json:"physical_key"`
	Modifiers     uint32  `json:"modifiers"`
	Text          string  `json:"text"`
	Generation    uint64  `json:"generation"`
	Ordinal       uint64  `json:"ordinal"`
}

type nativeCommand struct {
	OverlapBudgetMS   int                  `json:"overlap_budget_ms,omitempty"`
	RecoveryWindowMS  int                  `json:"recovery_window_ms,omitempty"`
	ReferenceRecovery bool                 `json:"reference_recovery,omitempty"`
	Generation        uint64               `json:"generation,omitempty"`
	LTRToken          uint64               `json:"ltr_token"`
	StreamID          uint64               `json:"stream_id,omitempty"`
	Codec             VideoCodec           `json:"codec,omitempty"`
	Profile           string               `json:"profile,omitempty"`
	FrameID           uint64               `json:"frame_id,omitempty"`
	Version           int                  `json:"version"`
	ID                uint64               `json:"id"`
	Kind              string               `json:"kind"`
	Input             *nativeInputPayload  `json:"input,omitempty"`
	Configuration     *StreamConfiguration `json:"configuration,omitempty"`
}

type SourceEvent struct {
	Content  *nativeContent
	StreamID uint64
	Err      error
	Cursor   *dieterv1.RemoteDesktopCursor
	State    *dieterv1.RemoteDesktopSessionState
}

type nativeContent struct {
	Generation      uint64  `json:"generation"`
	Sequence        uint64  `json:"sequence"`
	Samples         uint32  `json:"samples"`
	ChangedFraction float64 `json:"changed_fraction"`
}

type nativeEvent struct {
	Content               *nativeContent                      `json:"content"`
	FrameOverlapSupported bool                                `json:"frame_overlap_supported"`
	StreamID              uint64                              `json:"stream_id"`
	Version               int                                 `json:"version"`
	Ack                   uint64                              `json:"ack"`
	Error                 string                              `json:"error"`
	Cursor                *dieterv1.RemoteDesktopCursor       `json:"cursor"`
	State                 *dieterv1.RemoteDesktopSessionState `json:"state"`
}

type nativeWrite struct {
	command nativeCommand
	done    chan error
}

type nativeHelperSource struct {
	overlapSupported                        atomic.Bool
	longCommands                            atomic.Int32
	path, display, profile, portalStatePath string
	codec                                   VideoCodec
	fps, bitrateKbps, maxWidth, maxHeight   int
	logger                                  *slog.Logger
	synthetic, embeddedCursor, inputAllowed bool
	multiplex                               bool
	referenceRecovery                       bool
	ready                                   chan struct{}

	mu            sync.Mutex
	writes        chan nativeWrite
	stopped       chan struct{}
	stoppedErr    error
	pending       map[uint64]chan error
	configuration *StreamConfiguration
	onEvent       func(SourceEvent)
	sequence      atomic.Uint64
}

func (s *nativeHelperSource) Description() string {
	if runtime.GOOS == "linux" {
		return "Linux GStreamer native " + string(s.Codec())
	}
	return "ScreenCaptureKit / VideoToolbox hardware " + string(s.Codec())
}
func (s *nativeHelperSource) Codec() VideoCodec {
	if s.codec == VideoCodecH265 {
		return VideoCodecH265
	}
	return VideoCodecH264
}
func (s *nativeHelperSource) CodecParameters() string {
	if s.Codec() == VideoCodecH265 {
		return hevcFMTP
	}
	profile := "42e034"
	if s.profile == "high" {
		profile = "640034"
	}
	return "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=" + profile
}
func (s *nativeHelperSource) SetEventHandler(f func(SourceEvent)) {
	s.mu.Lock()
	s.onEvent = f
	s.mu.Unlock()
}

func (s *nativeHelperSource) send(ctx context.Context, command nativeCommand, acknowledge bool) error {
	timeout := nativeCommandTimeout
	if command.Kind == "create" || command.Kind == "remove" || command.Kind == "configure" || command.Kind == "frame_consumed" {
		timeout = nativeStartupTimeout
	} else if command.Kind == "heartbeat" {
		// A scheduling stall must not have a shorter lifetime than the native
		// watchdog. Interactive input keeps its independent, short deadline.
		timeout = nativeLivenessTimeout
	}
	longCommand := runtime.GOOS == "linux" && (command.Kind == "create" || command.Kind == "remove" || command.Kind == "configure")
	if longCommand {
		s.longCommands.Add(1)
		defer s.longCommands.Add(-1)
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	command.Version, command.ID = protocol.Number, s.sequence.Add(1)
	job := nativeWrite{command: command, done: make(chan error, 1)}
	s.mu.Lock()
	writes, stopped := s.writes, s.stopped
	if writes == nil {
		s.mu.Unlock()
		return errors.New("native helper is not ready")
	}
	if acknowledge {
		s.pending[command.ID] = job.done
	}
	s.mu.Unlock()
	defer func() {
		if acknowledge {
			s.mu.Lock()
			delete(s.pending, command.ID)
			s.mu.Unlock()
		}
	}()
	select {
	case writes <- job:
	case <-stopped:
		return s.stopError()
	case <-ctx.Done():
		return fmt.Errorf("native helper %s enqueue: %w", command.Kind, ctx.Err())
	}
	if !acknowledge {
		return nil
	}
	select {
	case err := <-job.done:
		return err
	case <-stopped:
		return s.stopError()
	case <-ctx.Done():
		return fmt.Errorf("native helper %s acknowledgment: %w", command.Kind, ctx.Err())
	}
}

func (s *nativeHelperSource) stopError() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stoppedErr != nil {
		return s.stoppedErr
	}
	return errors.New("native helper stopped")
}

func (s *nativeHelperSource) RequestKeyFrame() {
	_ = s.send(context.Background(), nativeCommand{Kind: "refresh"}, false)
}
func (s *nativeHelperSource) DisplayModeChanged(ctx context.Context) error {
	return s.send(ctx, nativeCommand{Kind: "display_changed"}, true)
}
func (s *nativeHelperSource) SetBitrateKbps(bitrate int) {
	s.mu.Lock()
	config := s.currentConfigurationLocked()
	s.mu.Unlock()
	config.BitrateKbps = max(100, min(bitrate, s.bitrateKbps))
	_ = s.Configure(context.Background(), config)
}
func (s *nativeHelperSource) currentConfigurationLocked() StreamConfiguration {
	if s.configuration != nil {
		return *s.configuration
	}
	return StreamConfiguration{DisplayID: normalizedDisplayID(s.display), MaxWidth: s.maxWidth, MaxHeight: s.maxHeight, FPS: s.fps, BitrateKbps: s.bitrateKbps, EmbeddedCursor: s.embeddedCursor}
}
func (s *nativeHelperSource) Configure(ctx context.Context, config StreamConfiguration) error {
	s.mu.Lock()
	running := s.writes != nil
	if !running {
		s.configuration = &config
	}
	s.mu.Unlock()
	if !running {
		return nil
	}
	if err := s.send(ctx, nativeCommand{Kind: "configure", Configuration: &config}, true); err != nil {
		return err
	}
	s.mu.Lock()
	s.configuration = &config
	s.mu.Unlock()
	return nil
}

func (s *nativeHelperSource) SendInput(ctx context.Context, input *dieterv1.RemoteDesktopInput) error {
	payload, err := translateNativeInput(input)
	if err != nil {
		return err
	}
	return s.send(ctx, nativeCommand{Kind: "input", Input: payload}, true)
}
func (s *nativeHelperSource) ReleaseInput(ctx context.Context) {
	_ = s.send(ctx, nativeCommand{Kind: "input", Input: &nativeInputPayload{Kind: "release_all"}}, true)
}

func translateNativeInput(value *dieterv1.RemoteDesktopInput) (*nativeInputPayload, error) {
	if value == nil {
		return nil, errors.New("remote desktop input is missing")
	}
	p := &nativeInputPayload{Generation: value.GetDisplayGeneration(), Ordinal: value.GetEventOrdinal()}
	switch input := value.GetPayload().(type) {
	case *dieterv1.RemoteDesktopInput_PointerMove:
		p.Kind, p.X, p.Y = "pointer_move", input.PointerMove.GetNormalizedX(), input.PointerMove.GetNormalizedY()
	case *dieterv1.RemoteDesktopInput_PointerButton:
		v := input.PointerButton
		p.Kind, p.X, p.Y, p.Button, p.Down, p.ClickCount, p.Modifiers = "pointer_button", v.GetNormalizedX(), v.GetNormalizedY(), int32(v.GetButton()), v.GetDown(), v.GetClickCount(), v.GetModifiers()
	case *dieterv1.RemoteDesktopInput_Scroll:
		v := input.Scroll
		p.Kind, p.DeltaX, p.DeltaY, p.Precise, p.Modifiers = "scroll", float64(v.GetDeltaX()), float64(v.GetDeltaY()), v.GetPrecise(), v.GetModifiers()
		if v.GetPrecise() {
			p.DeltaX, p.DeltaY = v.GetPreciseDeltaX(), v.GetPreciseDeltaY()
		}
		p.Phase, p.MomentumPhase = v.GetPhase(), v.GetMomentumPhase()
	case *dieterv1.RemoteDesktopInput_Key:
		v := input.Key
		p.Kind, p.PhysicalKey, p.Down, p.Repeat, p.Modifiers = "key", v.GetPhysicalKey(), v.GetDown(), v.GetRepeat(), v.GetModifiers()
	case *dieterv1.RemoteDesktopInput_Text:
		p.Kind, p.Text = "text", input.Text.GetText()
	case *dieterv1.RemoteDesktopInput_ReleaseAll:
		p.Kind = "release_all"
	default:
		return nil, errors.New("remote desktop input payload is missing")
	}
	return p, nil
}

func (s *nativeHelperSource) Stream(ctx context.Context, emit func(media.Sample) error) (result error) {
	s.mu.Lock()
	config := s.currentConfigurationLocked()
	s.mu.Unlock()
	args := []string{"--frame-credits", "true", "--display-id", config.DisplayID, "--fps", strconv.Itoa(config.FPS), "--bitrate-kbps", strconv.Itoa(config.BitrateKbps), "--max-width", strconv.Itoa(config.MaxWidth), "--max-height", strconv.Itoa(config.MaxHeight), "--event-fd", "3", "--profile", s.profile, "--embedded-cursor", strconv.FormatBool(config.EmbeddedCursor), "--allow-input", strconv.FormatBool(s.inputAllowed)}
	if s.referenceRecovery {
		args = append(args, "--reference-recovery", "true")
	}
	if s.multiplex {
		args = append(args, "--multiplex", "true")
	}
	if s.Codec() == VideoCodecH265 {
		args = append(args, "--codec", "H265")
	}
	if s.synthetic {
		args = append(args, "--synthetic", "true")
	}
	if s.portalStatePath != "" {
		args = append(args, "--portal-state", s.portalStatePath)
	}
	processCtx, cancelCause := context.WithCancelCause(ctx)
	cancel := func() { cancelCause(context.Canceled) }
	defer cancel()
	command := exec.CommandContext(processCtx, s.path, args...)
	configureCaptureCommand(command)
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	stdin, err := command.StdinPipe()
	if err != nil {
		return err
	}
	events, eventWriter, err := os.Pipe()
	if err != nil {
		return err
	}
	defer events.Close()
	defer eventWriter.Close()
	command.ExtraFiles = []*os.File{eventWriter}
	stderr := &captureStderr{log: s.logger}
	command.Stderr = stderr
	if err = command.Start(); err != nil {
		return err
	}
	_ = eventWriter.Close()
	s.mu.Lock()
	s.writes = make(chan nativeWrite, 128)
	s.stopped = make(chan struct{})
	s.stoppedErr = nil
	s.pending = make(map[uint64]chan error)
	writes, stopped := s.writes, s.stopped
	if s.ready != nil {
		close(s.ready)
	}
	s.mu.Unlock()
	wait := make(chan error, 1)
	go func() { wait <- command.Wait() }()
	// Closing stdin requests a graceful release/stop; CommandContext escalation is
	// bounded and only owns this child. Pipe closure also interrupts a blocked write.
	defer func() {
		if ctx.Err() == nil {
			if cause := context.Cause(processCtx); cause != nil && !errors.Is(cause, context.Canceled) {
				result = cause
			}
			if result != nil && s.logger != nil {
				s.logger.Warn("native capture helper stopped", "pid", command.Process.Pid, "error", result)
			}
		}
		_ = stdin.Close()
		cancel()
		s.mu.Lock()
		s.stoppedErr = result
		s.writes = nil
		close(stopped)
		s.pending = nil
		s.mu.Unlock()
		select {
		case <-wait:
		case <-time.After(3 * time.Second):
		}
	}()
	go func() {
		for {
			select {
			case <-processCtx.Done():
				_ = stdin.Close()
				return
			case job := <-writes:
				if f, ok := stdin.(*os.File); ok {
					_ = f.SetWriteDeadline(time.Now().Add(nativeCommandTimeout))
				}
				raw, e := json.Marshal(job.command)
				if e == nil && len(raw) <= 16<<10 {
					_, e = stdin.Write(append(raw, '\n'))
				} else if e == nil {
					e = errors.New("native command exceeds limit")
				}
				if e != nil {
					select {
					case job.done <- e:
					default:
					}
					cancelCause(fmt.Errorf("native helper %s write: %w", job.command.Kind, e))
					return
				}
			}
		}
	}()
	mailbox := newNativeEventMailbox()
	liveness := &nativeLiveness{at: time.Now()}
	var startupComplete atomic.Bool
	go mailbox.run(processCtx, func(event SourceEvent) {
		s.mu.Lock()
		handler := s.onEvent
		s.mu.Unlock()
		if handler != nil {
			handler(event)
		}
	})
	go func() {
		scanner := bufio.NewScanner(events)
		scanner.Buffer(make([]byte, 4096), 384<<10)
		for scanner.Scan() {
			var event nativeEvent
			if json.Unmarshal(scanner.Bytes(), &event) != nil || event.Version != protocol.Number {
				cancelCause(errors.New("invalid native helper event"))
				return
			}
			liveness.acknowledge(event.Ack, s.sequence.Load(), time.Now())
			if event.FrameOverlapSupported {
				s.overlapSupported.Store(true)
			}
			s.mu.Lock()
			done := s.pending[event.Ack]
			s.mu.Unlock()
			if done != nil {
				var e error
				if event.Error != "" {
					e = errors.New(event.Error)
				}
				select {
				case done <- e:
				default:
				}
			}
			if event.State != nil || event.Cursor != nil || event.Content != nil || (event.Ack == 0 && event.Error != "") {
				value := SourceEvent{Cursor: event.Cursor, State: event.State, Content: event.Content, StreamID: event.StreamID}
				if event.Ack == 0 && event.Error != "" {
					value.Err = errors.New(event.Error)
				}
				if !mailbox.push(value) {
					cancelCause(errors.New("native helper event stream limit exceeded"))
					return
				}
			}
		}
		if err := scanner.Err(); err != nil {
			cancelCause(fmt.Errorf("native helper event reader: %w", err))
		} else {
			cancelCause(nativeCaptureFailure(errNativeHelperStopped, stderr.String()))
		}
	}()
	go func() {
		timer := time.NewTicker(500 * time.Millisecond)
		defer timer.Stop()
		for {
			select {
			case <-processCtx.Done():
				return
			case <-timer.C:
				// The bounded pipe writer still reports write failures. Do not
				// serialize the cadence behind an individual acknowledgment.
				if err := s.send(processCtx, nativeCommand{Kind: "heartbeat"}, false); err != nil {
					cancelCause(fmt.Errorf("native helper heartbeat enqueue: %w", err))
					return
				}
				limit := nativeLivenessTimeout
				if runtime.GOOS == "linux" && (!startupComplete.Load() || s.longCommands.Load() > 0) {
					// A first Wayland stream may be blocked in the local portal
					// chooser, and encoder lifecycle operations are synchronous in
					// the helper. Restore the strict watchdog between those bounds.
					limit = nativeStartupTimeout
				}
				if ack, age := liveness.snapshot(time.Now()); age > limit {
					if s.logger != nil {
						s.logger.Warn("native helper IPC stalled", "pid", command.Process.Pid, "lastAck", ack,
							"ackAgeMs", age.Milliseconds(), "issuedCommands", s.sequence.Load(), "queuedCommands", len(writes))
					}
					cancelCause(errors.New("native capture helper unresponsive"))
					return
				}
			}
		}
	}()
	// Deadline includes the first full access unit, not merely the magic bytes.
	first := time.AfterFunc(nativeStartupTimeout, func() { cancelCause(errors.New("native helper first frame timed out")) })
	defer first.Stop()
	magic := make([]byte, 4)
	if _, err = io.ReadFull(stdout, magic); err != nil {
		return nativeCaptureFailure(err, stderr.String())
	}
	expectedMagic := nativeCaptureMagic
	if s.multiplex {
		expectedMagic = "DTH3"
	}
	if string(magic) != expectedMagic {
		return fmt.Errorf("native helper protocol mismatch: %q", magic)
	}
	// Return the single encoder credit only after the whole access unit has
	// passed transport pacing. The helper keeps the latest raw surface, so no
	// encoded reference frame is replaced and congestion cannot trigger IDR storms.
	var previousSend time.Duration
	for {
		var streamID uint64
		if s.multiplex {
			if err = binary.Read(stdout, binary.BigEndian, &streamID); err != nil {
				return nativeCaptureFailure(err, stderr.String())
			}
		}
		sample, _, _, readErr := readNativeCaptureSample(stdout, s.fps)
		if readErr != nil {
			if ctx.Err() != nil {
				return nil
			}
			return nativeCaptureFailure(readErr, stderr.String())
		}
		startupComplete.Store(true)
		first.Stop()
		if s.multiplex {
			meta := sample.Metadata.(FrameMetadata)
			meta.StreamID = streamID
			sample.Metadata = meta
		}
		metadata := sample.Metadata.(FrameMetadata)
		if !s.multiplex && s.overlapSupported.Load() && os.Getenv("DIETER_SCREEN_OVERLAP") == "1" {
			s.mu.Lock()
			config = s.currentConfigurationLocked()
			s.mu.Unlock()
			if budget := overlapBudget(sample, config, previousSend); budget > 0 {
				if err = s.send(processCtx, nativeCommand{Kind: "frame_sending", FrameID: metadata.ID, Generation: metadata.NativeGeneration, OverlapBudgetMS: budget}, true); err != nil {
					return err
				}
			}
		}
		startedSend := time.Now()
		if err = emit(sample); err != nil {
			return err
		}
		previousSend = time.Since(startedSend)
		if s.multiplex {
			continue
		}
		if err = s.send(processCtx, nativeCommand{Kind: "frame_consumed", FrameID: metadata.ID, Generation: metadata.NativeGeneration}, true); err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
	}
}

func readNativeCaptureSample(reader io.Reader, fps int) (media.Sample, int64, time.Duration, error) {
	var header [nativeCaptureHeaderSize]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return media.Sample{}, 0, 0, err
	}
	length := int(binary.BigEndian.Uint32(header[:4]))
	if length < 1 || length > maxEncodedFrameBytes {
		return media.Sample{}, 0, 0, errors.New("native frame exceeds bounds")
	}
	m := FrameMetadata{KeyFrame: binary.BigEndian.Uint32(header[4:8])&1 != 0, ID: binary.BigEndian.Uint64(header[8:16]), Generation: binary.BigEndian.Uint64(header[16:24]), PTS: time.Duration(binary.BigEndian.Uint64(header[24:32])), EncodeTime: time.Duration(binary.BigEndian.Uint64(header[32:40])), CaptureDelay: time.Duration(binary.BigEndian.Uint64(header[40:48])), Width: int(binary.BigEndian.Uint32(header[48:52])), Height: int(binary.BigEndian.Uint32(header[52:56])), Dropped: binary.BigEndian.Uint64(header[56:64]), ReceivedAt: time.Now()}
	m.NativeGeneration = m.Generation
	flags := binary.BigEndian.Uint32(header[4:8])
	m.Overlapped = flags&8 != 0 // Additive flag; older readers ignore it without changing frame layout.
	if flags&2 != 0 {
		var value uint64
		if err := binary.Read(reader, binary.BigEndian, &value); err != nil {
			return media.Sample{}, 0, 0, err
		}
		m.LTRToken, m.HasLTR = value, true
	}
	if flags&4 != 0 {
		if err := binary.Read(reader, binary.BigEndian, &m.RecoveryReference); err != nil {
			return media.Sample{}, 0, 0, err
		}
	}

	if m.PTS < 0 || m.Width < 2 || m.Height < 2 || m.Width > 16384 || m.Height > 16384 {
		return media.Sample{}, 0, 0, errors.New("invalid native frame metadata")
	}
	data := make([]byte, length)
	if _, err := io.ReadFull(reader, data); err != nil {
		return media.Sample{}, 0, 0, err
	}
	return media.Sample{Data: data, Duration: time.Second / time.Duration(max(1, fps)), Metadata: m}, int64(m.PTS), m.EncodeTime, nil
}

// Passive enumeration never starts SCStream or posts an input event.
func ProbeCapabilities(ctx context.Context, options SourceOptions) (*dieterv1.RemoteDesktopCapabilities, error) {
	helper, err := resolveCaptureHelper(options.HelperPath)
	if err != nil {
		return nil, err
	}
	args := []string{"--capabilities"}
	if options.Kind == "native-synthetic" {
		args = append(args, "--synthetic", "true")
	}
	if options.PortalStatePath != "" {
		args = append(args, "--portal-state", options.PortalStatePath)
	}
	command := exec.CommandContext(ctx, helper, args...)
	configureCaptureCommand(command)
	var output limitedCaptureOutput
	command.Stdout = &output
	stderr := &limitedCaptureOutput{}
	command.Stderr = stderr
	if err = command.Run(); err != nil {
		if message := strings.TrimSpace(string(stderr.raw)); message != "" {
			return nil, fmt.Errorf("probe native capture helper: %w: %s", err, message)
		}
		return nil, fmt.Errorf("probe native capture helper: %w", err)
	}
	var value dieterv1.RemoteDesktopCapabilities
	if err = json.Unmarshal(output.raw, &value); err != nil {
		return nil, err
	}
	if value.InputProtocolVersion != inputProtocolVersion {
		return nil, fmt.Errorf("capture helper contract %d does not match daemon contract %d", value.InputProtocolVersion, inputProtocolVersion)
	}
	if len(value.Displays) > 32 {
		return nil, errors.New("too many native displays")
	}
	return &value, nil
}

type limitedCaptureOutput struct{ raw []byte }

func (b *limitedCaptureOutput) Write(p []byte) (int, error) {
	if len(b.raw)+len(p) > 128<<10 {
		return 0, errors.New("native output exceeds limit")
	}
	b.raw = append(b.raw, p...)
	return len(p), nil
}
