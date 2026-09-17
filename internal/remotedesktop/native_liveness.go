package remotedesktop

import (
	"errors"
	"io"
	"strings"
	"sync"
	"time"
)

var errNativeHelperStopped = errors.New("native capture helper stopped")

func recoverableCaptureFailure(err error) bool {
	if err == nil {
		return false
	}
	// Permission errors may wrap EOF from a helper that declined capture.
	if strings.HasPrefix(err.Error(), "macOS Screen & System Audio Recording permission") {
		return false
	}
	if errors.Is(err, errNativeHelperStopped) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return true
	}
	switch err.Error() {
	case "native capture rendition stopped", "native daemon heartbeat expired", "native capture helper unresponsive", "native capture helper stopped":
		return true
	default:
		return false
	}
}

// Every newly acknowledged command proves that the helper is reading the
// daemon's pipe. Keepalives must not wait for one particular reply: frame/input
// acknowledgments can continue while a heartbeat reply is delayed.
type nativeLiveness struct {
	mu  sync.Mutex
	ack uint64
	at  time.Time
}

func (l *nativeLiveness) acknowledge(id, issued uint64, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if id == 0 || id > issued || id <= l.ack {
		return
	}
	l.ack, l.at = id, now
}

func (l *nativeLiveness) snapshot(now time.Time) (uint64, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.ack, now.Sub(l.at)
}
