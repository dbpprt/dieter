package cli

import (
	"context"
	"errors"
	"flag"
	"io"
	"os"
	"path/filepath"
	"time"

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
