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
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
)

const (
	nativeCaptureMagic      = "DTH2"
	nativeCaptureHeaderSize = 64
	maxEncodedFrameBytes    = 16 << 20
	nativeCommandTimeout    = 750 * time.Millisecond
	nativeStartupTimeout    = 10 * time.Second
)

// FrameMetadata preserves the native monotonic media timeline across idle gaps,
// raw-frame replacement and encoder reconfiguration. ReceivedAt is Go monotonic.
type FrameMetadata struct {
	ID, Generation           uint64
	PTS                      time.Duration
	EncodeTime, CaptureDelay time.Duration
	Width, Height            int
	Dropped                  uint64
	KeyFrame                 bool
	Discontinuity            bool
	ReceivedAt               time.Time
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
	KeyCode       uint32  `json:"key_code"`
	PhysicalKey   uint32  `json:"physical_key"`
	Modifiers     uint32  `json:"modifiers"`
	Text          string  `json:"text"`
	Generation    uint64  `json:"generation"`
	Ordinal       uint64  `json:"ordinal"`
}

type nativeCommand struct {
	Version       int                  `json:"version"`
	ID            uint64               `json:"id"`
	Kind          string               `json:"kind"`
	Input         *nativeInputPayload  `json:"input,omitempty"`
	Configuration *StreamConfiguration `json:"configuration,omitempty"`
}

type SourceEvent struct {
	Cursor *dieterv1.RemoteDesktopCursor
	State  *dieterv1.RemoteDesktopSessionState
}

type nativeEvent struct {
	Version int                                 `json:"version"`
	Ack     uint64                              `json:"ack"`
	Error   string                              `json:"error"`
	Cursor  *dieterv1.RemoteDesktopCursor       `json:"cursor"`
	State   *dieterv1.RemoteDesktopSessionState `json:"state"`
}

type nativeWrite struct {
	command nativeCommand
	done    chan error
}

type nativeHelperSource struct {
	path, display, profile                  string
	fps, bitrateKbps, maxWidth, maxHeight   int
	logger                                  *slog.Logger
	synthetic, embeddedCursor, inputAllowed bool

	mu            sync.Mutex
	writes        chan nativeWrite
	stopped       chan struct{}
	pending       map[uint64]chan error
	configuration *StreamConfiguration
	onEvent       func(SourceEvent)
	sequence      atomic.Uint64
}

func (s *nativeHelperSource) Description() string {
	return "ScreenCaptureKit / VideoToolbox hardware H.264"
}
func (*nativeHelperSource) Codec() VideoCodec { return VideoCodecH264 }
func (s *nativeHelperSource) CodecParameters() string {
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
	ctx, cancel := context.WithTimeout(ctx, nativeCommandTimeout)
	defer cancel()
	command.Version, command.ID = 2, s.sequence.Add(1)
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
		return errors.New("native helper stopped")
	case <-ctx.Done():
		return ctx.Err()
	}
	if !acknowledge {
		return nil
	}
	select {
	case err := <-job.done:
		return err
	case <-stopped:
		return errors.New("native helper stopped before acknowledgment")
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *nativeHelperSource) RequestKeyFrame() {
	_ = s.send(context.Background(), nativeCommand{Kind: "refresh"}, false)
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
		p.Kind, p.KeyCode, p.PhysicalKey, p.Down, p.Repeat, p.Modifiers = "key", v.GetKeyCode(), v.GetPhysicalKey(), v.GetDown(), v.GetRepeat(), v.GetModifiers()
	case *dieterv1.RemoteDesktopInput_Text:
		p.Kind, p.Text = "text", input.Text.GetText()
	case *dieterv1.RemoteDesktopInput_ReleaseAll:
		p.Kind = "release_all"
	default:
		return nil, errors.New("remote desktop input payload is missing")
	}
	return p, nil
}

