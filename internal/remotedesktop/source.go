package remotedesktop

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/pion/webrtc/v4/pkg/media/ivfreader"
)

type VideoCodec string

const (
	VideoCodecVP8  VideoCodec = "VP8"
	VideoCodecH264 VideoCodec = "H264"
)

// FrameSource emits complete encoded frames and owns capture, encoding, and
// pacing. Implementations must bound pending work and prefer the newest frame
// whenever the downstream transport is slower than capture.
type FrameSource interface {
	Description() string
	Codec() VideoCodec
	Stream(context.Context, func(media.Sample) error) error
}

type ControlledFrameSource interface {
	FrameSource
	RequestKeyFrame()
	SetBitrateKbps(int)
}

// InputSink is implemented by the signed native helper source. The daemon
// validates protobuf input before forwarding this deliberately small command
// representation to the helper that owns macOS event-posting permission.
type InputSink interface {
	SendInput(context.Context, *dieterv1.RemoteDesktopInput) error
	ReleaseInput(context.Context)
}

type SourceOptions struct {
	Kind       string
	FFmpegPath string
	HelperPath string
	Display    string
	FPS        int
	Bitrate    int
	MaxWidth   int
	MaxHeight  int
	Logger     *slog.Logger
}

const captureProbeTimeout = 15 * time.Second

var errCaptureProbeComplete = errors.New("capture probe completed")

// ProbeCapture runs the production capture path until its first encoded frame.
// It deliberately discards the frame: callers use it to verify the graphical
// session, capture permission, and platform encoder as one readiness check
// without retaining any screen content.
func ProbeCapture(ctx context.Context, options SourceOptions) error {
	source, err := NewFrameSource(options)
	if err != nil {
		return err
	}
	probeCtx, cancel := context.WithTimeout(ctx, captureProbeTimeout)
	defer cancel()
	captured := false
	err = source.Stream(probeCtx, func(sample media.Sample) error {
		if len(sample.Data) == 0 {
			return errors.New("capture produced an empty video frame")
		}
		captured = true
		return errCaptureProbeComplete
	})
	if captured && (err == nil || errors.Is(err, errCaptureProbeComplete)) {
		return nil
	}
	if probeCtx.Err() != nil {
		return fmt.Errorf("screen capture probe timed out: %w", probeCtx.Err())
	}
	if err != nil {
		return err
	}
	return errors.New("screen capture ended before producing a video frame")
}

func NewFrameSource(options SourceOptions) (FrameSource, error) {
	if options.FPS <= 0 {
		options.FPS = 30
	}
	if options.Bitrate <= 0 {
		options.Bitrate = 4_000
	}
	if options.MaxWidth <= 0 {
		options.MaxWidth = 1_920
	}
	if options.MaxHeight <= 0 {
		options.MaxHeight = 1_080
	}
	switch strings.TrimSpace(options.Kind) {
	case "", "screen":
		if runtime.GOOS == "darwin" {
			helper, err := resolveCaptureHelper(options.HelperPath)
			if err != nil {
				return nil, err
			}
			return &nativeHelperSource{
				path: helper, display: options.Display, fps: options.FPS,
				bitrateKbps: options.Bitrate, maxWidth: options.MaxWidth,
				maxHeight: options.MaxHeight, logger: options.Logger,
			}, nil
		}
		if options.FFmpegPath == "" {
			options.FFmpegPath = "ffmpeg"
		}
		if _, err := exec.LookPath(options.FFmpegPath); err != nil {
			return nil, fmt.Errorf("find FFmpeg %q: %w", options.FFmpegPath, err)
		}
		return ffmpegSource{
			path: options.FFmpegPath, platform: runtime.GOOS, display: options.Display,
			fps: options.FPS, bitrateKbps: options.Bitrate, logger: options.Logger,
			environ: currentEnvironment(),
		}, nil
	case "synthetic":
		return &syntheticSource{interval: time.Second / time.Duration(options.FPS)}, nil
	default:
		return nil, fmt.Errorf("remote desktop source must be screen or synthetic, got %q", options.Kind)
	}
}

