//go:build linux

package cli

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func platformDoctorChecks() []doctorCheck {
	checks := []doctorCheck{
		commandDoctorCheck("systemctl", false, "--version", nil),
		commandDoctorCheck("busctl", false, "--version", nil),
		commandDoctorCheck("cosign", false, "version", nil),
	}
	manager := doctorCheck{Name: "systemd-user-manager", Required: false, Status: "warning", Detail: "unavailable; foreground mode remains available"}
	if command, err := systemctlUserCommand("show-environment"); err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		command = exec.CommandContext(ctx, command.Path, command.Args[1:]...)
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
