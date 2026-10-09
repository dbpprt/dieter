package remotedesktop

import (
	"context"
	"errors"
	"os"
	"runtime"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/proto"
)

// VirtualDisplayBackend owns one helper and one temporary desktop. Calls are
// serialized by controlMu. Close must release the desktop after IPC failure.
type VirtualDisplayBackend interface {
	Exchange(context.Context, string, *dieterv1.SetRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error)
	Close()
}

type nativeVirtualDisplay struct{ pipe *nativeDisplay }

func newNativeVirtualDisplay(options SourceOptions) *nativeVirtualDisplay {
	return &nativeVirtualDisplay{pipe: &nativeDisplay{options: options, arguments: []string{"--virtual-display-service", "--state-root", options.StateRoot}}}
}
func (n *nativeVirtualDisplay) Close() { n.pipe.Close() }
func (n *nativeVirtualDisplay) Exchange(ctx context.Context, action string, r *dieterv1.SetRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	n.pipe.mu.Lock()
	defer n.pipe.mu.Unlock()
	if n.pipe.closed {
		return nil, errors.New("virtual display helper stopped")
	}
	if n.pipe.input == nil {
		if err := n.pipe.start(); err != nil {
			return nil, err
		}
	}
	result := &dieterv1.RemoteDesktopVirtualDisplay{}
	err := n.pipe.exchangeLocked(ctx, map[string]any{"action": action, "pixel_width": r.GetPixelWidth(), "pixel_height": r.GetPixelHeight(), "scale": r.GetScale(), "disable_physical": r.GetDisablePhysical()}, result)
	return result, err
}