func (s *nativeHelperSource) Stream(ctx context.Context, emit func(media.Sample) error) error {
	s.mu.Lock()
	config := s.currentConfigurationLocked()
	s.mu.Unlock()
	args := []string{"--display-id", config.DisplayID, "--fps", strconv.Itoa(config.FPS), "--bitrate-kbps", strconv.Itoa(config.BitrateKbps), "--max-width", strconv.Itoa(config.MaxWidth), "--max-height", strconv.Itoa(config.MaxHeight), "--event-fd", "3", "--profile", s.profile, "--embedded-cursor", strconv.FormatBool(config.EmbeddedCursor), "--allow-input", strconv.FormatBool(s.inputAllowed)}
	if s.synthetic {
		args = append(args, "--synthetic", "true")
	}
	processCtx, cancel := context.WithCancel(ctx)
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
	s.pending = make(map[uint64]chan error)
	writes, stopped := s.writes, s.stopped
	s.mu.Unlock()
	wait := make(chan error, 1)
	go func() { wait <- command.Wait() }()
	// Closing stdin requests a graceful release/stop; CommandContext escalation is
	// bounded and only owns this child. Pipe closure also interrupts a blocked write.
	defer func() {
		_ = stdin.Close()
		cancel()
		s.mu.Lock()
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
					cancel()
					return
				}
			}
		}
	}()
	go func() {
		scanner := bufio.NewScanner(events)
		scanner.Buffer(make([]byte, 4096), 384<<10)
		for scanner.Scan() {
			var event nativeEvent
			if json.Unmarshal(scanner.Bytes(), &event) != nil || event.Version != 2 {
				cancel()
				return
			}
			s.mu.Lock()
			done := s.pending[event.Ack]
			handler := s.onEvent
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
			if handler != nil && (event.State != nil || event.Cursor != nil) {
				handler(SourceEvent{Cursor: event.Cursor, State: event.State})
			}
		}
		cancel()
	}()
	go func() {
		timer := time.NewTicker(500 * time.Millisecond)
		defer timer.Stop()
		for {
			select {
			case <-processCtx.Done():
				return
			case <-timer.C:
				if s.send(processCtx, nativeCommand{Kind: "heartbeat"}, true) != nil {
					cancel()
					return
				}
			}
		}
	}()
	// Deadline includes the first full access unit, not merely the magic bytes.
	first := time.AfterFunc(nativeStartupTimeout, cancel)
	defer first.Stop()
	magic := make([]byte, 4)
	if _, err = io.ReadFull(stdout, magic); err != nil {
		return nativeCaptureFailure(err, stderr.String())
	}
	if string(magic) != nativeCaptureMagic {
		return fmt.Errorf("native helper protocol mismatch: %q", magic)
	}
	// Drain the helper independently of network pacing. Retain at most one
	// queued access unit plus the one being sent. Replacing an encoded frame
	// marks the reference chain broken so the sender waits for an IDR.
	frames := make(chan media.Sample, 1)
	readDone := make(chan error, 1)
	go func() {
		var replaced uint64
		discontinuity := false
		for {
			sample, _, _, readErr := readNativeCaptureSample(stdout, s.fps)
			if readErr != nil {
				readDone <- readErr
				return
			}
			first.Stop()
			metadata := sample.Metadata.(FrameMetadata)
			select {
			case <-frames:
				replaced++
				discontinuity = true
			default:
			}
			metadata.Dropped += replaced
			metadata.Discontinuity = discontinuity
			sample.Metadata = metadata
			select {
			case frames <- sample:
				discontinuity = false
			case <-processCtx.Done():
				return
			}
		}
	}()
	for {
		select {
		case sample := <-frames:
			if err = emit(sample); err != nil {
				return err
			}
		case readErr := <-readDone:
			if ctx.Err() != nil {
				return nil
			}
			return nativeCaptureFailure(readErr, stderr.String())
		case <-processCtx.Done():
			if ctx.Err() != nil {
				return nil
			}
			return nativeCaptureFailure(errors.New("capture helper stopped"), stderr.String())
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
	command := exec.CommandContext(ctx, helper, args...)
	configureCaptureCommand(command)
	var output limitedCaptureOutput
	command.Stdout = &output
	if err = command.Run(); err != nil {
		return nil, err
	}
	var value dieterv1.RemoteDesktopCapabilities
	if err = json.Unmarshal(output.raw, &value); err != nil {
		return nil, err
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
