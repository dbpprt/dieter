package remotedesktop

import (
	"context"
	"errors"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

// DisplayBackend owns a process-scoped physical display lease. Calls are
// serialized by controlMu; Close must revert its changes even after IPC failure.
type DisplayBackend interface {
	Exchange(context.Context, string, string, string, string) (*dieterv1.RemoteDesktopDisplayModes, error)
	Close()
}

func (m *Manager) displayBackendLocked() DisplayBackend {
	if m.displayBackend == nil {
		if m.options.DisplayFactory != nil {
			m.displayBackend = m.options.DisplayFactory()
		} else {
			m.displayBackend = newNativeDisplay(m.options.Source)
		}
	}
	return m.displayBackend
}

func (m *Manager) ListDisplayModes(ctx context.Context, id string) (*dieterv1.RemoteDesktopDisplayModes, error) {
	s := m.sessionFor(id)
	if s == nil {
		return nil, ErrNotFound
	}
	m.controlMu.Lock()
	defer m.controlMu.Unlock()
	if !s.active() {
		return nil, ErrNotFound
	}
	s.mu.Lock()
	display := s.status.Configuration.GetDisplayId()
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return m.displayBackendLocked().Exchange(ctx, "list", display, "", "")
}

func (m *Manager) SetDisplayMode(ctx context.Context, r *dieterv1.SetRemoteDesktopDisplayModeRequest) (*dieterv1.RemoteDesktopDisplayModes, error) {
	if r.GetDisplayId() == "" || len(r.GetDisplayId()) > 64 || r.GetModeId() == "" || len(r.GetModeId()) > 128 || r.GetExpectedCurrentModeId() == "" || len(r.GetExpectedCurrentModeId()) > 128 {
		return nil, errors.New("display, mode and expected current mode are required")
	}
	s := m.sessionFor(r.GetSessionId())
	if s == nil {
		return nil, ErrNotFound
	}
	s.configurationMu.Lock()
	defer s.configurationMu.Unlock()
	m.controlMu.Lock()
	defer m.controlMu.Unlock()
	if !s.active() {
		return nil, ErrNotFound
	}
	if m.controller != s {
		return nil, ErrControlOwner
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	s.mu.Lock()
	display := s.status.Configuration.GetDisplayId()
	s.mu.Unlock()
	backend := m.displayBackendLocked()
	before, err := backend.Exchange(ctx, "list", display, "", "")
	if err != nil {
		return nil, err
	}
	if before.DisplayId != r.DisplayId {
		return nil, errors.New("selected display changed; refresh its modes")
	}
	supported := false
	for _, mode := range before.Modes {
		if mode.Id == r.ModeId {
			supported = true
			break
		}
	}
	if !supported || before.Superseded || before.CurrentModeId != r.ExpectedCurrentModeId {
		return nil, errors.New("display changed; refresh its supported modes")
	}
	if err = s.releaseNativeInput(ctx); err != nil {
		return nil, err
	}
	changed := before.CurrentModeId != r.ModeId
	if changed {
		m.fenceDisplayInputLocked(before.DisplayId, true)
	}
	result, err := backend.Exchange(ctx, "set", r.DisplayId, r.ModeId, r.ExpectedCurrentModeId)
	if err != nil {
		m.fenceDisplayInputLocked(before.DisplayId, false)
		return nil, err
	}
	if result.Temporary {
		m.displayOwner = s
		m.displayLeaseDisplay = result.DisplayId
	} else if m.displayOwner == s {
		m.displayOwner = nil
		m.displayLeaseDisplay = ""
	}
	if changed {
		if err := m.media.DisplayModeChanged(ctx, result.DisplayId); err != nil {
			_, _ = m.restoreDisplayLocked(context.Background())
			return nil, err
		}
	}
	m.controlGeneration++
	m.publishControlLocked()
	return result, nil
}

func (m *Manager) RestoreDisplayMode(ctx context.Context, id string) (*dieterv1.RemoteDesktopDisplayModes, error) {
	s := m.sessionFor(id)
	if s == nil {
		return nil, ErrNotFound
	}
	s.configurationMu.Lock()
	defer s.configurationMu.Unlock()
	m.controlMu.Lock()
	defer m.controlMu.Unlock()
	if !s.active() {
		return nil, ErrNotFound
	}
	if m.controller != s {
		return nil, ErrControlOwner
	}
	if m.displayOwner != nil && m.displayOwner != s {
		return nil, ErrControlOwner
	}
	s.mu.Lock()
	display := s.status.Configuration.GetDisplayId()
	s.mu.Unlock()
	if m.displayOwner == nil {
		ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		return m.displayBackendLocked().Exchange(ctx, "list", display, "", "")
	}
	return m.restoreDisplayLocked(ctx)
}

func (m *Manager) restoreDisplayLocked(ctx context.Context) (*dieterv1.RemoteDesktopDisplayModes, error) {
	if m.displayOwner == nil {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	_ = m.displayOwner.releaseNativeInput(ctx)
	display := m.displayLeaseDisplay
	before, _ := m.displayBackend.Exchange(ctx, "list", display, "", "")
	changing := before != nil && before.Temporary && before.CurrentModeId != before.OriginalModeId
	m.fenceDisplayInputLocked(display, changing)
	result, err := m.displayBackend.Exchange(ctx, "restore", display, "", "")
	m.displayOwner = nil
	m.displayLeaseDisplay = ""
	if err != nil {
		// Exiting the app-scoped helper is the final rollback if IPC broke.
		m.displayBackend.Close()
		m.displayBackend = nil
	} else if result.Superseded {
		m.fenceDisplayInputLocked(display, false)
	}
	if changing {
		_ = m.media.DisplayModeChanged(ctx, display)
	}
	m.controlGeneration++
	m.publishControlLocked()
	return result, err
}

func (m *Manager) fenceDisplayInputLocked(display string, enabled bool) {
	for _, s := range m.allSessions() {
		s.mu.Lock()
		if s.status.DisplayId == display || s.status.Configuration.GetDisplayId() == display || s == m.controller {
			s.displayModeFence = 0
			if enabled && s.status.Width > 0 && s.status.Height > 0 {
				s.displayModeFence = s.status.DisplayGeneration
			}
		}
		s.mu.Unlock()
	}
}
