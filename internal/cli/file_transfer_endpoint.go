package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
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
	return &dieterv1.TransferPath{ProjectId: e.scope.ProjectId, CheckoutId: e.scope.CheckoutId, CardId: e.scope.CardId, Path: path.Join(e.base, p), Checksum: checksum}
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
		// The hash binds them to this source content; final publication rehashes all bytes.
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
	progress(u.Offset)
	for offset := u.Offset; offset < s.Size; {
		started := time.Now()
		b, err := source.read(ctx, p, s, offset)
		if err != nil {
			return err
		}
		if len(b) == 0 {
			return io.ErrUnexpectedEOF
		}
		write := &dieterv1.WriteFileChunkRequest{Id: u.Id, Offset: offset, Data: b, Sha256: files.Digest(b)}
		u, err = retryTransfer(ctx, func() (*dieterv1.FileUpload, error) { return destination.client.WriteFileChunk(ctx, write) })
		if err != nil {
			return fmt.Errorf("upload %s can be resumed by rerunning this command: %w", write.Id, err)
		}
		offset = u.Offset
		progress(offset)
		if err = paceTransfer(ctx, started, len(b), limit); err != nil {
			return err
		}
	}
	// Commit is idempotent, including recovery after a lost rename response.
	_, err = retryTransfer(ctx, func() (*dieterv1.FileUpload, error) {
		return destination.client.CommitFileUpload(ctx, &dieterv1.FileUploadRequest{Id: u.Id})
	})
	return err
}
func paceTransfer(ctx context.Context, start time.Time, n int, limit int64) error {
	if limit <= 0 {
		return nil
	}
	delay := time.Duration(float64(n)/float64(limit)*float64(time.Second)) - time.Since(start)
	if delay <= 0 {
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
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
	if _, err = f.Seek(offset, io.SeekStart); err != nil {
		return err
	}
	progress(offset)
	for offset < s.Size {
		started := time.Now()
		b, err := source.read(ctx, p, s, offset)
		if err != nil {
			return err
		}
		if len(b) == 0 {
			return io.ErrUnexpectedEOF
		}
		if _, err = f.Write(b); err != nil {
			return err
		}
		if err = f.Sync(); err != nil {
			return err
		}
		offset += int64(len(b))
		progress(offset)
		if err = paceTransfer(ctx, started, len(b), limit); err != nil {
			return err
		}
	}
	if _, err = f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	if err = files.Publish(ctx, destination.root, path.Join(destination.base, p), d.Revision, s, f); err != nil {
		return fmt.Errorf("download partial retained; remove %s to restart if corrupted: %w", filepath.Join(destination.root, filepath.FromSlash(path.Dir(path.Join(destination.base, p))), temp), err)
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
