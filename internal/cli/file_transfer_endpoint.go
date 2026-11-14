package cli

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sync"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type transferEndpoint struct {
	root, base string
	client     dieterclient.Client
	scope      *dieterv1.TransferPath
	remote     bool
}

func (e transferEndpoint) target(p string, checksum bool) *dieterv1.TransferPath {
	return &dieterv1.TransferPath{ProjectId: e.scope.ProjectId, CheckoutId: e.scope.CheckoutId, CardId: e.scope.CardId, FolderId: e.scope.FolderId, Path: path.Join(e.base, p), Checksum: checksum}
}
func entryFromProto(e *dieterv1.TransferEntry) files.Entry {
	return files.Entry{Path: e.Path, Kind: e.Kind, Size: e.Size, Modified: e.ModifiedNanos, Revision: e.Revision, SHA256: e.Sha256, Mode: e.Mode}
}
func (e transferEndpoint) stat(ctx context.Context, p string, checksum bool) (files.Entry, error) {
	if !e.remote {
		return files.Stat(ctx, e.root, path.Join(e.base, p), checksum)
	}
	r, err := retryTransfer(ctx, func() (*dieterv1.TransferEntry, error) { return e.client.StatTransferFile(ctx, e.target(p, checksum)) })
	if err != nil {
		return files.Entry{}, err
	}
	return entryFromProto(r), nil
}
func (e transferEndpoint) list(ctx context.Context, p, after, revision string) ([]files.Entry, string, string, error) {
	if !e.remote {
		return files.List(ctx, e.root, path.Join(e.base, p), after, revision, 256)
	}
	r, err := retryTransfer(ctx, func() (*dieterv1.TransferPage, error) {
		return e.client.ListTransferFiles(ctx, &dieterv1.ListTransferFilesRequest{Target: e.target(p, false), After: after, Revision: revision, PageSize: 256})
	})
	if err != nil {
		return nil, "", "", err
	}
	entries := make([]files.Entry, 0, len(r.Entries))
	for _, v := range r.Entries {
		entries = append(entries, entryFromProto(v))
	}
	return entries, r.Next, r.Revision, nil
}
func (e transferEndpoint) read(ctx context.Context, p string, entry files.Entry, offset int64) ([]byte, error) {
	if !e.remote {
		return files.Read(ctx, e.root, path.Join(e.base, p), entry.Revision, offset, files.ChunkSize)
	}
	r, err := retryTransfer(ctx, func() (*dieterv1.FileChunk, error) {
		return e.client.ReadFileChunk(ctx, &dieterv1.ReadFileChunkRequest{Target: e.target(p, false), Revision: entry.Revision, Offset: offset, Length: files.ChunkSize})
	})
	if err != nil {
		return nil, err
	}
	if files.Digest(r.Data) != r.Sha256 || int64(len(r.Data)) != min(int64(files.ChunkSize), entry.Size-offset) {
		return nil, errors.New("download chunk integrity failure")
	}
	return r.Data, nil
}
func (e transferEndpoint) remove(ctx context.Context, p, revision string) error {
	if !e.remote {
		return files.Remove(ctx, e.root, path.Join(e.base, p), revision)
	}
	// Deletion is revision checked, but has no replay receipt: do not retry it.
	_, err := e.client.DeleteTransferFile(ctx, &dieterv1.DeleteTransferFileRequest{Target: e.target(p, false), Revision: revision})
	return err
}
func (e transferEndpoint) inventory(ctx context.Context, checksum bool) (map[string]files.Entry, error) {
	result := map[string]files.Entry{}
	queue := []string{"."}
	root, err := e.stat(ctx, ".", false)
	if err != nil {
		return nil, err
	}
	if root.Kind == files.Missing {
		return result, nil
	}
	if root.Kind != "directory" {
		return nil, errors.New("sync/recursive copy requires directory endpoints")
	}
	for len(queue) > 0 {
		dir := queue[0]
		queue = queue[1:]
		after, revision := "", ""
		for {
			entries, next, rev, err := e.list(ctx, dir, after, revision)
			if err != nil {
				return nil, err
			}
			revision = rev
			for _, v := range entries {
				rel := path.Join(dir, path.Base(v.Path))
				v.Path = rel
				if _, exists := result[rel]; exists {
					return nil, errors.New("duplicate enumeration entry")
				}
				if len(result) >= files.MaxEntries {
					return nil, fmt.Errorf("tree exceeds %d entries; use a narrower source", files.MaxEntries)
				}
				if checksum && v.Kind == "file" {
					checked, err := e.stat(ctx, rel, true)
					if err != nil {
						return nil, err
					}
					if checked.Revision != v.Revision {
						return nil, fmt.Errorf("source changed during scan: %s", rel)
					}
					v.SHA256 = checked.SHA256
				}
				result[rel] = v
				if v.Kind == "directory" {
					queue = append(queue, rel)
				}
			}
			if next == "" {
				break
			}
			if next <= after {
				return nil, errors.New("non-progressing directory cursor")
			}
			after = next
		}
	}
	return result, nil
}

