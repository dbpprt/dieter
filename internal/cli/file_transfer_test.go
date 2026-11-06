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
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestDownloadPartialReleasesLockWithInheritedDescriptor(t *testing.T) {
	t.Parallel()
	dir, err := os.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer dir.Close()
	f, err := openTransferPartial(dir, "partial")
	if err != nil {
		t.Fatal(err)
	}
	// Dup retains the same open file description as a child between fork and
	// exec. Closing only the parent's descriptor would leave its flock held.
	inherited, err := unix.Dup(int(f.Fd()))
	if err != nil {
		_ = closeTransferPartial(f)
		t.Fatal(err)
	}
	defer func() { _ = unix.Close(inherited) }()
	if err := closeTransferPartial(f); err != nil {
		t.Fatal(err)
	}
	resumed, err := openTransferPartial(dir, "partial")
	if err != nil {
		t.Fatalf("resume while the child still holds its inherited descriptor: %v", err)
	}
	if err := closeTransferPartial(resumed); err != nil {
		t.Fatal(err)
	}
}

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
