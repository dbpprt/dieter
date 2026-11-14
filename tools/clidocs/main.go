// Command clidocs writes a Markdown reference of the dieter CLI, generated
// from the same command table that dispatches commands. Every section is a
// command's offline --help output, so the reference never drifts from the
// binary.
//
//	go run ./tools/clidocs -o PATH    write the reference to PATH
//	go run ./tools/clidocs            write it to standard output
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"

	"github.com/dbpprt/dieter/internal/cli"
	"github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/platform/fsx"
)

func main() {
	output := flag.String("o", "", "write the Markdown reference to this path instead of standard output")
	flag.Parse()
	if flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: go run ./tools/clidocs [-o PATH]")
		os.Exit(2)
	}
	var reference bytes.Buffer
	if err := cli.WriteReference(&reference, daemon.StartUsage); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	if *output == "" {
		_, _ = os.Stdout.Write(reference.Bytes())
		return
	}
	if err := fsx.WriteFile(*output, reference.Bytes(), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
