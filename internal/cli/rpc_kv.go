package cli

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/peerstore"
)

const kvHelp = `Usage: dieter kv <get|list|put|delete|move|watch> [options]

Account-scoped portable JSON state replicated between daemons. Writes acknowledge
local durability, not a quorum. Revisions are local compare-and-set checks.
Use global --machine ID|NAME for verified TLS, WebRTC, or relay targeting.

  get      Read a key, its deterministic value and all causal siblings
  list     Read a bounded snapshot page including tombstones
  put      Write JSON with an observed revision (empty means create only)
  delete   Persist a causal tombstone
  move     Position one ordered key using stable neighboring keys
  watch    Stream bounded changes; apply reset before replacement snapshots
`

func (c *CLI) rpcKV(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, kvHelp)
		return nil
	}
	action := args[0]
	usages := map[string]string{
		"get":    "--namespace NS --key KEY [--account ID]\nRead the selected value and all causal siblings.",
		"list":   "[--namespace NS] [--prefix PREFIX] [--after KEY --epoch EPOCH --sequence N]\nRead up to 64 entries. Pass nextKey and cursor for subsequent pages.",
		"put":    "--namespace NS --key KEY --file FILE [--revision REV] [--operation ID]\nWrite JSON (maximum 32 KiB). Read all siblings before resolving conflicts.",
		"delete": "--namespace NS --key KEY --revision REV [--operation ID]\nRetain a tombstone; deleting does not remove causal history.",
		"move":   "--namespace NS --key KEY [--parent ID] [--after KEY] [--before KEY] [--revision REV] [--operation ID]\nWrite an atomic parent/rank position. Empty neighbors append to this list.",
		"watch":  "[--namespace NS] [--prefix PREFIX] [--epoch EPOCH --sequence N] [--count N]\nWatch until canceled or count frames. Reset replaces the cache; publish at caughtUp.",
	}
	detail, ok := usages[action]
	if !ok {
		return fmt.Errorf("unknown kv action %q", action)
	}
	usage := "Usage: dieter kv " + action + " " + detail + "\nMutations may pass --account ID --daemon ID to pin an uncertain retry.\nRetry identical input and --operation only on that same daemon.\n"
	if wantsHelp(args[1:]) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	set := flags("kv " + action)
	ns := set.String("namespace", "", "portable namespace")
	key := set.String("key", "", "key")
	account := set.String("account", "", "expected account")
	daemon := set.String("daemon", "", "accepting daemon ID")
	prefix := set.String("prefix", "", "key prefix")
	after := set.String("after", "", "continuation or left neighbor key")
	before := set.String("before", "", "right neighbor key")
	parent := set.String("parent", "", "ordered parent")
	epoch := set.String("epoch", "", "replica epoch")
	sequence := set.Uint64("sequence", 0, "applied sequence")
	revision := set.String("revision", "", "observed revision")
	operation := set.String("operation", "", "stable mutation ID")
	file := set.String("file", "", "JSON file")
	count := set.Int("count", 0, "watch frame limit (zero watches until canceled)")
	if _, err := parse(set, args[1:], usage, c.Out); err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New(usage)
	}
	if action != "list" && action != "watch" && (*ns == "" || *key == "") {
		return errors.New("--namespace and --key are required")
	}
	if action == "delete" && *revision == "" {
		return errors.New("delete requires --revision")
	}
	var raw []byte
	if action == "put" {
		f, err := os.Open(*file)
		if err != nil {
			return err
		}
		defer f.Close()
		raw, err = io.ReadAll(io.LimitReader(f, peerstore.MaxValueBytes+1))
		if err != nil {
			return err
		}
		if len(raw) > peerstore.MaxValueBytes {
			return peerstore.ErrCapacity
		}
	}
	ctx, cancel := c.commandContext()
	if action == "watch" {
		cancel()
		ctx, cancel = signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	}
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	ref := &dieterv1.KVRef{Namespace: *ns, Key: *key, Account: *account}
	cursor := &dieterv1.KVCursor{Epoch: *epoch, Sequence: *sequence}
	switch action {
	case "get":
		v, e := client.GetKV(rpcCtx, ref)
		if e != nil {
			return e
		}
		return protoJSONOut(c.Out, v)
	case "list":
		r := &dieterv1.KVListRequest{Namespace: *ns, Prefix: *prefix, AfterKey: *after, Account: *account}
		if *epoch != "" {
			r.Snapshot = cursor
		}
		v, e := client.ListKV(rpcCtx, r)
		if e != nil {
			return e
		}
		return protoJSONOut(c.Out, v)
	case "watch":
		stream, e := client.WatchKV(rpcCtx, &dieterv1.KVWatchRequest{Namespace: *ns, Prefix: *prefix, After: cursor, Account: *account})
		if e != nil {
			return e
		}
		for n := 0; *count == 0 || n < *count; n++ {
			v, e := stream.Recv()
			if e != nil {
				return streamEnd(e, ctx)
			}
			if e = protoJSONLine(c.Out, v); e != nil {
				return streamEnd(e, ctx)
			}
		}
		return nil
	}
	if *account == "" || *daemon == "" {
		info, e := client.ListKV(rpcCtx, &dieterv1.KVListRequest{Namespace: *ns, Account: *account})
		if e != nil {
			return e
		}
		ref.Account = info.Account
		if *daemon == "" {
			*daemon = info.DaemonId
		}
	}
	if *operation == "" {
		var id [16]byte
		if _, err = rand.Read(id[:]); err != nil {
			return err
		}
		*operation = hex.EncodeToString(id[:])
	}
	var v *dieterv1.KVEntry
	switch action {
	case "put":
		v, err = client.PutKV(rpcCtx, &dieterv1.KVPutRequest{Ref: ref, ValueJson: raw, ExpectedRevision: *revision, OperationId: *operation, DaemonId: *daemon})
	case "delete":
		v, err = client.DeleteKV(rpcCtx, &dieterv1.KVDeleteRequest{Ref: ref, ExpectedRevision: *revision, OperationId: *operation, DaemonId: *daemon})
	case "move":
		v, err = client.MoveKV(rpcCtx, &dieterv1.KVMoveRequest{Ref: ref, Parent: *parent, AfterKey: *after, BeforeKey: *before, ExpectedRevision: *revision, OperationId: *operation, DaemonId: *daemon})
	}
	if err != nil {
		return fmt.Errorf("KV operation %s on daemon %s account %s: %w", *operation, *daemon, ref.Account, err)
	}
	return protoJSONOut(c.Out, v)
}
