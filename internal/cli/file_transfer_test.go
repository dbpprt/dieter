package cli

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type interruptedDownload struct {
	dieterclient.Client
	root      string
	interrupt bool
	offsets   []int64
}

func (c *interruptedDownload) StatTransferFile(ctx context.Context, r *dieterv1.TransferPath, _ ...grpc.CallOption) (*dieterv1.TransferEntry, error) {
	e, err := files.Stat(ctx, c.root, r.Path, r.Checksum)
	return &dieterv1.TransferEntry{Path: e.Path, Kind: e.Kind, Size: e.Size, ModifiedNanos: e.Modified, Revision: e.Revision, Sha256: e.SHA256, Mode: e.Mode}, err
}
func (c *interruptedDownload) ReadFileChunk(ctx context.Context, r *dieterv1.ReadFileChunkRequest, _ ...grpc.CallOption) (*dieterv1.FileChunk, error) {
	c.offsets = append(c.offsets, r.Offset)
	if c.interrupt && r.Offset >= files.ChunkSize {
		return nil, status.Error(codes.Canceled, "simulated disconnect")
	}
	b, err := files.Read(ctx, c.root, r.Target.Path, r.Revision, r.Offset, int(r.Length))
	return &dieterv1.FileChunk{Data: b, Sha256: files.Digest(b)}, err
}
func TestDownloadResumesWithoutPublishingPartial(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	root := t.TempDir()
	payload := bytes.Repeat([]byte{0, 19, 255}, files.ChunkSize)
	if err := os.WriteFile(filepath.Join(root, "source"), payload, 0o600); err != nil {
		t.Fatal(err)
	}
	client := &interruptedDownload{root: root, interrupt: true}
	source := transferEndpoint{remote: true, base: "source", client: client, scope: &dieterv1.TransferPath{}}
	dstPath := filepath.Join(t.TempDir(), "destination")
	if err := os.WriteFile(dstPath, []byte("old content"), 0o600); err != nil {
		t.Fatal(err)
	}
	destination, err := localTransferEndpoint(dstPath)
	if err != nil {
		t.Fatal(err)
	}
	s, err := source.stat(ctx, ".", false)
	if err != nil {
		t.Fatal(err)
	}
	d, err := destination.stat(ctx, ".", false)
	if err != nil {
		t.Fatal(err)
	}
	progress := func(int64) {}
	if err = copyTransfer(ctx, source, destination, ".", s, d, 0, progress); err == nil {
		t.Fatal("expected interrupted download")
	}
	actual, err := os.ReadFile(dstPath)
	if err != nil || string(actual) != "old content" {
		t.Fatal("published partial destination")
	}
	client.interrupt = false
	client.offsets = nil
	if err = copyTransfer(ctx, source, destination, ".", s, d, 0, progress); err != nil {
		t.Fatal(err)
	}
	if len(client.offsets) != 2 || client.offsets[0] != files.ChunkSize {
		t.Fatalf("did not resume: %v", client.offsets)
	}
	actual, err = os.ReadFile(dstPath)
	if err != nil || !bytes.Equal(actual, payload) {
		t.Fatalf("resumed content mismatch: %v", err)
	}
}