func SourceAvailable(options SourceOptions) (bool, string) {
	if strings.TrimSpace(options.Kind) == "synthetic" {
		return true, ""
	}
	if runtime.GOOS == "darwin" {
		if _, err := resolveCaptureHelper(options.HelperPath); err != nil {
			return false, "Dieter native screen-capture helper is unavailable"
		}
		return true, ""
	}
	path := options.FFmpegPath
	if path == "" {
		path = "ffmpeg"
	}
	if _, err := exec.LookPath(path); err != nil {
		return false, "FFmpeg with libvpx is unavailable"
	}
	if runtime.GOOS == "linux" && os.Getenv("DISPLAY") == "" {
		if os.Getenv("WAYLAND_DISPLAY") != "" {
			return false, "Wayland portal capture is not available in the Pion host"
		}
		return false, "No graphical X11 session is active"
	}
	switch runtime.GOOS {
	case "darwin", "windows", "linux":
		return true, ""
	default:
		return false, "Screen capture is unsupported on this platform"
	}
}

func CaptureExecutable(options SourceOptions) (path, label string, err error) {
	if strings.TrimSpace(options.Kind) == "synthetic" {
		return "synthetic", "synthetic test source", nil
	}
	if runtime.GOOS == "darwin" {
		path, err = resolveCaptureHelper(options.HelperPath)
		return path, "Dieter capture helper", err
	}
	path = strings.TrimSpace(options.FFmpegPath)
	if path == "" {
		path = "ffmpeg"
	}
	path, err = exec.LookPath(path)
	return path, "FFmpeg", err
}

// ProbeControl verifies the event-posting permission of the exact helper used
// by a production screen session. It never clicks, types, or moves the cursor.
func ProbeControl(ctx context.Context, options SourceOptions, request bool) error {
	if strings.TrimSpace(options.Kind) == "synthetic" {
		return nil
	}
	if runtime.GOOS != "darwin" {
		return errors.New("remote desktop control is currently supported on macOS only")
	}
	helper, err := resolveCaptureHelper(options.HelperPath)
	if err != nil {
		return err
	}
	argument := "--check-control"
	if request {
		argument = "--request-control"
	}
	command := exec.CommandContext(ctx, helper, argument)
	configureCaptureCommand(command)
	if output, err := command.CombinedOutput(); err != nil {
		message := strings.TrimSpace(string(output))
		if message == "" {
			message = err.Error()
		}
		return fmt.Errorf("macOS Accessibility permission is not granted to Dieter's capture helper: %s", message)
	}
	return nil
}

type syntheticSource struct{ interval time.Duration }

func (*syntheticSource) SendInput(context.Context, *dieterv1.RemoteDesktopInput) error { return nil }
func (*syntheticSource) ReleaseInput(context.Context)                                  {}

// A deterministic 320x180 VP8 keyframe used by isolated integration tests.
const syntheticIVFBase64 = "REtJRgAAIABWUDgwQAG0AAEAAAABAAAA/////wAAAACVAAAAAAAAAAAAAABQDwCdASpAAbQAAEcIhYWImYSIAgICdaoCBmZlqMPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZNkD+/y6p/q7E+FCCfxvN5rViAA=="

func (syntheticSource) Description() string { return "synthetic VP8 keyframe" }
func (syntheticSource) Codec() VideoCodec   { return VideoCodecVP8 }

