package remotedesktop

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/pion/webrtc/v4/pkg/media/ivfreader"
)

// FrameSource emits complete encoded VP8 frames and owns their pacing.
// The production host keeps this small boundary so ScreenCaptureKit or a
// native helper can replace FFmpeg without changing session admission.
type FrameSource interface {
	Description() string
	Stream(context.Context, func(media.Sample) error) error
}

type SourceOptions struct {
	Kind       string
	FFmpegPath string
	Display    string
	FPS        int
	Bitrate    int
	Logger     *slog.Logger
}

func NewFrameSource(options SourceOptions) (FrameSource, error) {
	if options.FPS <= 0 {
		options.FPS = 30
	}
	if options.Bitrate <= 0 {
		options.Bitrate = 4_000
	}
	switch strings.TrimSpace(options.Kind) {
	case "", "screen":
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
		return syntheticSource{interval: time.Second / time.Duration(options.FPS)}, nil
	default:
		return nil, fmt.Errorf("remote desktop source must be screen or synthetic, got %q", options.Kind)
	}
}

func SourceAvailable(options SourceOptions) (bool, string) {
	if strings.TrimSpace(options.Kind) == "synthetic" {
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

type syntheticSource struct{ interval time.Duration }

// A deterministic 320x180 VP8 keyframe used by isolated integration tests.
const syntheticIVFBase64 = "REtJRgAAIABWUDgwQAG0AAEAAAABAAAA/////wAAAACVAAAAAAAAAAAAAABQDwCdASpAAbQAAEcIhYWImYSIAgICdaoCBmZlqMPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZOcPZNkD+/y6p/q7E+FCCfxvN5rViAA=="

func (syntheticSource) Description() string { return "synthetic VP8 keyframe" }

func (s syntheticSource) Stream(ctx context.Context, write func(media.Sample) error) error {
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

func (s ffmpegSource) Stream(ctx context.Context, write func(media.Sample) error) error {
	arguments, err := ffmpegArgs(s.platform, s.display, s.fps, s.bitrateKbps, s.environ)
	if err != nil {
		return err
	}
	captureContext, cancelCapture := context.WithCancel(ctx)
	defer cancelCapture()
	command := exec.CommandContext(captureContext, s.path, arguments...)
	stdout, err := command.StdoutPipe()
	if err != nil {
		return fmt.Errorf("open FFmpeg output: %w", err)
	}
	if s.logger != nil {
		command.Stderr = slogWriter{s.logger}
	} else {
		command.Stderr = os.Stderr
	}
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
		return finishCapture(ctx, wait, fmt.Errorf("FFmpeg produced no video within %s; check screen recording permission and the display selector", ffmpegStartupTimeout))
	default:
	}
	if err != nil {
		cancelCapture()
		return finishCapture(ctx, wait, fmt.Errorf("read FFmpeg IVF header: %w", err))
	}
	if header.FourCC != "VP80" {
		cancelCapture()
		return finishCapture(ctx, wait, fmt.Errorf("FFmpeg emitted unsupported IVF codec %q", header.FourCC))
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
				return finishCapture(ctx, wait, nil)
			}
			return finishCapture(ctx, wait, fmt.Errorf("read FFmpeg frame: %w", readErr))
		}
		if err := write(media.Sample{Data: frame, Duration: frameDuration}); err != nil {
			cancelCapture()
			return finishCapture(ctx, wait, err)
		}
	}
}

type slogWriter struct{ log *slog.Logger }

func (w slogWriter) Write(value []byte) (int, error) {
	message := strings.TrimSpace(string(value))
	if message != "" {
		w.log.Warn("remote desktop capture", "message", message)
	}
	return len(value), nil
}

func finishCapture(ctx context.Context, wait <-chan error, streamErr error) error {
	select {
	case waitErr := <-wait:
		if ctx.Err() != nil {
			return nil
		}
		if streamErr != nil {
			return streamErr
		}
		if waitErr != nil {
			return fmt.Errorf("FFmpeg exited: %w", waitErr)
		}
		return nil
	case <-ctx.Done():
		return nil
	case <-time.After(2 * time.Second):
		if streamErr != nil {
			return streamErr
		}
		return errors.New("FFmpeg did not stop")
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
