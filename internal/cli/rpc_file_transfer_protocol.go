package cli

import (
	"errors"
	"fmt"
	"io"
	"os"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func (c *CLI) rpcFileTransferProtocol(action string, args []string) error {
	usage := `Usage: dieter file stat (--project PROJECT|--card CARD) [--checkout ID] [--checksum] PATH
       dieter file scan (--project PROJECT|--card CARD) [--checkout ID] [--after NAME] [--revision REV] [--page-size N] PATH
       dieter file upload <begin|chunk|show|commit|abort> [OPTIONS]

stat and scan emit protobuf JSON. scan returns a bounded directory page; carry
its revision and next name into the following request. Restart on conflict.

Upload protocol commands (JSON output):
  begin (--project PROJECT|--card CARD) [--checkout ID] --operation ID
        --revision REV|missing --size BYTES --sha256 HASH --modified-nanos NS
        [--mode 420] PATH
  chunk --offset BYTES --file FILE UPLOAD_ID
  show UPLOAD_ID
  commit UPLOAD_ID
  abort UPLOAD_ID

Chunks are at most 1 MiB; offsets must be aligned except at the end of a file.
Replay uses identical input and operation ID. Commit is idempotent. Sessions
expire after 24 hours. Use cp/sync for automatic chunking, checksums and resume.
`
	if groupHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	sub := ""
	if action == "upload" {
		sub = args[0]
		args = args[1:]
		switch sub {
		case "begin", "chunk", "show", "commit", "abort":
		default:
			return errors.New("unknown upload action")
		}
	}
	set := flags("file " + action)
	project, card, checkout := addFileScopeFlags(set)
	checksum := set.Bool("checksum", false, "compute SHA-256")
	after := set.String("after", "", "directory continuation name")
	revision := set.String("revision", "", "observed revision or missing for create")
	pageSize := set.Int("page-size", 256, "entries per page, 1..512")
	operation := set.String("operation", "", "stable upload operation ID")
	size := set.Int64("size", 0, "expected file size")
	digest := set.String("sha256", "", "expected lowercase SHA-256")
	modified := set.Int64("modified-nanos", 0, "source modification time in Unix nanoseconds")
	mode := set.Uint("mode", 420, "permission bits as decimal (420 = 0644)")
	offset := set.Int64("offset", 0, "chunk byte offset")
	input := set.String("file", "", "local chunk payload path")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("one path or upload ID required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	var target *dieterv1.TransferPath
	if action != "upload" || sub == "begin" {
		projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
		if err != nil {
			return err
		}
		target = &dieterv1.TransferPath{ProjectId: projectID, CardId: cardID, CheckoutId: *checkout, Path: set.Arg(0), Checksum: *checksum}
	}
	switch action {
	case "stat":
		r, err := client.StatTransferFile(rpcCtx, target)
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, r)
	case "scan":
		if *pageSize < 1 || *pageSize > 512 {
			return errors.New("page size must be 1..512")
		}
		r, err := client.ListTransferFiles(rpcCtx, &dieterv1.ListTransferFilesRequest{Target: target, After: *after, Revision: *revision, PageSize: int32(*pageSize)})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, r)
	}
	var r *dieterv1.FileUpload
	switch sub {
	case "begin":
		if *mode > 0o777 {
			return errors.New("mode must contain only permission bits")
		}
		r, err = client.BeginFileUpload(rpcCtx, &dieterv1.BeginFileUploadRequest{Target: target, OperationId: *operation, ExpectedRevision: *revision, Size: *size, Sha256: *digest, ModifiedNanos: *modified, Mode: uint32(*mode)})
	case "chunk":
		f, e := os.Open(*input)
		if e != nil {
			return e
		}
		defer f.Close()
		b, e := io.ReadAll(io.LimitReader(f, files.ChunkSize+1))
		if e != nil {
			return e
		}
		if len(b) > files.ChunkSize {
			return errors.New("chunk exceeds 1 MiB")
		}
		r, err = client.WriteFileChunk(rpcCtx, &dieterv1.WriteFileChunkRequest{Id: set.Arg(0), Offset: *offset, Data: b, Sha256: files.Digest(b)})
	case "show":
		r, err = client.GetFileUpload(rpcCtx, &dieterv1.FileUploadRequest{Id: set.Arg(0)})
	case "commit":
		r, err = client.CommitFileUpload(rpcCtx, &dieterv1.FileUploadRequest{Id: set.Arg(0)})
	case "abort":
		r, err = client.AbortFileUpload(rpcCtx, &dieterv1.FileUploadRequest{Id: set.Arg(0)})
	}
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, r)
}
