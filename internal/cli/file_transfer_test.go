package cli

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

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
	mu        sync.Mutex
	offsets   []int64
}

func (c *interruptedDownload) StatTransferFile(ctx context.Context, r *dieterv1.TransferPath, _ ...grpc.CallOption) (*dieterv1.TransferEntry, error) {
	e, err := files.Stat(ctx, c.root, r.Path, r.Checksum)
	return &dieterv1.TransferEntry{Path: e.Path, Kind: e.Kind, Size: e.Size, ModifiedNanos: e.Modified, Revision: e.Revision, Sha256: e.SHA256, Mode: e.Mode}, err
}
func (c *interruptedDownload) ReadFileChunk(ctx context.Context, r *dieterv1.ReadFileChunkRequest, _ ...grpc.CallOption) (*dieterv1.FileChunk, error) {
	c.mu.Lock()
	c.offsets = append(c.offsets, r.Offset)
	c.mu.Unlock()
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
	// Chunks are requested concurrently; the resume skips the verified prefix.
	slices.Sort(client.offsets)
	if !slices.Equal(client.offsets, []int64{files.ChunkSize, 2 * files.ChunkSize}) {
		t.Fatalf("did not resume: %v", client.offsets)
	}
	actual, err = os.ReadFile(dstPath)
	if err != nil || !bytes.Equal(actual, payload) {
		t.Fatalf("resumed content mismatch: %v", err)
	}
}

func TestPipelineChunksDeliversInOrderWithinTheWindow(t *testing.T) {
	t.Parallel()
	const size = 20*files.ChunkSize + 5
	var mu sync.Mutex
	inFlight, peak := 0, 0
	fetch := func(ctx context.Context, offset int64) (int64, error) {
		mu.Lock()
		inFlight++
		peak = max(peak, inFlight)
		mu.Unlock()
		// Later chunks finish first, so delivery must reorder them.
		time.Sleep(time.Duration(20-offset/files.ChunkSize) * time.Millisecond)
		mu.Lock()
		inFlight--
		mu.Unlock()
		if offset == 15*files.ChunkSize && ctx.Value(failKey{}) != nil {
			return 0, errors.New("chunk failed")
		}
		return offset, nil
	}
	var delivered []int64
	deliver := func(offset, value int64) error {
		if offset != value {
			t.Errorf("chunk %d delivered value %d", offset, value)
		}
		delivered = append(delivered, offset)
		return nil
	}
	if err := pipelineChunks(t.Context(), files.ChunkSize, size, 4, 0, fetch, deliver); err != nil {
		t.Fatal(err)
	}
	if len(delivered) != 20 || !slices.IsSorted(delivered) || delivered[0] != files.ChunkSize {
		t.Fatalf("delivered %v", delivered)
	}
	if peak > 4 || peak < 2 {
		t.Fatalf("peak in flight %d, want 2..4", peak)
	}
	// The first failure stops delivery at the failed chunk.
	delivered = nil
	ctx := context.WithValue(t.Context(), failKey{}, true)
	if err := pipelineChunks(ctx, 0, size, 4, 0, fetch, deliver); err == nil || err.Error() != "chunk failed" {
		t.Fatalf("error %v", err)
	}
	if len(delivered) != 15 {
		t.Fatalf("delivered %d chunks before the failure, want 15", len(delivered))
	}
}

type failKey struct{}

func TestDownloadRestartsAPartialThatNoLongerMatches(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	root := t.TempDir()
	payload := bytes.Repeat([]byte{4, 2, 9}, files.ChunkSize)
	if err := os.WriteFile(filepath.Join(root, "source"), payload, 0o600); err != nil {
		t.Fatal(err)
	}
	client := &interruptedDownload{root: root}
	source := transferEndpoint{remote: true, base: "source", client: client, scope: &dieterv1.TransferPath{}}
	dstDir := t.TempDir()
	destination, err := localTransferEndpoint(filepath.Join(dstDir, "destination"))
	if err != nil {
		t.Fatal(err)
	}
	s, err := source.stat(ctx, ".", false)
	if err != nil {
		t.Fatal(err)
	}
	// A retained partial whose prefix was damaged outside the process.
	partial := filepath.Join(dstDir, files.TemporaryPrefix+files.Digest([]byte("destination\x00"+files.Digest(payload))))
	if err = os.WriteFile(partial, bytes.Repeat([]byte{1}, files.ChunkSize), 0o600); err != nil {
		t.Fatal(err)
	}
	d := files.Entry{Kind: files.Missing, Revision: files.Missing}
	if err = copyTransfer(ctx, source, destination, ".", s, d, 0, func(int64) {}); err == nil {
		t.Fatal("published a download that does not match the source")
	}
	if _, err = os.Stat(filepath.Join(dstDir, "destination")); !os.IsNotExist(err) {
		t.Fatal("mismatching download was published")
	}
	if err = copyTransfer(ctx, source, destination, ".", s, d, 0, func(int64) {}); err != nil {
		t.Fatal(err)
	}
	actual, err := os.ReadFile(filepath.Join(dstDir, "destination"))
	if err != nil || !bytes.Equal(actual, payload) {
		t.Fatalf("restarted download mismatch: %v", err)
	}
	if _, err = os.Stat(partial); !os.IsNotExist(err) {
		t.Fatal("partial retained after publishing")
	}
}

func TestDownloadConflictKeepsAReadOnlySourcePartialResumable(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	root := t.TempDir()
	payload := bytes.Repeat([]byte{8, 3}, files.ChunkSize)
	if err := os.WriteFile(filepath.Join(root, "source"), payload, 0o444); err != nil {
		t.Fatal(err)
	}
	client := &interruptedDownload{root: root}
	source := transferEndpoint{remote: true, base: "source", client: client, scope: &dieterv1.TransferPath{}}
	dstPath := filepath.Join(t.TempDir(), "destination")
	if err := os.WriteFile(dstPath, []byte("old"), 0o600); err != nil {
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
	stale, err := destination.stat(ctx, ".", false)
	if err != nil {
		t.Fatal(err)
	}
	// Another writer replaces the destination after it was observed.
	if err = os.WriteFile(dstPath, []byte("concurrent writer"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err = copyTransfer(ctx, source, destination, ".", s, stale, 0, func(int64) {}); err == nil {
		t.Fatal("replaced a destination that changed after it was observed")
	}
	if actual, _ := os.ReadFile(dstPath); string(actual) != "concurrent writer" {
		t.Fatal("concurrent destination overwritten")
	}
	current, err := destination.stat(ctx, ".", false)
	if err != nil {
		t.Fatal(err)
	}
	client.offsets = nil
	if err = copyTransfer(ctx, source, destination, ".", s, current, 0, func(int64) {}); err != nil {
		t.Fatalf("resume after the conflict: %v", err)
	}
	if len(client.offsets) != 0 {
		t.Fatalf("complete partial was downloaded again: %v", client.offsets)
	}
	info, err := os.Stat(dstPath)
	if err != nil || info.Mode().Perm() != 0o444 {
		t.Fatalf("published mode %v: %v", info.Mode(), err)
	}
	if actual, _ := os.ReadFile(dstPath); !bytes.Equal(actual, payload) {
		t.Fatal("resumed content mismatch")
	}
}
