package daemon

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
)

// buildHarnessRuntimeArchive is run by the release lanes with a development
// build of the release source, on each target platform. It installs the
// embedded harness runtime and the managed Bun exactly as a source-built
// daemon does and writes the prebuilt archive whose SHA-256 the release
// daemon pins. It touches neither DIETER_HOME nor a running daemon.
func buildHarnessRuntimeArchive(args []string, output io.Writer) error {
	flags := flag.NewFlagSet("harness runtime archive", flag.ContinueOnError)
	flags.SetOutput(output)
	path := flags.String("output", "", "archive path; its name must be this platform's release asset")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *path == "" {
		return errors.New("harness runtime archive requires --output PATH")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	started := time.Now()
	archive, err := harness.BuildRuntimeArchive(ctx, *path)
	if err != nil {
		return err
	}
	agents := make([]string, 0, len(archive.Agents))
	for name, agent := range archive.Agents {
		agents = append(agents, fmt.Sprintf("%s %s (%s@%s, %s)", name, agent.Version, agent.Package, agent.PackageVersion, agent.Native))
	}
	sort.Strings(agents)
	_, err = fmt.Fprintf(output, "wrote %s (%d bytes, sha256 %s, harness runtime %s) in %s\nverified agents: %s\n",
		archive.Path, archive.Size, archive.SHA256, archive.RuntimeDigest, time.Since(started).Round(time.Second), strings.Join(agents, "; "))
	return err
}
