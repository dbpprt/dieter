package cli

import (
	"errors"
	"fmt"
	"io"
	"os"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/peerstore"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/emptypb"
)

const peerHelp = `Usage: dieter peer <status|show|changes|list|put|delete|merge> [options]

Leaderless account settings replicated by enrolled daemons, including while clients
are closed. Local commits work offline after first account discovery. Concurrent
values and deletions are preserved; read all versions and put with their revision
to resolve. Shared project and board operations use these records directly.
Use global --machine ID|NAME to address another daemon over authenticated routes.

  show     Read one shared record and all conflicting values
  changes  Read an incremental change page using a durable sequence cursor
  status   Account, actor, record/conflict counts and last successful peer route
  list     One bounded snapshot page, including conflicts and tombstones
  put      Resolve a typed shared field from a JSON file
  delete   Write a causal deletion using the current record revision
  merge    Import a bounded protobuf JSON MergePeerRecordsRequest (recovery/sync)
`

func (c *CLI) rpcPeer(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, peerHelp)
		return nil
	}
	action := args[0]
	usage := "Usage: dieter peer " + action + "\n"
	switch action {
	case "show":
		usage += "  --kind KIND --id ID\nRead one shared record.\n"
	case "changes":
		usage += "  [--account HASH] [--epoch EPOCH] [--sequence N]\nRead a bounded incremental change page.\n"
	case "status":
		usage += "Show enrolled account, conflicts, and last successful peer synchronization.\n"
	case "list":
		usage += "  [--account HASH] [--after KEY --snapshot REVISION]\nReturn up to eight records. Pass nextKey and snapshotRevision for the next page.\n"
	case "put":
		usage += "  --kind KIND --id ENTITY.FIELD --file FILE [--revision HASH]\nFILE contains the JSON value for the typed shared field. See docs/peer-store.md for the explicit field allowlist.\nOmit revision only for a new record. Resolve conflicts by supplying the current revision.\n"
	case "delete":
		usage += "  --kind KIND --id ID --revision HASH\nPersist a tombstone; concurrent unseen writes remain visible as conflicts.\n"
	case "merge":
		usage += "  --file FILE\nImport at most 64 records (2 MiB total) using protobuf JSON with account and records fields.\nThis joins causal versions, never replaces the store or runs an agent.\n"
	default:
		return fmt.Errorf("unknown peer action %q; run dieter peer --help", action)
	}
	if wantsHelp(args[1:]) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	set := flags("peer " + action)
	var kind, id, file, revision, account, after, snapshot *string
	var sequence *uint64
	switch action {
	case "show":
		kind = set.String("kind", "", "record kind")
		id = set.String("id", "", "record ID")
	case "changes":
		account = set.String("account", "", "account hash")
		snapshot = set.String("epoch", "", "replica epoch")
		sequence = set.Uint64("sequence", 0, "last fully applied sequence")
	case "put", "delete":
		kind = set.String("kind", "", "record kind")
		id = set.String("id", "", "logical record ID")
		revision = set.String("revision", "", "observed record revision")
		if action == "put" {
			file = set.String("file", "", "settings JSON file")
		}
	case "merge":
		file = set.String("file", "", "protobuf JSON request file")
	case "list":
		account = set.String("account", "", "account hash")
		after = set.String("after", "", "continuation key")
		snapshot = set.String("snapshot", "", "snapshot revision")
	}
	if _, err := parse(set, args[1:], usage, c.Out); err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New(usage)
	}
	var raw []byte
	if file != nil {
		if *file == "" {
			return errors.New("--file is required")
		}
		f, err := os.Open(*file)
		if err != nil {
			return err
		}
		defer f.Close()
		limit := int64(peerstore.MaxValueBytes)
		if action == "merge" {
			limit = 8 << 20
		}
		raw, err = io.ReadAll(io.LimitReader(f, limit+1))
		if err != nil {
			return err
		}
		if int64(len(raw)) > limit {
			return peerstore.ErrCapacity
		}
	}
	if kind != nil && (*kind == "" || *id == "") {
		return errors.New("--kind and --id are required")
	}
	if action == "delete" && *revision == "" {
		return errors.New("delete requires --revision")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	switch action {
	case "show":
		v, e := client.GetPeerRecord(rpcCtx, &dieterv1.PeerRecordRef{Kind: *kind, Id: *id})
		if e != nil {
			return e
		}
		return protoJSONOut(c.Out, v)
	case "changes":
		v, e := client.GetPeerChanges(rpcCtx, &dieterv1.PeerChangesRequest{Account: *account, Epoch: *snapshot, AfterSequence: *sequence})
		if e != nil {
			return e
		}
		return protoJSONOut(c.Out, v)

	case "status":
		v, e := client.GetPeerStoreStatus(rpcCtx, &emptypb.Empty{})
		if e != nil {
			return e
		}
		return protoJSONOut(c.Out, v)
	case "list":
		v, e := client.ListPeerRecords(rpcCtx, &dieterv1.PeerSnapshotRequest{Account: *account, AfterKey: *after, SnapshotRevision: *snapshot})
		if e != nil {
			return e
		}
		return protoJSONOut(c.Out, v)
	case "put", "delete":
		v, e := client.PutPeerRecord(rpcCtx, &dieterv1.PutPeerRecordRequest{Kind: *kind, Id: *id, ValueJson: raw, Deleted: action == "delete", ExpectedRevision: *revision})
		if e != nil {
			return e
		}
		return protoJSONOut(c.Out, v)
	case "merge":
		var r dieterv1.MergePeerRecordsRequest
		if err = protojson.Unmarshal(raw, &r); err != nil {
			return err
		}
		v, e := client.MergePeerRecords(rpcCtx, &r)
		if e != nil {
			return e
		}
		return protoJSONOut(c.Out, v)
	}
	return nil
}
