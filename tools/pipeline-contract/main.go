// pipeline-contract validates bounded data; Fastlane owns execution scheduling.
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
	root, err := os.Getwd()
	if err == nil {
		err = pipeline.Contract(ctx, root, os.Args[1:], os.Stdin, os.Stdout)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "pipeline-contract:", err)
		os.Exit(1)
	}
}
