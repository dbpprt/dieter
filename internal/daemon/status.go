package daemon

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	GatewayNotEnrolled  = "not-enrolled"
	GatewayConnecting   = "connecting"
	GatewayConnected    = "connected"
	GatewayDisconnected = "disconnected"
)

type RuntimeStatus struct {
	PID                int    `json:"pid"`
	Version            string `json:"version"`
	State              string `json:"state"`
	StartedAt          string `json:"startedAt"`
	UpdatedAt          string `json:"updatedAt"`
	StoppedAt          string `json:"stoppedAt,omitempty"`
	Store              string `json:"store"`
	ListenAddress      string `json:"listenAddress"`
	ServiceManaged     bool   `json:"serviceManaged"`
	LogPath            string `json:"logPath,omitempty"`
	Enrolled           bool   `json:"enrolled"`
	DaemonID           string `json:"daemonId,omitempty"`
	DaemonName         string `json:"daemonName,omitempty"`
	GatewayURL         string `json:"gatewayUrl,omitempty"`
	GatewayState       string `json:"gatewayState"`
	GatewayConnectedAt string `json:"gatewayConnectedAt,omitempty"`
	GatewayLastError   string `json:"gatewayLastError,omitempty"`
}

type GatewayEvent struct {
	State string
	Error string
}

type StatusWriter struct {
	mu    sync.Mutex
	path  string
	value RuntimeStatus
}

func RuntimeStatusPath(root string) string {
	return filepath.Join(root, "runtime", "daemon.json")
}

func LogPath(root string) string {
	return filepath.Join(root, "logs", "daemon.log")
}

func NewStatusWriter(root string, value RuntimeStatus) (*StatusWriter, error) {
	value.Store = root
	value.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	writer := &StatusWriter{path: RuntimeStatusPath(root), value: value}
	if err := writer.writeLocked(); err != nil {
		return nil, err
	}
	return writer, nil
}

func (w *StatusWriter) Update(change func(*RuntimeStatus)) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	change(&w.value)
	w.value.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return w.writeLocked()
}

func (w *StatusWriter) Touch() error {
	return w.Update(func(*RuntimeStatus) {})
}

func (w *StatusWriter) Stop() error {
	return w.Update(func(value *RuntimeStatus) {
		value.State = "stopped"
		value.StoppedAt = time.Now().UTC().Format(time.RFC3339Nano)
		if value.Enrolled {
			value.GatewayState = GatewayDisconnected
		}
	})
}

func (w *StatusWriter) Gateway(event GatewayEvent) {
	_ = w.Update(func(value *RuntimeStatus) {
		value.GatewayState = event.State
		value.GatewayLastError = event.Error
		if event.State == GatewayConnected {
			value.GatewayConnectedAt = time.Now().UTC().Format(time.RFC3339Nano)
		}
	})
}

func (w *StatusWriter) writeLocked() error {
	raw, err := json.MarshalIndent(w.value, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(w.path, append(raw, '\n'), 0o600)
}

func LoadRuntimeStatus(root string) (RuntimeStatus, error) {
	raw, err := os.ReadFile(RuntimeStatusPath(root))
	if err != nil {
		return RuntimeStatus{}, err
	}
	var value RuntimeStatus
	if err := json.Unmarshal(raw, &value); err != nil {
		return RuntimeStatus{}, err
	}
	return value, nil
}

func RuntimeStatusCurrent(value RuntimeStatus, now time.Time) bool {
	if value.State != "running" && value.State != "starting" {
		return false
	}
	updated, err := time.Parse(time.RFC3339Nano, value.UpdatedAt)
	return err == nil && now.Sub(updated) < 20*time.Second
}

func IsRuntimeStatusMissing(err error) bool {
	return errors.Is(err, os.ErrNotExist)
}
