//go:build !linux

package cli

import (
	"errors"
	"fmt"
	"io"
)

func platformServiceCommand(c *CLI, action string, args []string) error {
	usage := "Usage: dieter daemon service " + action + "\n"
	for _, arg := range args {
		if arg == "--help" || arg == "-h" {
			fmt.Fprint(c.Out, usage)
			return nil
		}
	}
	if len(args) != 0 {
		return errors.New(usage)
	}
	return errors.New("daemon service management is provided by Homebrew on macOS")
}

func installAndStartPlatformService(string, io.Writer) error {
	return errors.New("platform service installation is unavailable")
}

func serviceStartHint() string { return "Skipped; start it with `brew services start dieter`." }
func managedServiceStatus(manager string) string {
	if manager == "homebrew" {
		return homebrewServiceStatus()
	}
	return "unknown"
}
func notifyServiceReady(string) error { return nil }
