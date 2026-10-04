package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/dbpprt/dieter/internal/pipeline"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := pipeline.Support(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "pipeline-support:", err)
		os.Exit(1)
	}
}
