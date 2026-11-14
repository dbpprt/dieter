package daemon

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/link"
)

const (
	daemonLogLimit   = 10 << 20
	daemonLogBackups = 3
)

type rotatingLogWriter struct {
	mu   sync.Mutex
	path string
	file *os.File
	size int64
}

func openRotatingLog(path string) (*rotatingLogWriter, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	writer := &rotatingLogWriter{path: path}
	if err := writer.open(); err != nil {
		return nil, err
	}
	return writer, nil
}

func (w *rotatingLogWriter) open() error {
	file, err := os.OpenFile(w.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return err
	}
	w.file, w.size = file, info.Size()
	return nil
}

func (w *rotatingLogWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.size+int64(len(data)) > daemonLogLimit {
		if err := w.rotate(); err != nil {
			return 0, err
		}
	}
	written, err := w.file.Write(data)
	w.size += int64(written)
	return written, err
}

func (w *rotatingLogWriter) rotate() error {
	if err := w.file.Close(); err != nil {
		return err
	}
	for index := daemonLogBackups; index >= 1; index-- {
		destination := fmt.Sprintf("%s.%d", w.path, index)
		if index == daemonLogBackups {
			_ = os.Remove(destination)
		}
		source := w.path
		if index > 1 {
			source = fmt.Sprintf("%s.%d", w.path, index-1)
		}
		if err := os.Rename(source, destination); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	w.file, w.size = nil, 0
	return w.open()
}

func (w *rotatingLogWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return nil
	}
	return w.file.Close()
}

func daemonLogger(root string, serviceMode, verbose bool, stderr io.Writer) (*slog.Logger, string, func(), error) {
	level := slog.LevelInfo
	if verbose {
		level = slog.LevelDebug
	}
	if !serviceMode {
		return slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: level})), "", func() {}, nil
	}
	path := link.LogPath(root)
	writer, err := openRotatingLog(path)
	if err != nil {
		return nil, "", nil, err
	}
	logger := slog.New(slog.NewTextHandler(writer, &slog.HandlerOptions{Level: level}))
	return logger, path, func() { _ = writer.Close() }, nil
}

func runStatusHeartbeat(ctx context.Context, writer *link.StatusWriter) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_ = writer.Touch()
		}
	}
}
