// Command dieter-gateway is the machine-only Dieter gateway: account
// sessions, daemon identities, presence, and the authenticated relay.
package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"

	"github.com/dbpprt/dieter/internal/gateway"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/platform/config"
)

func main() {
	root := flag.String("store", gateway.DefaultRoot(config.Environ()), "gateway state directory")
	envFile := flag.String("env-file", "", "environment file (default gateway home/.env)")
	verbose := flag.Bool("verbose", false, "verbose logs")
	version := flag.Bool("version", false, "print version")
	flag.Parse()
	if *version {
		fmt.Fprintln(os.Stdout, buildinfo.ReleaseVersion)
		return
	}
	if err := config.LoadEnvFile(*root, *envFile); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	cfg, err := gateway.ConfigFromEnv(config.Environ(), *root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	store, err := gateway.OpenStore(*root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	defer store.Close()
	level := slog.LevelInfo
	if *verbose {
		level = slog.LevelDebug
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	if err := gateway.Listen(cfg, store, logger); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
