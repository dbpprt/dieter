// Command folders measures what docs/proposals/synced-folders.md §4.3 asks
// before the defaults are trusted:
//
//	go run ./tools/spikes/folders walk [-entries 100000] [-dir DIR]
//	    M1: a stat-only walk (filetransfer.Scan) of a tree with that many
//	    entries: wall time and CPU of one walk.
//	go run ./tools/spikes/folders relay [-streams 0,2,4] [-calls 200]
//	    M2: p50/p95 latency of interactive calls over an isolated gateway's
//	    relay while N folder chunk downloads stream on the same command lane.
//
// Results go to docs/proposals/synced-folders-results.md.
package main

import (
	"context"
	"crypto/rand"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	files "github.com/dbpprt/dieter/internal/filetransfer"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	hostfolders "github.com/dbpprt/dieter/internal/host/folders"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: folders walk|relay [options]")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "walk":
		err = walk(os.Args[2:])
	case "relay":
		err = relay(os.Args[2:])
	default:
		err = fmt.Errorf("unknown measurement %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func cpu() time.Duration {
	var usage syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &usage)
	return time.Duration(usage.Utime.Nano() + usage.Stime.Nano())
}

func walk(args []string) error {
	set := flag.NewFlagSet("walk", flag.ExitOnError)
	entries := set.Int("entries", 100000, "entries in the tree (1 directory per 100 files)")
	dir := set.String("dir", "", "where to build the tree (default: a temporary directory)")
	_ = set.Parse(args)
	root := *dir
	if root == "" {
		var err error
		if root, err = os.MkdirTemp("", "folders-walk-*"); err != nil {
			return err
		}
		defer os.RemoveAll(root)
	}
	for i := 0; i < *entries; i++ {
		sub := filepath.Join(root, fmt.Sprintf("d%04d", i/100))
		if i%100 == 0 {
			if err := os.MkdirAll(sub, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.WriteFile(filepath.Join(sub, fmt.Sprintf("f%06d", i)), []byte("x"), 0o644); err != nil {
			return err
		}
	}
	for round := 1; round <= 3; round++ {
		startCPU, start := cpu(), time.Now()
		result, err := files.Scan(context.Background(), root, files.ScanOptions{Limit: *entries + 1})
		if err != nil {
			return err
		}
		wall, used := time.Since(start), cpu()-startCPU
		fmt.Printf("walk %d: %d entries in %v (CPU %v); at a 60 s interval that is %.2f%% of one core\n",
			round, len(result.Entries), wall.Round(time.Millisecond), used.Round(time.Millisecond), 100*used.Seconds()/60)
	}
	return nil
}

func relay(args []string) error {
	set := flag.NewFlagSet("relay", flag.ExitOnError)
	streamList := set.String("streams", "0,2,4", "concurrent chunk downloads per measurement")
	calls := set.Int("calls", 200, "interactive calls per measurement")
	_ = set.Parse(args)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	root, err := os.MkdirTemp("", "folders-relay-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	logger := slog.New(slog.DiscardHandler)
	g, err := topology.NewGateway(topology.GatewayOptions{Root: filepath.Join(root, "gateway")})
	if err != nil {
		return err
	}
	defer g.Close()
	identity, err := g.Enroll(ctx, filepath.Join(root, "daemon"), "relay", topology.Account)
	if err != nil {
		return err
	}
	data := store.New(identity.Root)
	engine := hostfolders.New(hostfolders.Options{Store: data, Log: logger, Name: "relay"})
	daemon, err := g.StartDaemon(ctx, topology.DaemonOptions{Identity: identity, Store: data, Logger: logger,
		API: api.Options{Runner: harness.NewSubprocessRunner(identity.Root, harness.Environment{}), Catalog: harness.StaticCatalog(true), Folders: engine}})
	if err != nil {
		return err
	}
	defer daemon.Close()
	go engine.Run(ctx)
	dir := filepath.Join(root, "folder")
	payload := make([]byte, 64<<20)
	_, _ = rand.Read(payload)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "big.bin"), payload, 0o644); err != nil {
		return err
	}
	name := "Spike"
	definition, err := engine.CreateFolder(hostfolders.DefinitionChange{Name: &name})
	if err != nil {
		return err
	}
	if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: dir}); err != nil {
		return err
	}
	if err := engine.WaitCycle(ctx, definition.ID, true); err != nil {
		return err
	}
	client, err := g.NewClient(ctx, daemon, "spike phone")
	if err != nil {
		return err
	}
	defer client.Close()
	conn, err := client.Dial(ctx, identity.ID, topology.Tunnel)
	if err != nil {
		return err
	}
	defer conn.Close()
	rpc := dieterclient.New(conn)
	stat, err := rpc.StatTransferFile(ctx, &dieterv1.TransferPath{FolderId: definition.ID, Path: "big.bin", Checksum: true})
	if err != nil {
		return err
	}
	for _, field := range strings.Split(*streamList, ",") {
		streams, _ := strconv.Atoi(strings.TrimSpace(field))
		streamCtx, stop := context.WithCancel(ctx)
		var wg sync.WaitGroup
		var moved int64
		var mu sync.Mutex
		for s := range streams {
			wg.Add(1)
			go func() {
				defer wg.Done()
				offset := int64(s) * (8 << 20)
				for streamCtx.Err() == nil {
					chunk, err := rpc.ReadFileChunk(streamCtx, &dieterv1.ReadFileChunkRequest{Target: &dieterv1.TransferPath{FolderId: definition.ID, Path: "big.bin"}, Revision: stat.GetSha256(), Offset: offset, Length: 1 << 20})
					if err != nil {
						return
					}
					mu.Lock()
					moved += int64(len(chunk.GetData()))
					mu.Unlock()
					offset = (offset + 1<<20) % int64(len(payload))
				}
			}()
		}
		time.Sleep(500 * time.Millisecond)
		latencies := make([]time.Duration, 0, *calls)
		start := time.Now()
		for range *calls {
			began := time.Now()
			if _, err := rpc.GetFolderStatus(ctx, &dieterv1.FolderRef{FolderId: definition.ID}); err != nil {
				stop()
				return err
			}
			latencies = append(latencies, time.Since(began))
		}
		elapsed := time.Since(start)
		stop()
		wg.Wait()
		slices.Sort(latencies)
		p := func(q float64) time.Duration {
			return latencies[int(q*float64(len(latencies)-1))].Round(10 * time.Microsecond)
		}
		fmt.Printf("streams %d: interactive p50 %v p95 %v; chunk throughput %.1f MiB/s\n", streams, p(0.5), p(0.95), float64(moved)/(1<<20)/elapsed.Seconds())
	}
	return nil
}
