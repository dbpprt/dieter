package remotedesktop

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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
	// Optional named pasteboard for isolated native fixtures; empty uses the system clipboard.
	ClipboardName  string
	Kind           string
	HelperPath     string
	Display        string
	FPS            int
	Bitrate        int
	MaxWidth       int
	MaxHeight      int
	Logger         *slog.Logger
	Profile        string
	EmbeddedCursor bool
	Control        bool
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
		options.FPS = 60
	}
	if options.Bitrate <= 0 {
		options.Bitrate = 12_000
	}
	if options.MaxWidth <= 0 {
		options.MaxWidth = 3_840
	}
	if options.MaxHeight <= 0 {
		options.MaxHeight = 2_160
	}
	switch strings.TrimSpace(options.Kind) {
	case "", "screen", "native-synthetic":
		if runtime.GOOS == "darwin" {
			helper, err := resolveCaptureHelper(options.HelperPath)
			if err != nil {
				return nil, err
			}
			return &nativeHelperSource{
				path: helper, display: options.Display, fps: options.FPS,
				bitrateKbps: options.Bitrate, maxWidth: options.MaxWidth,
				maxHeight: options.MaxHeight, logger: options.Logger,
				profile: options.Profile, synthetic: options.Kind == "native-synthetic",
				embeddedCursor: options.EmbeddedCursor, inputAllowed: options.Control,
			}, nil
		}
		return nil, errors.New("native screen sharing is currently supported on macOS only")
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
	return false, "Native screen sharing is currently supported on macOS only"
}

func CaptureExecutable(options SourceOptions) (path, label string, err error) {
	if strings.TrimSpace(options.Kind) == "synthetic" {
		return "synthetic", "synthetic test source", nil
	}
	if runtime.GOOS == "darwin" {
		path, err = resolveCaptureHelper(options.HelperPath)
		return path, "Dieter capture helper", err
	}
	return "", "", errors.New("native screen sharing is currently supported on macOS only")
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
		return fmt.Errorf("macOS Accessibility permission is not granted in the running Dieter daemon's capture context: %s", message)
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
		return fmt.Errorf("macOS Screen & System Audio Recording permission is not granted to the running Dieter daemon; run `dieter daemon permissions`: %w", err)
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