func (s *syntheticSource) Stream(ctx context.Context, write func(media.Sample) error) error {
	raw, err := base64.StdEncoding.DecodeString(syntheticIVFBase64)
	if err != nil {
		return fmt.Errorf("decode synthetic IVF: %w", err)
	}
	reader, _, err := ivfreader.NewWith(bytes.NewReader(raw))
	if err != nil {
		return fmt.Errorf("open synthetic IVF: %w", err)
	}
	frame, _, err := reader.ParseNextFrame()
	if err != nil {
		return fmt.Errorf("read synthetic IVF frame: %w", err)
	}
	interval := s.interval
	if interval <= 0 {
		interval = 100 * time.Millisecond
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if err := write(media.Sample{Data: frame, Duration: interval}); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

type ffmpegSource struct {
	path        string
	platform    string
	display     string
	fps         int
	bitrateKbps int
	logger      *slog.Logger
	environ     map[string]string
}

const ffmpegStartupTimeout = 10 * time.Second

func (s ffmpegSource) Description() string {
	return fmt.Sprintf("%s desktop via FFmpeg/libvpx (%dfps, %dkbps)", s.platform, s.fps, s.bitrateKbps)
}

func (ffmpegSource) Codec() VideoCodec { return VideoCodecVP8 }

func (s ffmpegSource) Stream(ctx context.Context, write func(media.Sample) error) error {
	arguments, err := ffmpegArgs(s.platform, s.display, s.fps, s.bitrateKbps, s.environ)
	if err != nil {
		return err
	}
	captureContext, cancelCapture := context.WithCancel(ctx)
	defer cancelCapture()
	command := exec.CommandContext(captureContext, s.path, arguments...)
	configureCaptureCommand(command)
	stdout, err := command.StdoutPipe()
	if err != nil {
		return fmt.Errorf("open FFmpeg output: %w", err)
	}
	stderr := &captureStderr{log: s.logger}
	command.Stderr = stderr
	if err := command.Start(); err != nil {
		return fmt.Errorf("start FFmpeg: %w", err)
	}
	wait := make(chan error, 1)
	go func() { wait <- command.Wait() }()

	startupTimedOut := make(chan struct{})
	startupTimer := time.AfterFunc(ffmpegStartupTimeout, func() {
		close(startupTimedOut)
		cancelCapture()
	})
	reader, header, err := ivfreader.NewWith(stdout)
	if !startupTimer.Stop() {
		<-startupTimedOut
	}
	select {
	case <-startupTimedOut:
		return captureFailure(s.platform, finishCapture(ctx, wait, fmt.Errorf("FFmpeg produced no video within %s", ffmpegStartupTimeout)), stderr.String())
	default:
	}
	if err != nil {
		cancelCapture()
		return captureFailure(s.platform, finishCapture(ctx, wait, fmt.Errorf("read FFmpeg IVF header: %w", err)), stderr.String())
	}
	if header.FourCC != "VP80" {
		cancelCapture()
		return captureFailure(s.platform, finishCapture(ctx, wait, fmt.Errorf("FFmpeg emitted unsupported IVF codec %q", header.FourCC)), stderr.String())
	}
	frameDuration := time.Duration(header.TimebaseNumerator) * time.Second / time.Duration(header.TimebaseDenominator)
	if frameDuration <= 0 || frameDuration > time.Second {
		frameDuration = time.Second / time.Duration(s.fps)
	}
	for {
		frame, _, readErr := reader.ParseNextFrame()
		if readErr != nil {
			cancelCapture()
			if errors.Is(readErr, io.EOF) && ctx.Err() != nil {
				return captureFailure(s.platform, finishCapture(ctx, wait, nil), stderr.String())
			}
			return captureFailure(s.platform, finishCapture(ctx, wait, fmt.Errorf("read FFmpeg frame: %w", readErr)), stderr.String())
		}
		if err := write(media.Sample{Data: frame, Duration: frameDuration}); err != nil {
			cancelCapture()
			return captureFailure(s.platform, finishCapture(ctx, wait, err), stderr.String())
		}
	}
}

const (
	nativeCaptureMagic      = "DTH1"
	nativeCaptureHeaderSize = 32
	maxEncodedFrameBytes    = 16 << 20
)

type nativeHelperSource struct {
	path        string
	display     string
	fps         int
	bitrateKbps int
	maxWidth    int
	maxHeight   int
	logger      *slog.Logger

	controlMu      sync.Mutex
	control        io.WriteCloser
	pendingIDR     bool
	pendingBitrate int
}

type nativeInputCommand struct {
	Input *nativeInputPayload `json:"input,omitempty"`
}

type nativeInputPayload struct {
	Kind       string `json:"kind"`
	X          int32  `json:"x,omitempty"`
	Y          int32  `json:"y,omitempty"`
	Button     int32  `json:"button,omitempty"`
	Down       bool   `json:"down,omitempty"`
	Repeat     bool   `json:"repeat,omitempty"`
	ClickCount int32  `json:"click_count,omitempty"`
	DeltaX     int32  `json:"delta_x,omitempty"`
	DeltaY     int32  `json:"delta_y,omitempty"`
	Precise    bool   `json:"precise,omitempty"`
	KeyCode    uint32 `json:"key_code,omitempty"`
	Modifiers  uint32 `json:"modifiers,omitempty"`
}

func (s *nativeHelperSource) Description() string {
	return fmt.Sprintf("macOS ScreenCaptureKit/VideoToolbox H.264 (%dfps, %dkbps, <=%dx%d)", s.fps, s.bitrateKbps, s.maxWidth, s.maxHeight)
}

func (*nativeHelperSource) Codec() VideoCodec { return VideoCodecH264 }

func (s *nativeHelperSource) RequestKeyFrame() {
	s.controlMu.Lock()
	defer s.controlMu.Unlock()
	if s.control == nil {
		s.pendingIDR = true
		return
	}
	_, _ = io.WriteString(s.control, "{\"keyframe\":true}\n")
}

func (s *nativeHelperSource) SetBitrateKbps(bitrate int) {
	if s.bitrateKbps > 0 {
		bitrate = min(bitrate, s.bitrateKbps)
	}
	if bitrate < 100 || bitrate > 100_000 {
		return
	}
	s.controlMu.Lock()
	defer s.controlMu.Unlock()
	if s.control == nil {
		s.pendingBitrate = bitrate
		return
	}
	_, _ = fmt.Fprintf(s.control, "{\"bitrate_kbps\":%d}\n", bitrate)
}

func (s *nativeHelperSource) SendInput(_ context.Context, value *dieterv1.RemoteDesktopInput) error {
	if value == nil {
		return errors.New("remote desktop input is missing")
	}
	payload := &nativeInputPayload{}
	switch input := value.GetPayload().(type) {
	case *dieterv1.RemoteDesktopInput_PointerMove:
		payload.Kind, payload.X, payload.Y = "pointer_move", input.PointerMove.GetNormalizedX(), input.PointerMove.GetNormalizedY()
	case *dieterv1.RemoteDesktopInput_PointerButton:
		payload.Kind, payload.X, payload.Y = "pointer_button", input.PointerButton.GetNormalizedX(), input.PointerButton.GetNormalizedY()
		payload.Button, payload.Down, payload.ClickCount = int32(input.PointerButton.GetButton()), input.PointerButton.GetDown(), input.PointerButton.GetClickCount()
		payload.Modifiers = input.PointerButton.GetModifiers()
	case *dieterv1.RemoteDesktopInput_Scroll:
		payload.Kind, payload.DeltaX, payload.DeltaY = "scroll", input.Scroll.GetDeltaX(), input.Scroll.GetDeltaY()
		payload.Precise, payload.Modifiers = input.Scroll.GetPrecise(), input.Scroll.GetModifiers()
	case *dieterv1.RemoteDesktopInput_Key:
		payload.Kind, payload.KeyCode = "key", input.Key.GetKeyCode()
		payload.Down, payload.Repeat, payload.Modifiers = input.Key.GetDown(), input.Key.GetRepeat(), input.Key.GetModifiers()
	case *dieterv1.RemoteDesktopInput_ReleaseAll:
		payload.Kind = "release_all"
	default:
		return errors.New("remote desktop input payload is missing")
	}
	raw, err := json.Marshal(nativeInputCommand{Input: payload})
	if err != nil {
		return err
	}
	s.controlMu.Lock()
	defer s.controlMu.Unlock()
	if s.control == nil {
		return errors.New("remote desktop input helper is not ready")
	}
	_, err = s.control.Write(append(raw, '\n'))
	return err
}

func (s *nativeHelperSource) ReleaseInput(ctx context.Context) {
	_ = s.SendInput(ctx, &dieterv1.RemoteDesktopInput{Payload: &dieterv1.RemoteDesktopInput_ReleaseAll{ReleaseAll: &dieterv1.RemoteDesktopReleaseAll{}}})
}

func (s *nativeHelperSource) Stream(ctx context.Context, write func(media.Sample) error) error {
	display := strings.TrimSpace(s.display)
	if display == "" {
		display = "primary"
	}
	arguments := []string{
		"--display-id", display,
		"--fps", strconv.Itoa(s.fps),
		"--bitrate-kbps", strconv.Itoa(s.bitrateKbps),
		"--max-width", strconv.Itoa(s.maxWidth),
		"--max-height", strconv.Itoa(s.maxHeight),
	}
	captureContext, cancelCapture := context.WithCancel(ctx)
	defer cancelCapture()
	command := exec.CommandContext(captureContext, s.path, arguments...)
	configureCaptureCommand(command)
	stdout, err := command.StdoutPipe()
	if err != nil {
		return fmt.Errorf("open native capture output: %w", err)
	}
	stdin, err := command.StdinPipe()
	if err != nil {
		return fmt.Errorf("open native capture control: %w", err)
	}
	stderr := &captureStderr{log: s.logger}
	command.Stderr = stderr
	if err := command.Start(); err != nil {
		return fmt.Errorf("start native capture helper: %w", err)
	}
	s.installControl(stdin)
	defer s.clearControl(stdin)
	wait := make(chan error, 1)
	go func() { wait <- command.Wait() }()

	startupTimer := time.NewTimer(ffmpegStartupTimeout)
	defer startupTimer.Stop()
	magic := make([]byte, len(nativeCaptureMagic))
	readMagic := make(chan error, 1)
	go func() {
		_, readErr := io.ReadFull(stdout, magic)
		readMagic <- readErr
	}()
	select {
	case err := <-readMagic:
		if err != nil {
			cancelCapture()
			return nativeCaptureFailure(finishNativeCapture(ctx, wait, fmt.Errorf("read native capture header: %w", err)), stderr.String())
		}
	case <-startupTimer.C:
		cancelCapture()
		return nativeCaptureFailure(finishNativeCapture(ctx, wait, fmt.Errorf("native capture produced no video within %s", ffmpegStartupTimeout)), stderr.String())
	case <-ctx.Done():
		cancelCapture()
		return finishNativeCapture(ctx, wait, nil)
	}
	if string(magic) != nativeCaptureMagic {
		cancelCapture()
		return nativeCaptureFailure(finishNativeCapture(ctx, wait, fmt.Errorf("native capture emitted invalid stream header %q", magic)), stderr.String())
	}

	var frameCount uint64
	var encodeTotal time.Duration
	var encodeMax time.Duration
	lastLog := time.Now()
	for {
		sample, captureUnixNanos, encodeDuration, err := readNativeCaptureSample(stdout, s.fps)
		if err != nil {
			cancelCapture()
			if errors.Is(err, io.EOF) && ctx.Err() != nil {
				return finishNativeCapture(ctx, wait, nil)
			}
			return nativeCaptureFailure(finishNativeCapture(ctx, wait, err), stderr.String())
		}
		frameCount++
		encodeTotal += encodeDuration
		encodeMax = max(encodeMax, encodeDuration)
		if s.logger != nil && time.Since(lastLog) >= 5*time.Second {
			average := time.Duration(0)
			if frameCount > 0 {
				average = encodeTotal / time.Duration(frameCount)
			}
			age := time.Since(time.Unix(0, captureUnixNanos))
			s.logger.Info("remote desktop media", "frames", frameCount, "encode_average", average, "encode_max", encodeMax, "latest_frame_age", age)
			frameCount, encodeTotal, encodeMax, lastLog = 0, 0, 0, time.Now()
		}
		if err := write(sample); err != nil {
			cancelCapture()
			return finishNativeCapture(ctx, wait, err)
		}
	}
}

func readNativeCaptureSample(reader io.Reader, fps int) (media.Sample, int64, time.Duration, error) {
	header := make([]byte, nativeCaptureHeaderSize)
	if _, err := io.ReadFull(reader, header); err != nil {
		return media.Sample{}, 0, 0, fmt.Errorf("read native capture frame header: %w", err)
	}
	length := int(binary.BigEndian.Uint32(header[0:4]))
	if length <= 0 || length > maxEncodedFrameBytes {
		return media.Sample{}, 0, 0, fmt.Errorf("native capture frame has invalid size %d", length)
	}
	duration := time.Duration(binary.BigEndian.Uint64(header[8:16]))
	if duration <= 0 || duration > time.Second {
		duration = time.Second / time.Duration(max(1, fps))
	}
	captureUnixNanos := int64(binary.BigEndian.Uint64(header[16:24]))
	encodeDuration := time.Duration(binary.BigEndian.Uint64(header[24:32]))
	frame := make([]byte, length)
	if _, err := io.ReadFull(reader, frame); err != nil {
		return media.Sample{}, 0, 0, fmt.Errorf("read native capture frame: %w", err)
	}
	return media.Sample{Data: frame, Duration: duration}, captureUnixNanos, encodeDuration, nil
}

func (s *nativeHelperSource) installControl(stdin io.WriteCloser) {
	s.controlMu.Lock()
	defer s.controlMu.Unlock()
	s.control = stdin
	if s.pendingIDR {
		_, _ = io.WriteString(stdin, "{\"keyframe\":true}\n")
		s.pendingIDR = false
	}
	if s.pendingBitrate > 0 {
		_, _ = fmt.Fprintf(stdin, "{\"bitrate_kbps\":%d}\n", s.pendingBitrate)
		s.pendingBitrate = 0
	}
}

func (s *nativeHelperSource) clearControl(stdin io.WriteCloser) {
	s.controlMu.Lock()
	if s.control == stdin {
		s.control = nil
	}
	s.controlMu.Unlock()
	_ = stdin.Close()
}

func resolveCaptureHelper(configured string) (string, error) {
	if value := strings.TrimSpace(configured); value != "" {
		if info, err := os.Stat(value); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return value, nil
		}
		return "", fmt.Errorf("native capture helper %q is not executable", value)
	}
	if executable, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(executable), "dieter-capture")
		if info, statErr := os.Stat(candidate); statErr == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate, nil
		}
	}
	if value, err := exec.LookPath("dieter-capture"); err == nil {
		return value, nil
	}
	return "", errors.New("find Dieter native capture helper next to the daemon or on PATH")
}

