package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/serviceruntime"
)

// Called by Homebrew before CLI construction: its sandbox has an isolated HOME
// and must never initialize Dieter user data, run capture, or start a service.
func stageServiceRuntime(args []string, output io.Writer) error {
	flags := flag.NewFlagSet("service runtime staging", flag.ContinueOnError)
	flags.SetOutput(output)
	root := flags.String("root", "", "absolute Homebrew service runtime directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *root == "" {
		return errors.New("service runtime staging requires --root PATH")
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	return (serviceruntime.Runtime{Root: *root}).Stage(ctx, filepath.Dir(executable))
}

// prepareHarnessRuntime is run from the signed candidate service binary after
// package staging but before the current daemon is restarted. It touches only
// the content-addressed harness cache and never opens Dieter's durable store.
func prepareHarnessRuntime(args []string, output io.Writer) error {
	flags := flag.NewFlagSet("harness runtime preparation", flag.ContinueOnError)
	flags.SetOutput(output)
	root := flags.String("root", "", "absolute DIETER_HOME directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || !filepath.IsAbs(*root) || filepath.Clean(*root) != *root {
		return errors.New("harness runtime preparation requires --root ABSOLUTE_PATH")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	reference, err := harness.NewSubprocessRunner(*root).PrepareRuntime(ctx, "")
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(output, "prepared harness runtime %s (protocol %s)\n", reference.Digest, reference.ProtocolVersion)
	return err
}
