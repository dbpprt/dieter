package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"

	"github.com/dbpprt/dieter/internal/envfile"
	"github.com/dbpprt/dieter/internal/gateway"
)

func main() {
	root := flag.String("store", gateway.DefaultRoot(), "gateway state directory")
	envFile := flag.String("env-file", "", "environment file (default gateway home/.env)")
	verbose := flag.Bool("verbose", false, "verbose logs")
	flag.Parse()
	if err := envfile.Load(*root, *envFile); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	config, err := gateway.ConfigFromEnv(*root)
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
	if err := gateway.Listen(config, store, logger); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