func nativeCaptureFailure(err error, diagnostic string) error {
	if err == nil || errors.Is(err, errCaptureProbeComplete) {
		return err
	}
	lower := strings.ToLower(diagnostic)
	if strings.Contains(lower, "not authorized") || strings.Contains(lower, "permission") ||
		strings.Contains(lower, "denied") || strings.Contains(lower, "user declined") ||
		strings.Contains(lower, "-3801") {
		return fmt.Errorf("macOS Screen & System Audio Recording permission is not granted to Dieter's capture helper; run `dieter daemon permissions`: %w", err)
	}
	if diagnostic != "" {
		return fmt.Errorf("%w: %s", err, diagnostic)
	}
	return err
}

type captureStderr struct {
	mu  sync.Mutex
	log *slog.Logger
	raw []byte
}

func (w *captureStderr) Write(value []byte) (int, error) {
	w.mu.Lock()
	w.raw = append(w.raw, value...)
	if len(w.raw) > 8<<10 {
		w.raw = append([]byte(nil), w.raw[len(w.raw)-(8<<10):]...)
	}
	w.mu.Unlock()
	message := strings.TrimSpace(string(value))
	if message != "" && w.log != nil {
		w.log.Warn("remote desktop capture", "message", message)
	}
	return len(value), nil
}

