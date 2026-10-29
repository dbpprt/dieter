package remotedesktop

import (
	"context"
	"errors"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/proto"
)

// MemoryVirtualDisplay is an isolated fixture. It never changes a host display.
type MemoryVirtualDisplay struct {
	state   *dieterv1.RemoteDesktopVirtualDisplay
	disable bool
}

func (m *MemoryVirtualDisplay) Exchange(_ context.Context, action string, r *dieterv1.SetRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	if m.state == nil {
		m.state = &dieterv1.RemoteDesktopVirtualDisplay{}
	}
	switch action {
	case "create":
		if m.state.Active {
			return nil, errors.New("virtual display already active")
		}
		m.disable = r.DisablePhysical
		m.state = &dieterv1.RemoteDesktopVirtualDisplay{Active: true, DisplayId: "virtual-synthetic", OriginalDisplayId: "synthetic", PixelWidth: r.PixelWidth, PixelHeight: r.PixelHeight, Scale: r.Scale, AwaitingPresentation: r.DisablePhysical}
	case "confirm":
		if !m.state.Active {
			return nil, errors.New("no virtual display")
		}
		m.state.AwaitingPresentation = false
		m.state.PhysicalDisabled = m.disable
	case "restore":
		m.state = &dieterv1.RemoteDesktopVirtualDisplay{}
	case "status":
	default:
		return nil, errors.New("invalid virtual display action")
	}
	return proto.Clone(m.state).(*dieterv1.RemoteDesktopVirtualDisplay), nil
}
func (m *MemoryVirtualDisplay) Close() { m.state = &dieterv1.RemoteDesktopVirtualDisplay{} }
