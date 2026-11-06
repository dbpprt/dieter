//go:build !linux

package machine

import (
	"errors"
	"io"
)

func RunLinuxDaemonUpdateWorker([]string, io.Writer) error {
	return errors.New("Linux update worker is unavailable on this platform")
}