func (w *captureStderr) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return strings.TrimSpace(string(w.raw))
}

func captureFailure(platform string, err error, diagnostic string) error {
	if err == nil || errors.Is(err, errCaptureProbeComplete) {
		return err
	}
	lower := strings.ToLower(diagnostic)
	switch {
	case platform == "darwin" && (strings.Contains(lower, "not authorized") ||
		strings.Contains(lower, "screen recording permission") ||
		strings.Contains(lower, "permission denied")):
		return fmt.Errorf("macOS Screen Recording permission is not granted to FFmpeg; run `dieter daemon permissions` on the host: %w", err)
	case strings.Contains(lower, "unknown encoder") && strings.Contains(lower, "libvpx"):
		return fmt.Errorf("FFmpeg does not include the required VP8/libvpx encoder: %w", err)
	case strings.Contains(lower, "capture screen") && strings.Contains(lower, "not found"):
		return fmt.Errorf("FFmpeg could not find the selected macOS display: %w", err)
	default:
		return err
	}
}

func finishCapture(ctx context.Context, wait <-chan error, streamErr error) error {
	return finishCaptureProcess(ctx, wait, streamErr, "FFmpeg")
}

func finishNativeCapture(ctx context.Context, wait <-chan error, streamErr error) error {
	return finishCaptureProcess(ctx, wait, streamErr, "native capture helper")
}