func (m *Manager) virtualDisplayEnabled() bool {
	return m.options.VirtualDisplayFactory != nil || (runtime.GOOS == "darwin" && os.Getenv("DIETER_SCREEN_VIRTUAL_DISPLAY") == "1" && m.options.Source.StateRoot != "")
}
func (m *Manager) virtualDisableEnabled() bool {
	return m.options.VirtualDisplayFactory != nil || (m.virtualDisplayEnabled() && os.Getenv("DIETER_SCREEN_VIRTUAL_DISABLE") == "1")
}
func (m *Manager) GetVirtualDisplay(ctx context.Context, id string) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	s := m.sessionFor(id)
	m.controlMu.Lock()
	defer m.controlMu.Unlock()
	if s == nil || !s.active() {
		return nil, ErrNotFound
	}
	if m.virtualOwner != s {
		return &dieterv1.RemoteDesktopVirtualDisplay{}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return m.virtualBackend.Exchange(ctx, "status", nil)
}
func (m *Manager) SetVirtualDisplay(ctx context.Context, r *dieterv1.SetRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	if !m.virtualDisplayEnabled() {
		return nil, errors.New("experimental virtual displays are not enabled on this host")
	}
	if r.GetPixelWidth() < 320 || r.GetPixelWidth() > 3840 || r.GetPixelHeight() < 180 || r.GetPixelHeight() > 2160 || (r.GetScale() != 1 && r.GetScale() != 2) || r.GetPixelWidth()%(r.GetScale()*2) != 0 || r.GetPixelHeight()%(r.GetScale()*2) != 0 {
		return nil, errors.New("virtual display requires even 320x180..3840x2160 backing pixels and scale 1 or 2 (2x sizes must be divisible by 4)")
	}
	if r.DisablePhysical && !m.virtualDisableEnabled() {
		return nil, errors.New("physical display disabling is not qualified on this host")
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
	if m.virtualOwner == s && proto.Equal(m.virtualRequest, r) {
		return proto.Clone(m.virtualState).(*dieterv1.RemoteDesktopVirtualDisplay), nil
	}
	if m.virtualOwner != nil {
		return nil, errors.New("restore the current virtual display before changing its dimensions")
	}
	s.mu.Lock()
	previous := proto.Clone(s.status.Configuration).(*dieterv1.RemoteDesktopStreamConfiguration)
	s.mu.Unlock()
	next := proto.Clone(previous).(*dieterv1.RemoteDesktopStreamConfiguration)
	next.MaxWidth, next.MaxHeight, next.MaxFps = r.PixelWidth, r.PixelHeight, min(next.MaxFps, 60)
	if s.codec == VideoCodecH265 && !hevcModeSupported(next) {
		return nil, errors.New("virtual display exceeds HEVC limits; select H.264")
	}
	source, ok := s.source.(AdaptiveFrameSource)
	if !ok {
		return nil, errors.New("capture backend does not support virtual displays")
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if _, err := m.restoreDisplayLocked(ctx); err != nil {
		return nil, err
	}
	if err := s.releaseNativeInput(ctx); err != nil {
		return nil, err
	}
	var backend VirtualDisplayBackend
	if m.options.VirtualDisplayFactory != nil {
		backend = m.options.VirtualDisplayFactory()
	} else {
		backend = newNativeVirtualDisplay(m.options.Source)
	}
	result, err := backend.Exchange(ctx, "create", r)
	if err != nil {
		backend.Close()
		return nil, err
	}
	if !result.Active || result.DisplayId == "" || result.PixelWidth != r.PixelWidth || result.PixelHeight != r.PixelHeight || result.Scale != r.Scale || result.PhysicalDisabled {
		backend.Close()
		return nil, errors.New("virtual display geometry or initial state was not verified")
	}
	m.virtualOwner, m.virtualBackend, m.virtualPrevious = s, backend, previous
	m.virtualState, m.virtualRequest = result, proto.Clone(r).(*dieterv1.SetRemoteDesktopVirtualDisplayRequest)
	next.DisplayId = result.DisplayId
	m.fenceDisplayInputLocked(previous.DisplayId, true)
	if err = source.Configure(ctx, nativeConfiguration(next)); err != nil {
		_, _ = m.restoreVirtualLocked(context.Background())
		return nil, err
	}
	s.mu.Lock()
	s.status.Configuration = next
	s.applied = nativeConfiguration(next)
	s.configurationRevision++
	s.mu.Unlock()
	m.publishVirtualLocked()
	// Presentation must arrive promptly; a healthy signaling transport alone must
	// never keep an unseen replacement desktop (or a failed helper) alive forever.
	go m.monitorVirtual(s, backend)
	return proto.Clone(result).(*dieterv1.RemoteDesktopVirtualDisplay), nil
}
func (m *Manager) ConfirmVirtualDisplay(ctx context.Context, r *dieterv1.ConfirmRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	s := m.sessionFor(r.GetSessionId())
	m.controlMu.Lock()
	defer m.controlMu.Unlock()
	if s == nil || !s.active() {
		return nil, ErrNotFound
	}
	if m.controller != s || m.virtualOwner != s {
		return nil, ErrControlOwner
	}
	s.mu.Lock()
	valid := r.GetDisplayGeneration() != 0 && r.DisplayId == m.virtualState.DisplayId && s.status.DisplayId == r.DisplayId && s.status.DisplayGeneration == r.DisplayGeneration && s.status.MediaGeneration == r.DisplayGeneration
	s.mu.Unlock()
	if !valid {
		return nil, errors.New("presented frame does not belong to the current virtual display and media generation")
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	result, err := m.virtualBackend.Exchange(ctx, "confirm", nil)
	if err != nil {
		_, _ = m.restoreVirtualLocked(context.Background())
		return nil, err
	}
	m.virtualState, m.virtualPresented = result, true
	m.publishVirtualLocked()
	return proto.Clone(result).(*dieterv1.RemoteDesktopVirtualDisplay), nil
}
func (m *Manager) RestoreVirtualDisplay(ctx context.Context, id string) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
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
	return m.restoreVirtualLocked(ctx)
}
func (m *Manager) restoreVirtualLocked(ctx context.Context) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	if m.virtualOwner == nil {
		return &dieterv1.RemoteDesktopVirtualDisplay{}, nil
	}
	s, backend, previous := m.virtualOwner, m.virtualBackend, m.virtualPrevious
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	_ = s.releaseNativeInput(ctx)
	result, err := backend.Exchange(ctx, "restore", nil)
	if err == nil && result.GetActive() {
		err = errors.New("virtual display helper did not verify restoration")
	}
	// EOF is a second restoration path; a watchdog independently owns the journal.
	backend.Close()
	m.virtualOwner, m.virtualBackend, m.virtualPrevious, m.virtualState, m.virtualRequest = nil, nil, nil, nil, nil
	m.virtualPresented = false
	if s.active() && previous != nil {
		if source, ok := s.source.(AdaptiveFrameSource); ok {
			if configureErr := source.Configure(ctx, nativeConfiguration(previous)); configureErr != nil {
				err = errors.Join(err, configureErr)
			} else {
				s.mu.Lock()
				s.status.Configuration = previous
				s.applied = nativeConfiguration(previous)
				s.configurationRevision++
				s.mu.Unlock()
			}
		}
	}
	s.mu.Lock()
	s.status.VirtualDisplay = nil
	s.mu.Unlock()
	m.controlGeneration++
	m.publishControlLocked()
	if err != nil {
		m.options.Logger.Error("virtual display restoration failed; recovery journal retained", "session", s.id, "error", err)
		s.emitError("virtual_display_restore", "Virtual display restoration failed: "+err.Error(), false)
	}
	if result == nil {
		result = &dieterv1.RemoteDesktopVirtualDisplay{}
	}
	return result, err
}
func (m *Manager) publishVirtualLocked() {
	if m.virtualOwner == nil {
		return
	}
	m.virtualOwner.mu.Lock()
	m.virtualOwner.status.VirtualDisplay = proto.Clone(m.virtualState).(*dieterv1.RemoteDesktopVirtualDisplay)
	m.virtualOwner.mu.Unlock()
	m.controlGeneration++
	m.publishControlLocked()
}
func (m *Manager) monitorVirtual(s *Session, backend VirtualDisplayBackend) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	deadline := time.Now().Add(15 * time.Second)
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
		}
		m.controlMu.Lock()
		if m.virtualOwner != s || m.virtualBackend != backend {
			m.controlMu.Unlock()
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		state, err := backend.Exchange(ctx, "status", nil)
		cancel()
		expired := !m.virtualPresented && time.Now().After(deadline)
		s.mu.Lock()
		if m.virtualPresented && time.Since(s.lastFeedback) > 3*time.Second {
			expired = true
		}
		s.mu.Unlock()
		failed := err != nil || !state.GetActive() || expired
		if failed {
			_, _ = m.restoreVirtualLocked(context.Background())
		}
		m.controlMu.Unlock()
		if failed {
			return
		}
	}
}