// Only reads and operations with explicit durable replay semantics use this.
func retryTransfer[T any](ctx context.Context, fn func() (T, error)) (T, error) {
	var value T
	var err error
	for attempt := 0; attempt < 4; attempt++ {
		value, err = fn()
		if err == nil {
			return value, nil
		}
		code := status.Code(err)
		if code != codes.Unavailable && code != codes.DeadlineExceeded {
			return value, err
		}
		if attempt == 3 {
			break
		}
		timer := time.NewTimer(time.Duration(1<<attempt) * 200 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return value, ctx.Err()
		case <-timer.C:
		}
	}
	return value, err
}

// transferWindow is how many chunks of one file are in flight. Each chunk is
// one request and response, so a window hides the round trip per chunk and
// keeps the route's byte stream full; files run concurrently on top.
const transferWindow = 8

func copyTransfer(ctx context.Context, source, destination transferEndpoint, p string, s, d files.Entry, limit int64, progress func(int64)) error {
	current, err := source.stat(ctx, p, true)
	if err != nil {
		return err
	}
	if current.Revision != s.Revision {
		return fmt.Errorf("source changed before copy: %s", p)
	}
	s = current
	if !destination.remote {
		// Payload-only partials are kept beside the destination for restart/resume.
		// The hash binds them to this source content.
		return downloadTransfer(ctx, source, destination, p, s, d, limit, progress)
	}
	request := &dieterv1.BeginFileUploadRequest{Target: destination.target(p, false), ExpectedRevision: d.Revision, Size: s.Size, Sha256: s.SHA256, ModifiedNanos: s.Modified, Mode: s.Mode}
	identity, _ := json.Marshal(request)
	request.OperationId = files.Digest(identity)
	u, err := retryTransfer(ctx, func() (*dieterv1.FileUpload, error) { return destination.client.BeginFileUpload(ctx, request) })
	if err != nil {
		return err
	}
	if u.State == "committed" {
		return nil
	}
	if u.State == "aborted" {
		return fmt.Errorf("upload %s was aborted; change the source or use file upload begin with a new operation ID", u.Id)
	}
	id := u.Id
	progress(u.Offset)
	// The daemon acknowledges the contiguous prefix; chunks complete in order,
	// so every acknowledgement is at least the end of the chunk delivered.
	err = pipelineChunks(ctx, u.Offset, s.Size, min(transferWindow, max(1, int(u.Window))), limit, func(ctx context.Context, offset int64) (int64, error) {
		b, err := source.read(ctx, p, s, offset)
		if err != nil {
			return 0, err
		}
		write := &dieterv1.WriteFileChunkRequest{Id: id, Offset: offset, Data: b, Sha256: files.Digest(b)}
		r, err := retryTransfer(ctx, func() (*dieterv1.FileUpload, error) { return destination.client.WriteFileChunk(ctx, write) })
		if err != nil {
			return 0, fmt.Errorf("upload %s can be resumed by rerunning this command: %w", id, err)
		}
		return r.Offset, nil
	}, func(offset, acknowledged int64) error {
		progress(max(acknowledged, min(offset+files.ChunkSize, s.Size)))
		return nil
	})
	if err != nil {
		return err
	}
	// Commit is idempotent, including recovery after a lost rename response.
	_, err = retryTransfer(ctx, func() (*dieterv1.FileUpload, error) {
		return destination.client.CommitFileUpload(ctx, &dieterv1.FileUploadRequest{Id: id})
	})
	return err
}

// pipelineChunks runs fetch for every chunk offset in [offset, size) with up
// to window calls in flight and hands the results to deliver strictly in
// offset order. A positive limit paces chunk starts to limit bytes per second.
// The first error cancels the remaining calls; deliver is never called after,
// and no call outlives the return.
func pipelineChunks[T any](ctx context.Context, offset, size int64, window int, limit int64, fetch func(context.Context, int64) (T, error), deliver func(int64, T) error) error {
	ctx, cancel := context.WithCancel(ctx)
	var running sync.WaitGroup
	defer running.Wait()
	defer cancel()
	type result struct {
		value T
		err   error
	}
	type call struct {
		offset int64
		done   chan result
	}
	calls := make(chan call, window)
	slots := make(chan struct{}, window)
	running.Go(func() {
		defer close(calls)
		next := time.Now()
		for at := offset; at < size; at += files.ChunkSize {
			select {
			case slots <- struct{}{}:
			case <-ctx.Done():
				return
			}
			if limit > 0 {
				if wait := time.Until(next); wait > 0 {
					timer := time.NewTimer(wait)
					select {
					case <-timer.C:
					case <-ctx.Done():
						timer.Stop()
						return
					}
				}
				if now := time.Now(); next.Before(now) {
					next = now
				}
				n := min(int64(files.ChunkSize), size-at)
				next = next.Add(time.Duration(float64(n) / float64(limit) * float64(time.Second)))
			}
			c := call{offset: at, done: make(chan result, 1)}
			running.Go(func() {
				v, err := fetch(ctx, c.offset)
				c.done <- result{v, err}
			})
			calls <- c
		}
	})
	for c := range calls {
		var r result
		select {
		case r = <-c.done:
		case <-ctx.Done():
			return ctx.Err()
		}
		if r.err != nil {
			return r.err
		}
		if err := deliver(c.offset, r.value); err != nil {
			return err
		}
		<-slots
	}
	return ctx.Err()
}

