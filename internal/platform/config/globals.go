// Package config owns process configuration for the dieter binaries: the
// global command-line options and every DIETER_* environment variable. It is
// the only package that reads the process environment; everything below the
// composition roots receives typed values.
package config

import (
	"flag"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Globals are the options accepted before any dieter command.
type Globals struct {
	Home          string
	HarnessConfig string
	Gateway       string
	Machine       string
	Timeout       time.Duration
	Help          bool
	Version       bool
}

// ParseGlobals parses the global options and returns the remaining command
// arguments. Home defaults to DefaultHome.
func ParseGlobals(args []string) (Globals, []string, error) {
	var globals Globals
	set := flag.NewFlagSet("dieter", flag.ContinueOnError)
	set.SetOutput(io.Discard)
	set.StringVar(&globals.Home, "store", "", "DIETER_HOME data directory")
	short := set.String("s", "", "DIETER_HOME data directory")
	set.StringVar(&globals.HarnessConfig, "harness-config", "", "harness registry YAML")
	set.StringVar(&globals.Gateway, "gateway", "", "gateway origin; must match the local daemon enrollment")
	set.StringVar(&globals.Machine, "machine", "", "target enrolled daemon ID or exact name")
	set.DurationVar(&globals.Timeout, "timeout", 15*time.Second, "command timeout")
	set.BoolVar(&globals.Help, "help", false, "help")
	set.BoolVar(&globals.Help, "h", false, "help")
	set.BoolVar(&globals.Version, "version", false, "version")
	if err := set.Parse(args); err != nil {
		return Globals{}, nil, err
	}
	if *short != "" {
		globals.Home = *short
	}
	globals.Home = ResolveHome(globals.Home)
	return globals, set.Args(), nil
}

// DefaultHome is DIETER_HOME, or ~/.dieter when it is unset.
func DefaultHome() string {
	if value := os.Getenv("DIETER_HOME"); value != "" {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".dieter"
	}
	return filepath.Join(home, ".dieter")
}

// ResolveHome returns an absolute data directory, defaulting an empty value
// to DefaultHome.
func ResolveHome(root string) string {
	if strings.TrimSpace(root) == "" {
		root = DefaultHome()
	}
	if !filepath.IsAbs(root) {
		if absolute, err := filepath.Abs(root); err == nil {
			root = absolute
		}
	}
	return root
}
