//go:build linux

package cli

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/remotedesktop"
)

func platformDoctorChecks() []doctorCheck {
	checks := []doctorCheck{
		commandDoctorCheck("systemctl", false, "--version", nil),
		commandDoctorCheck("busctl", false, "--version", nil),
		commandDoctorCheck("cosign", false, "version", nil),
		commandDoctorCheck("gst-inspect-1.0", false, "--version", nil),
	}
	checks = append(checks, linuxScreenDoctorChecks()...)
	manager := doctorCheck{Name: "systemd-user-manager", Required: false, Status: "warning", Detail: "unavailable; foreground mode remains available"}
	if command, err := systemctlUserCommand("show-environment"); err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		environment := command.Env
		command = exec.CommandContext(ctx, command.Path, command.Args[1:]...)
		command.Env = environment
		if err := command.Run(); err == nil {
			manager.Status, manager.Detail = "ok", "available"
		}
		cancel()
	}
	checks = append(checks, manager)

	unit, unitErr := systemdUserUnitPath()
	service := doctorCheck{Name: "systemd-user-service", Required: false, Status: "warning", Detail: "not installed; run `dieter daemon service install`"}
	if unitErr == nil {
		if raw, readErr := os.ReadFile(unit); readErr == nil {
			service.Status, service.Detail = "ok", unit
			if !strings.HasPrefix(string(raw), managedSystemdUnitHeader) {
				service.Status, service.Detail = "warning", unit+" is not managed by Dieter"
			}
		} else if !errors.Is(readErr, os.ErrNotExist) {
			service.Status, service.Detail = "warning", readErr.Error()
		}
	}
	checks = append(checks, service)

	linger := doctorCheck{Name: "login-linger", Required: false, Status: "warning", Detail: "disabled; the user service starts after login"}
	if loginctl, lookErr := exec.LookPath("loginctl"); lookErr == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		raw, runErr := exec.CommandContext(ctx, loginctl, "show-user", strconv.Itoa(os.Getuid()), "--property=Linger", "--value").Output()
		cancel()
		if runErr == nil && strings.TrimSpace(string(raw)) == "yes" {
			linger.Status, linger.Detail = "ok", "enabled; the user service may start before interactive login"
		} else if runErr != nil {
			linger.Detail = "could not query loginctl; enable lingering only when boot-before-login is required"
		}
	} else {
		linger.Detail = "loginctl unavailable; boot-before-login persistence cannot be inspected"
	}
	return append(checks, linger)
}

func linuxScreenDoctorChecks() []doctorCheck {
	helper := doctorCheck{Name: "linux-capture-helper", Required: false, Status: "warning", Detail: "dieter-capture is not installed beside the daemon or in PATH"}
	backend := doctorCheck{Name: "linux-screen-backend", Required: false, Status: "warning", Detail: "not probed because the capture helper is unavailable"}
	options := remotedesktop.SourceOptions{Kind: "screen", HelperPath: strings.TrimSpace(os.Getenv("DIETER_REMOTE_DESKTOP_HELPER"))}
	if path, _, err := remotedesktop.CaptureExecutable(options); err == nil {
		helper.Status, helper.Detail = "ok", path
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		capabilities, probeErr := remotedesktop.ProbeCapabilities(ctx, options)
		cancel()
		if probeErr != nil {
			backend.Detail = probeErr.Error()
		} else if !capabilities.GetGraphicalSessionActive() || len(capabilities.GetDisplays()) == 0 || len(capabilities.GetCodecs()) == 0 {
			backend.Detail = capabilities.GetUnavailableReason()
			if backend.Detail == "" {
				backend.Detail = "no usable graphical capture session or H.264 encoder"
			}
		} else {
			backend.Status = "ok"
			backend.Detail = fmt.Sprintf("%s; %d display(s); encoder %s", capabilities.GetPlatform(), len(capabilities.GetDisplays()), capabilities.GetEncoder())
		}
	}
	return []doctorCheck{helper, backend}
}
