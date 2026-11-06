// Package daemon is the composition root of the Dieter daemon. It parses the
// daemon configuration once, opens central storage, wires the engine, host
// services, API server, gateway link, and replication, and owns the process
// lifecycle from startup recovery to graceful shutdown.
package daemon

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/dbpprt/dieter/internal/platform/config"
)

// StartUsage documents `dieter daemon start` and its `dieter serve` alias.
const StartUsage = `Usage: dieter daemon start [--addr ADDRESS] [--direct-addr ADDRESS --direct-host HOST [--direct-network lan|tailscale|public|loopback]] [--env-file PATH] [--service [--runtime PATH]] [--verbose]

Run the machine-local Dieter data plane and, when enrolled, its persistent
outbound gateway tunnel. The local API is always loopback-only. An enrolled
daemon automatically advertises an authenticated loopback route; direct flags
add an optional LAN (the default --direct-network), Tailscale, or public route.
A package manager may supply --runtime with a fixed executable directory.
Service startup activates a staged verified release there before workers begin.
An enrolled daemon also verifies any gateway-signed endpoint relocation at startup,
preserving its enrolled identity and shared account. Discovery failure retains
its current address. Status reports the selected network endpoint.
`

// Config is every input of one daemon process.
type Config struct {
	// Home is the absolute DIETER_HOME directory.
	Home string
	// HarnessConfig is an explicit harness registry YAML; empty uses
	// Env.HarnessConfig, then DIETER_HOME/harnesses.yaml, then the embedded
	// catalog.
	HarnessConfig string
	// Addr is the loopback listen address of the raw local API.
	Addr string
	// DirectAddr, DirectHost, and DirectNetwork configure an optional
	// additional authenticated TLS route.
	DirectAddr, DirectHost, DirectNetwork string
	// EnvFile is loaded into the process environment; empty uses
	// DIETER_HOME/.env.
	EnvFile string
	// ServiceMode runs as a managed service with bounded file logs.
	ServiceMode bool
	// RuntimePath is a fixed package-manager service runtime.
	RuntimePath string
	Verbose     bool
	// Stderr receives foreground logs.
	Stderr io.Writer
	// Env is the environment configuration. Nil makes Run load it once, after
	// the env file, so .env values apply; fixtures may preset it.
	Env *config.Daemon
}

// Handles reports whether args select a daemon-side entry point: a hidden
// worker, `serve`, or `daemon start`. Everything else belongs to the CLI.
func Handles(args []string) bool {
	if len(args) > 0 {
		if _, ok := worker(args[0]); ok {
			return true
		}
	}
	globals, rest, err := config.ParseGlobals(args)
	if err != nil || globals.Help || globals.Version {
		return false
	}
	return isStart(rest)
}

func isStart(rest []string) bool {
	return len(rest) > 0 && (rest[0] == "serve" || len(rest) > 1 && rest[0] == "daemon" && rest[1] == "start")
}

// Main runs a daemon-side entry point selected by Handles and returns the
// process exit code.
func Main(args []string) int {
	if len(args) > 0 {
		if run, ok := worker(args[0]); ok {
			if err := run(args[1:], os.Stderr); err != nil {
				fmt.Fprintln(os.Stderr, "error:", err)
				return 1
			}
			return 0
		}
	}
	globals, rest, err := config.ParseGlobals(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	if !isStart(rest) {
		fmt.Fprintln(os.Stderr, "error: not a daemon command")
		return 2
	}
	if rest[0] == "daemon" {
		rest = rest[1:]
	}
	cfg, help, err := ParseStart(globals, rest[1:], os.Stdout)
	if help {
		return 0
	}
	if err == nil {
		cfg.Stderr = os.Stderr
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		err = Run(ctx, cfg)
		cancel()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	return 0
}

// ParseStart parses `daemon start` options. It prints StartUsage to out and
// reports help when --help or -h is present.
func ParseStart(globals config.Globals, args []string, out io.Writer) (Config, bool, error) {
	set := flag.NewFlagSet("daemon start", flag.ContinueOnError)
	set.SetOutput(io.Discard)
	cfg := Config{Home: globals.Home, HarnessConfig: globals.HarnessConfig}
	set.StringVar(&cfg.Addr, "addr", "127.0.0.1:4242", "listen address")
	set.StringVar(&cfg.DirectAddr, "direct-addr", "", "optional authenticated TLS listen address")
	set.StringVar(&cfg.DirectHost, "direct-host", "", "host advertised for the direct TLS route")
	set.StringVar(&cfg.DirectNetwork, "direct-network", "lan", "direct route kind: loopback, lan, tailscale, or public")
	set.StringVar(&cfg.EnvFile, "env-file", "", "environment file (default DIETER_HOME/.env)")
	set.BoolVar(&cfg.ServiceMode, "service", false, "run as a managed service with bounded file logs")
	set.StringVar(&cfg.RuntimePath, "runtime", "", "fixed service runtime; requires --service")
	set.BoolVar(&cfg.Verbose, "verbose", false, "verbose logs")
	for _, arg := range args {
		if arg == "--help" || arg == "-h" {
			fmt.Fprint(out, StartUsage)
			return Config{}, true, nil
		}
	}
	if err := set.Parse(interspersed(set, args)); err != nil {
		return Config{}, false, fmt.Errorf("%w\n\n%s", err, StartUsage)
	}
	if cfg.RuntimePath != "" && !cfg.ServiceMode {
		return Config{}, false, errors.New("--runtime requires --service")
	}
	host, _, err := net.SplitHostPort(cfg.Addr)
	if err != nil {
		return Config{}, false, fmt.Errorf("invalid listen address: %w", err)
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return Config{}, false, errors.New("unrestricted local harnesses require a loopback listen address")
	}
	return cfg, false, nil
}

// interspersed moves flags before positional arguments so options may follow
// the command words, matching the CLI's parser.
func interspersed(set *flag.FlagSet, args []string) []string {
	var opts, pos []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if strings.HasPrefix(arg, "-") && arg != "-" {
			opts = append(opts, arg)
			name := strings.TrimLeft(arg, "-")
			if strings.Contains(name, "=") {
				continue
			}
			if field := set.Lookup(name); field != nil {
				if b, ok := field.Value.(interface{ IsBoolFlag() bool }); ok && b.IsBoolFlag() {
					continue
				}
				if i+1 < len(args) {
					i++
					opts = append(opts, args[i])
				}
			}
		} else {
			pos = append(pos, arg)
		}
	}
	return append(opts, pos...)
}
