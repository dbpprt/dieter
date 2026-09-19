package remotedesktop

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func executableIdentity(options SourceOptions) (string, string) {
	daemon, _ := os.Executable()
	if resolved, err := filepath.EvalSymlinks(daemon); err == nil {
		daemon = resolved
	}
	helper, _, _ := CaptureExecutable(options)
	if resolved, err := filepath.EvalSymlinks(helper); helper != "" && err == nil {
		helper = resolved
	}
	return daemon, helper
}

// ProbePermissions runs in the service's responsible-process context. Admission
// is nonblocking and shared across all transports to bound helper processes.
func (m *Manager) ProbePermissions(ctx context.Context, requestControl bool) (*dieterv1.RemoteDesktopPermissionProbe, error) {
	if !m.permissionMu.TryLock() {
		return nil, ErrBusy
	}
	defer m.permissionMu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, captureProbeTimeout+10*time.Second)
	defer cancel()
	daemon, helper := executableIdentity(m.options.Source)
	result := &dieterv1.RemoteDesktopPermissionProbe{Platform: runtime.GOOS, DaemonExecutable: daemon, CaptureExecutable: helper}
	probeSource := m.options.Source
	if runtime.GOOS == "linux" && requestControl {
		// One RemoteDesktop portal session verifies both the selected source and
		// the granted pointer/keyboard devices without injecting any input.
		probeSource.Control = true
	}
	if err := m.options.CaptureProbe(ctx, probeSource); err != nil {
		result.CaptureError = err.Error()
	} else {
		result.CaptureVerified = true
	}
	controlRequest := requestControl
	if runtime.GOOS == "linux" {
		// The capture probe above owns the single interactive portal request.
		controlRequest = false
	}
	if err := m.options.ControlProbe(ctx, probeSource, controlRequest); err != nil {
		result.ControlError = err.Error()
	} else {
		result.ControlVerified = true
	}
	// A fresh explicit probe invalidates the passive capability cache, including
	// previous denied results after the user changes System Settings.
	m.capabilityMu.Lock()
	m.cachedCapabilities = nil
	m.capabilityMu.Unlock()
	return result, ctx.Err()
}
