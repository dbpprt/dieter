package daemon

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
	"github.com/dbpprt/dieter/internal/host/machine"
	"github.com/dbpprt/dieter/internal/host/serviceruntime"
	"github.com/dbpprt/dieter/internal/platform/config"
)

// worker returns a hidden daemon-side entry point run by package managers and
// detached updaters. Workers run before any configuration or store is opened.
func worker(name string) (func(args []string, output io.Writer) error, bool) {
	switch name {
	case "__service-stage":
		return stageServiceRuntime, true
	case "__harness-prepare":
		return prepareHarnessRuntime, true
	case "__harness-runtime-archive":
		return buildHarnessRuntimeArchive, true
	case "__daemon-update-worker":
		return machine.RunDaemonUpdateWorker, true
	case "__linux-update-worker":
		return machine.RunLinuxDaemonUpdateWorker, true
	}
	return nil, false
}

// Called by Homebrew before CLI construction: its sandbox has an isolated HOME
// and must never initialize Dieter user data, run capture, or start a service.
func stageServiceRuntime(args []string, output io.Writer) error {
	flags := flag.NewFlagSet("service runtime staging", flag.ContinueOnError)
	flags.SetOutput(output)
	root := flags.String("root", "", "absolute Homebrew service runtime directory")
	bundlePrefix := flags.String("bundle-prefix", "", "companion bundle directory relative to the standalone binaries")
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
	runtime := serviceruntime.PlatformRuntime(*root)
	runtime.SourceBundlePrefix = *bundlePrefix
	return runtime.Stage(ctx, filepath.Dir(executable))
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
	reference, err := harness.NewSubprocessRunner(*root, harnessEnvironment(config.LoadDaemon(config.Environ()))).PrepareRuntime(ctx, "")
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(output, "prepared harness runtime %s (protocol %s)\n", reference.Digest, reference.ProtocolVersion)
	return err
}
