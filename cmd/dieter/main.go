// Command dieter is both the local daemon and its automation client. Daemon
// entry points (serve, daemon start, and hidden package-manager workers) run
// through internal/daemon; every other command is a client of a running
// daemon API and runs through internal/cli.
package main

import (
	"os"

	"github.com/dbpprt/dieter/internal/cli"
	"github.com/dbpprt/dieter/internal/daemon"
)

func main() {
	args := os.Args[1:]
	if daemon.Handles(args) {
		os.Exit(daemon.Main(args))
	}
	os.Exit(cli.Main(args))
}
