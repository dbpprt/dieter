package remotedesktop

import (
	"context"
	"errors"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/proto"
)

// MemoryDisplayModes is selected only by the synthetic source used in isolated
// daemon/CLI fixtures. It never accesses the operator's physical display.
type MemoryDisplayModes struct {
	state *dieterv1.RemoteDesktopDisplayModes
}

func (m *MemoryDisplayModes) Close() { m.state = nil }
func (m *MemoryDisplayModes) Exchange(_ context.Context, action, display, mode, expected string) (*dieterv1.RemoteDesktopDisplayModes, error) {
	if m.state == nil {
		m.state = &dieterv1.RemoteDesktopDisplayModes{DisplayId: display, CurrentModeId: "1080", Modes: []*dieterv1.RemoteDesktopDisplayMode{
			{Id: "1080", LogicalWidth: 1920, LogicalHeight: 1080, PixelWidth: 1920, PixelHeight: 1080, RefreshRate: 60},
			{Id: "720", LogicalWidth: 1280, LogicalHeight: 720, PixelWidth: 1280, PixelHeight: 720, RefreshRate: 60},
		}}
	}
	if !m.state.Temporary {
		m.state.DisplayId = display
	}
	switch action {
	case "list":
	case "set":
		if display != m.state.DisplayId || expected != m.state.CurrentModeId || (mode != "1080" && mode != "720") {
			return nil, errors.New("display changed; refresh modes")
		}
		if m.state.CurrentModeId != mode {
			if !m.state.Temporary {
				m.state.OriginalModeId = m.state.CurrentModeId
			}
			m.state.CurrentModeId = mode
			m.state.Temporary = true
		}
	case "restore":
		if m.state.Temporary {
			m.state.CurrentModeId = m.state.OriginalModeId
		}
		m.state.OriginalModeId = ""
		m.state.Temporary = false
	default:
		return nil, errors.New("invalid display action")
	}
	return proto.Clone(m.state).(*dieterv1.RemoteDesktopDisplayModes), nil
}
