//go:build !linux

package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"time"

	"github.com/dbpprt/dieter/internal/platform/config"
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

func installAndStartPlatformService(config.Env, string, io.Writer) error {
	return errors.New("platform service installation is unavailable")
}

func serviceStartHint() string { return "Skipped; start it with `brew services start dieter`." }
func managedServiceStatus(_ config.Env, manager string) string {
	if manager == "homebrew" {
		return homebrewServiceStatus()
	}
	return "unknown"
}

func homebrewServiceStatus() string {
	brew, err := exec.LookPath("brew")
	if err != nil {
		return "unknown"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	raw, err := exec.CommandContext(ctx, brew, "services", "info", "--all", "--json").Output()
	if err != nil {
		return "unknown"
	}
	var items []struct {
		Name   string `json:"name"`
		Status string `json:"status"`
	}
	if json.Unmarshal(raw, &items) != nil {
		return "unknown"
	}
	for _, item := range items {
		if item.Name == "dieter" {
			return item.Status
		}
	}
	return "not registered"
}