func localTransferEndpoint(p string) (transferEndpoint, error) {
	absolute, err := filepath.Abs(p)
	if err != nil {
		return transferEndpoint{}, err
	}
	root, base := filepath.Dir(absolute), filepath.Base(absolute)
	for {
		canonical, e := filepath.EvalSymlinks(root)
		if e == nil {
			return transferEndpoint{root: canonical, base: filepath.ToSlash(base)}, nil
		}
		if !errors.Is(e, os.ErrNotExist) || root == filepath.Dir(root) {
			return transferEndpoint{}, e
		}
		base = filepath.Join(filepath.Base(root), base)
		root = filepath.Dir(root)
	}
}

// Keep the partial file descriptor open throughout; never follow a replacement
// symlink when resuming or publishing. The destination parent is pinned too.
// Chunks are written in order, so the partial is always a verified prefix of
// the source; it is fsynced once, when it is published in place.
func downloadTransfer(ctx context.Context, source, destination transferEndpoint, p string, s, d files.Entry, limit int64, progress func(int64)) (resultErr error) {
	dir, name, err := files.Parent(destination.root, path.Join(destination.base, p), true)
	if err != nil {
		return err
	}
	defer dir.Close()
	temp := files.TemporaryPrefix + files.Digest([]byte(name+"\x00"+s.SHA256))
	f, err := openTransferPartial(dir, temp)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, closeTransferPartial(f)) }()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	offset := info.Size()
	if offset > s.Size || offset%files.ChunkSize != 0 && offset != s.Size {
		offset = 0
		if err = f.Truncate(0); err != nil {
			return err
		}
	}
	// Hash the retained prefix once; new chunks extend the digest in order.
	digest := sha256.New()
	if _, err = io.CopyBuffer(digest, io.NewSectionReader(f, 0, offset), make([]byte, files.ChunkSize)); err != nil {
		return err
	}
	progress(offset)
	err = pipelineChunks(ctx, offset, s.Size, transferWindow, limit, func(ctx context.Context, offset int64) ([]byte, error) {
		b, err := source.read(ctx, p, s, offset)
		if err == nil && len(b) == 0 {
			err = io.ErrUnexpectedEOF
		}
		return b, err
	}, func(offset int64, b []byte) error {
		if _, err := f.WriteAt(b, offset); err != nil {
			return err
		}
		digest.Write(b)
		progress(offset + int64(len(b)))
		return nil
	})
	if err != nil {
		return err
	}
	if hex.EncodeToString(digest.Sum(nil)) != s.SHA256 {
		// A partial damaged outside this process cannot be resumed: restart it.
		return errors.Join(fault.New(fault.DataLoss, "download does not match the source SHA-256; rerun to restart it"), f.Truncate(0))
	}
	if err = files.PublishVerified(ctx, dir, f, temp, name, path.Join(destination.base, p), d.Revision, s); err != nil {
		// Publishing applied the source mode; keep the partial writable to resume.
		return errors.Join(fmt.Errorf("download partial retained; rerun to resume: %w", err), f.Chmod(0o600))
	}
	if d.Revision != files.Missing {
		// Publishing renamed the partial over the destination.
		return nil
	}
	return removeTransferPartial(dir, temp)
}

// Check ancestors even when the destination does not exist yet. This catches
// a local CLI syncing a checkout into its own child through the local daemon.
func transferOverlap(ctx context.Context, source, destination transferEndpoint, src, dst files.Entry) error {
	ancestors := func(e transferEndpoint, revision string) error {
		if revision == files.Missing {
			return nil
		}
		for p := e.base; ; p = path.Dir(p) {
			probe := e
			probe.base = p
			entry, err := probe.stat(ctx, ".", false)
			if err != nil {
				return err
			}
			if entry.Kind != "missing" && entry.Revision == revision {
				return errors.New("source and destination trees overlap")
			}
			if p == "." || p == "/" {
				break
			}
		}
		return nil
	}
	if err := ancestors(destination, src.Revision); err != nil {
		return err
	}
	return ancestors(source, dst.Revision)
}
