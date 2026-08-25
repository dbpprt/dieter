//go:build !darwin && !linux && !windows

package remotedesktop

import "os/exec"

func configureCaptureCommand(command *exec.Cmd) {}
