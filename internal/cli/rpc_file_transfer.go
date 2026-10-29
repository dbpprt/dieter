package cli

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path"
	"strings"
	"sync"
	"syscall"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"golang.org/x/sys/unix"
)

type transferRuleFlag struct {
	rules   *[]files.Rule
	include bool
}

func (v transferRuleFlag) String() string { return "" }
func (v transferRuleFlag) Set(value string) error {
	r := files.Rule{Pattern: value, Include: v.include}
	if err := r.Validate(); err != nil {
		return err
	}
	*v.rules = append(*v.rules, r)
	return nil
}

func (c *CLI) rpcFileTransfer(action string, args []string) error {
	usage := "Usage: dieter file " + action + " (--project PROJECT|--card CARD) [--checkout ID] [OPTIONS] SOURCE DESTINATION\n\nExactly one endpoint must start with remote:; other paths are on this CLI machine.\nRemote paths are relative to the selected workspace. Directories copy their contents.\nOptions: --recursive (cp), --dryrun, --delete (sync only), --checksum, --size-only,\n  --no-clobber, ordered --exclude GLOB / --include GLOB, --concurrency N (1..8),\n  --bandwidth-limit BYTES_PER_SECOND, --no-progress, --format text|jsonl.\nSync compares size and modification time; --checksum compares SHA-256 instead.\nHidden files are included; .git and transfer partials are protected. Symlinks and\nspecial files are unsupported. Empty directories are not copied. Delete runs only\nafter a complete successful scan and copy phase; excluded files are protected.\nRerun an interrupted command to resume. Uploads expire after 24 hours.\n"
	set := flags("file " + action)
	project, card, checkout := addFileScopeFlags(set)
	recursive := set.Bool("recursive", false, "copy directory contents recursively")
	dry := set.Bool("dryrun", false, "print the plan without changing files")
	remove := set.Bool("delete", false, "delete destination-only files after successful sync")
	checksum := set.Bool("checksum", false, "compare SHA-256 instead of modification times")
	sizeOnly := set.Bool("size-only", false, "compare file sizes only")
	noClobber := set.Bool("no-clobber", false, "skip existing destination files")
	concurrency := set.Int("concurrency", 4, "parallel files, 1..8")
	bandwidth := set.Int64("bandwidth-limit", 0, "aggregate bytes per second; 0 is unlimited")
	noProgress := set.Bool("no-progress", false, "disable progress on stderr")
	format := set.String("format", "text", "text or jsonl")
	var rules []files.Rule
	set.Var(transferRuleFlag{&rules, false}, "exclude", "exclude matching relative paths")
	set.Var(transferRuleFlag{&rules, true}, "include", "include matching relative paths (last match wins)")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 2 {
		return errors.New("SOURCE and DESTINATION required")
	}
	if *concurrency < 1 || *concurrency > 8 || *bandwidth < 0 {
		return errors.New("concurrency must be 1..8 and bandwidth nonnegative")
	}
	if *format != "text" && *format != "jsonl" {
		return errors.New("format must be text or jsonl")
	}
	if *checksum && *sizeOnly {
		return errors.New("--checksum and --size-only are mutually exclusive")
	}
	if *remove && action != "sync" {
		return errors.New("--delete requires sync")
	}
	srcArg, dstArg := set.Arg(0), set.Arg(1)
	srcRemote, dstRemote := strings.HasPrefix(srcArg, "remote:"), strings.HasPrefix(dstArg, "remote:")
	if srcRemote == dstRemote {
		return errors.New("exactly one endpoint must use remote:")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if c.Timeout > 0 {
		var timeoutCancel context.CancelFunc
		ctx, timeoutCancel = context.WithTimeout(ctx, c.Timeout)
		defer timeoutCancel()
	}
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
	if err != nil {
		return err
	}
	endpoint := func(arg string, remote bool) (transferEndpoint, error) {
		if !remote {
			return localTransferEndpoint(arg)
		}
		p, err := files.Clean(strings.TrimPrefix(arg, "remote:"))
		if err != nil {
			return transferEndpoint{}, err
		}
		e := transferEndpoint{remote: true, base: p, client: client, scope: &dieterv1.TransferPath{}}
		e.scope.ProjectId = projectID
		e.scope.CardId = cardID
		e.scope.CheckoutId = *checkout
		return e, nil
	}
	source, err := endpoint(srcArg, srcRemote)
	if err != nil {
		return err
	}
	destination, err := endpoint(dstArg, dstRemote)
	if err != nil {
		return err
	}
	src, err := source.stat(rpcCtx, ".", false)
	if err != nil {
		return err
	}
	if src.Kind == files.Missing {
		return errors.New("source does not exist")
	}
	dst, err := destination.stat(rpcCtx, ".", false)
	if err != nil {
		return err
	}
	if src.Revision == dst.Revision {
		return errors.New("source and destination are the same filesystem entry")
	}
	directory := action == "sync" || *recursive
	if directory && src.Kind != "directory" {
		return errors.New("sync/recursive copy requires a source directory")
	}
	if !directory && src.Kind != "file" {
		return errors.New("use --recursive to copy a directory")
	}
	var sourceTree, destTree map[string]files.Entry
	if directory {
		if err = transferOverlap(rpcCtx, source, destination, src, dst); err != nil {
			return err
		}
		sourceTree, err = source.inventory(rpcCtx, *checksum)
		if err != nil {
			return err
		}
		destTree, err = destination.inventory(rpcCtx, *checksum)
		if err != nil {
			return err
		}
		for _, e := range sourceTree {
			if e.Kind == "directory" && e.Revision == dst.Revision {
				return errors.New("destination overlaps source tree")
			}
		}
		for _, e := range destTree {
			if e.Kind == "directory" && e.Revision == src.Revision {
				return errors.New("source overlaps destination tree")
			}
		}
	} else {
		if dst.Kind == "directory" || strings.HasSuffix(dstArg, "/") {
			destination.base = path.Join(destination.base, path.Base(source.base))
			dst, err = destination.stat(rpcCtx, ".", false)
			if err != nil {
				return err
			}
		}
		sourceTree = map[string]files.Entry{".": src}
		destTree = map[string]files.Entry{}
		if dst.Kind != files.Missing {
			destTree["."] = dst
		}
	}
	options := files.PlanOptions{Sync: action == "sync", Delete: *remove, Checksum: *checksum, SizeOnly: *sizeOnly, NoClobber: *noClobber, Rules: rules}
	if !directory {
		if !files.Included(path.Base(source.base), rules) {
			return nil
		}
		// The single-file endpoint uses "." internally; filters use its filename.
		options.Rules = nil
	}
	plan, err := files.Plan(sourceTree, destTree, options)
	if err != nil {
		return err
	}
	var outputMu sync.Mutex
	emit := func(a files.Action, state string) error {
		outputMu.Lock()
		defer outputMu.Unlock()
		if *format == "jsonl" {
			return json.NewEncoder(c.Out).Encode(struct {
				Action string `json:"action"`
				Path   string `json:"path"`
				State  string `json:"state"`
				Bytes  int64  `json:"bytes"`
			}{a.Kind, a.Path, state, a.Source.Size})
		}
		_, err := fmt.Fprintf(c.Out, "%s: %s (%s)\n", a.Kind, a.Path, state)
		return err
	}
	if *dry {
		for _, a := range plan {
			if err = emit(a, "planned"); err != nil {
				return err
			}
		}
		return nil
	}
	workCtx, stop := context.WithCancel(rpcCtx)
	defer stop()
	jobs := make(chan files.Action)
	var wg sync.WaitGroup
	var firstErr error
	var errMu sync.Mutex
	fail := func(err error) {
		errMu.Lock()
		defer errMu.Unlock()
		if firstErr == nil {
			firstErr = err
		}
		stop()
	}
	perWorker := *bandwidth
	if perWorker > 0 {
		perWorker = max(1, perWorker/int64(*concurrency))
	}
	for range *concurrency {
		wg.Go(func() {
			for a := range jobs {
				if workCtx.Err() != nil {
					continue
				}
				last := time.Time{}
				progress := func(n int64) {
					if *noProgress || time.Since(last) < time.Second && n != a.Source.Size {
						return
					}
					last = time.Now()
					outputMu.Lock()
					defer outputMu.Unlock()
					fmt.Fprintf(c.Err, "transfer: %s %d/%d bytes\n", a.Path, n, a.Source.Size)
				}
				if err := copyTransfer(workCtx, source, destination, a.Path, a.Source, a.Destination, perWorker, progress); err != nil {
					fail(fmt.Errorf("%s: %w", a.Path, err))
					continue
				}
				if err := emit(a, "complete"); err != nil {
					fail(err)
				}
			}
		})
	}
	for _, a := range plan {
		if a.Kind == "copy" {
			select {
			case jobs <- a:
			case <-workCtx.Done():
			}
		} else if a.Kind == "skip" {
			if err = emit(a, "unchanged"); err != nil {
				fail(err)
			}
		}
	}
	close(jobs)
	wg.Wait()
	if firstErr != nil {
		return firstErr
	}
	if err = workCtx.Err(); err != nil {
		return err
	}
	if *remove {
		// Re-scan before deletion: a failed/changed source never authorizes removal.
		current, err := source.inventory(rpcCtx, false)
		if err != nil {
			return err
		}
		if len(current) != len(sourceTree) {
			return errors.New("source tree changed; deletion suppressed")
		}
		for p, e := range sourceTree {
			if current[p].Revision != e.Revision {
				return errors.New("source tree changed; deletion suppressed")
			}
		}
		for _, a := range plan {
			if a.Kind != "delete" {
				continue
			}
			if err = destination.remove(rpcCtx, a.Path, a.Destination.Revision); err != nil {
				return fmt.Errorf("delete %s: %w", a.Path, err)
			}
			if err = emit(a, "complete"); err != nil {
				return err
			}
		}
	}
	return nil
}

func openTransferPartial(dir *os.File, name string) (*os.File, error) {
	fd, err := unix.Openat(int(dir.Fd()), name, unix.O_RDWR|unix.O_CREAT|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), name)
	info, err := f.Stat()
	if err == nil && !info.Mode().IsRegular() {
		err = errors.New("partial is not a regular file")
	}
	if err == nil {
		err = fsx.TryLockFile(f)
	}
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	return f, nil
}

// A concurrently forked child can retain the open file description until exec,
// even with O_CLOEXEC. Release the lock explicitly before closing so an immediate
// resume does not contend with that inherited descriptor.
func closeTransferPartial(f *os.File) error {
	err := unix.Flock(int(f.Fd()), unix.LOCK_UN)
	return errors.Join(err, f.Close())
}

func removeTransferPartial(dir *os.File, name string) error {
	if err := unix.Unlinkat(int(dir.Fd()), name, 0); err != nil {
		return err
	}
	return dir.Sync()
}

// Keep flag import close to the ordered filter contract for go doc.
var _ flag.Value = transferRuleFlag{}
