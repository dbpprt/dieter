package remotedesktop

import (
	"context"
	"errors"
	"sort"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/proto"
)

// controlMu serializes the last ownership check with native input delivery and
// handoff. No queued input from a retired grant can run after its release.
func (m *Manager) SetControl(ctx context.Context, id string, take bool) (*dieterv1.RemoteDesktopSessionState, error) {
	s := m.sessionFor(id)
	if s == nil {
		return nil, ErrNotFound
	}
	m.controlMu.Lock()
	defer m.controlMu.Unlock()
	if !s.active() {
		return nil, ErrNotFound
	}
	if !s.control {
		return nil, ErrControlDisabled
	}
	if s.protocol < 3 {
		return nil, errors.New("update this client to use control handoff")
	}
	if take && m.controller != s {
		if m.controller != nil {
			if m.controller.protocol < 3 {
				return nil, ErrControlOwner
			}
			if err := m.controller.releaseNativeInput(ctx); err != nil {
				return nil, err
			}
		}
		m.controller = s
		m.controlGeneration++
	} else if !take && m.controller == s {
		if err := s.releaseNativeInput(ctx); err != nil {
			return nil, err
		}
		m.controller = nil
		m.controlGeneration++
	}
	m.publishControlLocked()
	return m.SessionState(id)
}

func (m *Manager) publishControlLocked() {
	sessions := m.allSessions()
	name := ""
	if m.controller != nil {
		name = m.controller.clientName
		if name == "" {
			name = "Another client"
		}
	}
	for _, s := range sessions {
		s.mu.Lock()
		s.status.ControlActive = m.controller == s
		s.status.ControlGeneration = m.controlGeneration
		s.status.ControllerName = name
		s.status.ConnectedClients = uint32(len(sessions))
		state := proto.Clone(s.status).(*dieterv1.RemoteDesktopSessionState)
		s.mu.Unlock()
		// Include ownership in signaling history as well as the authenticated data
		// channel, so initial connection and route replacement see the same state.
		s.emit(&dieterv1.RemoteDesktopSignal{Payload: &dieterv1.RemoteDesktopSignal_State{State: state}})
		s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_State{State: state}})
	}
}

func (m *Manager) Sessions() *dieterv1.RemoteDesktopSessions {
	result := &dieterv1.RemoteDesktopSessions{MaxClients: maxClients}
	m.controlMu.Lock()
	defer m.controlMu.Unlock()
	for _, s := range m.allSessions() {
		s.mu.Lock()
		result.Sessions = append(result.Sessions, &dieterv1.RemoteDesktopSessionInfo{
			SessionId: s.id, ClientName: s.clientName, DisplayId: s.status.DisplayId,
			ControlAllowed: s.control, ControlActive: m.controller == s, InputProtocolVersion: s.protocol,
		})
		s.mu.Unlock()
	}
	sort.Slice(result.Sessions, func(i, j int) bool { return result.Sessions[i].SessionId < result.Sessions[j].SessionId })
	result.CaptureStreams, result.Encoders = m.media.Counts()
	return result
}

func (s *Session) releaseNativeInput(ctx context.Context) error {
	sink, ok := s.source.(InputSink)
	if !ok {
		return nil
	}
	// A native acknowledgment is required for transfer. A failed release cannot
	// grant another client authority while old keys may still be held.
	if release, ok := sink.(interface{ ReleaseInputChecked(context.Context) error }); ok {
		return release.ReleaseInputChecked(ctx)
	}
	sink.ReleaseInput(ctx)
	return nil
}