func finishCaptureProcess(ctx context.Context, wait <-chan error, streamErr error, name string) error {
	select {
	case waitErr := <-wait:
		if ctx.Err() != nil {
			return nil
		}
		if streamErr != nil {
			return streamErr
		}
		if waitErr != nil {
			return fmt.Errorf("%s exited: %w", name, waitErr)
		}
		return nil
	case <-ctx.Done():
		select {
		case <-wait:
			return nil
		case <-time.After(2 * time.Second):
			return fmt.Errorf("%s did not stop after capture cancellation", name)
		}
	case <-time.After(2 * time.Second):
		if streamErr != nil {
			return streamErr
		}
		return fmt.Errorf("%s did not stop", name)
	}
}

func ffmpegArgs(platform, display string, fps, bitrateKbps int, environ map[string]string) ([]string, error) {
	if fps < 1 || fps > 120 {
		return nil, fmt.Errorf("fps must be between 1 and 120, got %d", fps)
	}
	if bitrateKbps < 100 || bitrateKbps > 100_000 {
		return nil, fmt.Errorf("bitrate must be between 100 and 100000 kbps, got %d", bitrateKbps)
	}
	input := []string{"-hide_banner", "-loglevel", "warning"}
	switch platform {
	case "darwin":
		if display == "" || display == "primary" {
			// AVFoundation mixes cameras and screens in one device index. Naming
			// the screen explicitly avoids ever selecting camera index 0.
			display = "Capture screen 0"
		}
		input = append(input, "-f", "avfoundation", "-capture_cursor", "1", "-pixel_format", "nv12", "-framerate", strconv.Itoa(fps), "-i", display+":none")
	case "windows":
		if display == "" || display == "primary" {
			display = "desktop"
		}
		input = append(input, "-f", "gdigrab", "-draw_mouse", "1", "-framerate", strconv.Itoa(fps), "-i", display)
	case "linux":
		if display == "" || display == "primary" {
			display = environ["DISPLAY"]
		}
		if display == "" {
			if environ["WAYLAND_DISPLAY"] != "" {
				return nil, errors.New("the Pion host does not automate Wayland portal capture")
			}
			return nil, errors.New("DISPLAY is empty")
		}
		input = append(input, "-f", "x11grab", "-draw_mouse", "1", "-framerate", strconv.Itoa(fps), "-i", display)
	default:
		return nil, fmt.Errorf("screen capture is not configured for %q", platform)
	}
	keyframeInterval := fps * 2
	output := []string{
		"-an", "-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8",
		"-lag-in-frames", "0", "-error-resilient", "1", "-g", strconv.Itoa(keyframeInterval),
		"-b:v", strconv.Itoa(bitrateKbps) + "k", "-pix_fmt", "yuv420p", "-f", "ivf", "pipe:1",
	}
	return append(input, output...), nil
}

func currentEnvironment() map[string]string {
	values := make(map[string]string)
	for _, item := range os.Environ() {
		key, value, ok := strings.Cut(item, "=")
		if ok {
			values[key] = value
		}
	}
	return values
}
