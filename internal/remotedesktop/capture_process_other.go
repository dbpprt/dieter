//go:build !darwin && !linux

package remotedesktop

import "os/exec"

func configureCaptureCommand(command *exec.Cmd) {}
