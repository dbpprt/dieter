// Package filetransfer manages durable, bounded upload sessions on a daemon.
package filetransfer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
)

const MaxFileSize int64 = 64 << 30
const maxStaging int64 = 256 << 30
const maxSessions = 4096
const retention = 24 * time.Hour

type Manager struct{ Home string }
type Upload struct {
	ID          string      `json:"id"`
	Root        string      `json:"root"`
	Path        string      `json:"path"`
	Expected    string      `json:"expected"`
	Source      files.Entry `json:"source"`
	Offset      int64       `json:"offset"`
	State       string      `json:"state"`
	Expires     int64       `json:"expires"`
	Fingerprint string      `json:"fingerprint"`
}

func (m Manager) directory(id string) string { return filepath.Join(m.Home, "transfers", id) }
func (m Manager) save(u Upload) error {
	b, err := json.Marshal(u)
	if err != nil {
		return err
	}
	return fsx.WriteFile(filepath.Join(m.directory(u.ID), "session.json"), b, 0o600)
}
func (m Manager) read(id string) (Upload, error) {
	if !files.ValidDigest(id) {
		return Upload{}, fault.Invalidf("invalid transfer ID")
	}
	b, err := os.ReadFile(filepath.Join(m.directory(id), "session.json"))
	if errors.Is(err, os.ErrNotExist) {
		return Upload{}, fault.NotFoundf("upload not found or expired")
	}
	if err != nil {
		return Upload{}, err
	}
	var u Upload
	if err = json.Unmarshal(b, &u); err != nil {
		return u, err
	}
	return u, nil
}
func (m Manager) lock(ctx context.Context) (*fsx.Lock, error) { return fsx.LockHome(ctx, m.Home) }
func (m Manager) Begin(ctx context.Context, operation, root, p, expected string, source files.Entry) (Upload, error) {
	if operation == "" || len(operation) > 256 || (expected != files.Missing && !files.ValidDigest(expected)) || !files.ValidDigest(source.SHA256) || source.Size < 0 || source.Size > MaxFileSize || source.Mode&^0o777 != 0 {
		return Upload{}, fault.Invalidf("operation, revision, SHA-256, valid mode and size (0..64 GiB) required")
	}
	p, err := files.Clean(p)
	if err != nil {
		return Upload{}, err
	}
	if p == "." {
		return Upload{}, fault.Invalidf("file path required")
	}
	id := files.Digest([]byte(operation))
	u := Upload{ID: id, Root: root, Path: p, Expected: expected, Source: source, State: "uploading", Expires: time.Now().Add(retention).Unix()}
	identity, _ := json.Marshal([]any{root, p, expected, source})
	u.Fingerprint = files.Digest(identity)
	lock, err := m.lock(ctx)
	if err != nil {
		return u, err
	}
	defer lock.Close()
	if err = m.collect(); err != nil {
		return u, err
	}
	old, err := m.read(id)
	if err == nil {
		if old.Fingerprint != u.Fingerprint {
			return u, fault.New(fault.Conflict, "operation ID already used with different input")
		}
		return old, nil
	}
	if k, _ := fault.KindOf(err); k != fault.NotFound {
		return u, err
	}
	entries, err := os.ReadDir(filepath.Join(m.Home, "transfers"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return u, err
	}
	if len(entries) >= maxSessions {
		return u, fault.New(fault.ResourceExhausted, "4096 retained upload sessions reached; wait for expiry")
	}
	total := source.Size
	for _, e := range entries {
		other, e := m.read(e.Name())
		if e != nil {
			return u, e
		}
		if other.State == "uploading" || other.State == "committing" {
			total += other.Source.Size
		}
	}
	if total > maxStaging {
		return u, fault.New(fault.ResourceExhausted, "upload staging quota exceeded")
	}
	dest, err := files.Stat(ctx, root, p, false)
	if err != nil {
		return u, err
	}
	if dest.Revision != expected {
		return u, fault.New(fault.Conflict, "destination changed before upload")
	}
	return u, m.save(u)
}
func (m Manager) collect() error {
	entries, err := os.ReadDir(filepath.Join(m.Home, "transfers"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !files.ValidDigest(e.Name()) {
			return fault.New(fault.DataLoss, "invalid transfer staging directory")
		}
		u, err := m.read(e.Name())
		if kind, _ := fault.KindOf(err); kind == fault.NotFound {
			// Admission may have crashed after creating the staging directory but
			// before atomically publishing its first session record.
			if err = os.RemoveAll(m.directory(e.Name())); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		if u.Expires <= time.Now().Unix() {
			if err = os.RemoveAll(m.directory(u.ID)); err != nil {
				return err
			}
			continue
		}
		if u.State == "committed" || u.State == "aborted" {
			if err = m.removeChunks(u); err != nil {
				return err
			}
		}
	}
	return nil
}

func (m Manager) Get(ctx context.Context, id string) (Upload, error) {
	lock, err := m.lock(ctx)
	if err != nil {
		return Upload{}, err
	}
	defer lock.Close()
	u, err := m.read(id)
	if err == nil && u.Expires <= time.Now().Unix() {
		return u, fault.NotFoundf("upload expired")
	}
	return u, err
}
func (m Manager) Write(ctx context.Context, id string, offset int64, data []byte, digest string) (Upload, error) {
	if offset < 0 || offset%files.ChunkSize != 0 || len(data) == 0 || len(data) > files.ChunkSize || files.Digest(data) != digest {
		return Upload{}, fault.Invalidf("invalid chunk offset, size or checksum")
	}
	lock, err := m.lock(ctx)
	if err != nil {
		return Upload{}, err
	}
	defer lock.Close()
	u, err := m.read(id)
	if err != nil {
		return u, err
	}
	if u.Expires <= time.Now().Unix() || u.State != "uploading" {
		return u, fault.New(fault.FailedPrecondition, "upload is not writable")
	}
	if offset+int64(len(data)) > u.Source.Size || offset > u.Offset || len(data) != files.ChunkSize && offset+int64(len(data)) != u.Source.Size {
		return u, fault.Invalidf("chunk is outside the next upload range")
	}
	chunk := filepath.Join(m.directory(id), fmt.Sprintf("%016x.chunk", offset))
	if offset < u.Offset {
		old, e := os.ReadFile(chunk)
		if e != nil {
			return u, e
		}
		if files.Digest(old) != digest {
			return u, fault.New(fault.Conflict, "chunk replay differs")
		}
		return u, nil
	}
	if err = fsx.WriteFile(chunk, data, 0o600); err != nil {
		return u, err
	}
	u.Offset += int64(len(data))
	return u, m.save(u)
}
func (m Manager) Abort(ctx context.Context, id string) (Upload, error) {
	lock, err := m.lock(ctx)
	if err != nil {
		return Upload{}, err
	}
	defer lock.Close()
	u, err := m.read(id)
	if err != nil {
		return u, err
	}
	if u.State == "committed" {
		return u, fault.New(fault.FailedPrecondition, "upload already committed")
	}
	if u.State == "committing" {
		// A previous process may have published and lost its response. Resolve that
		// uncertainty through Commit before allowing an abort.
		dest, e := files.Stat(ctx, u.Root, u.Path, true)
		if e != nil {
			return u, e
		}
		if dest.SHA256 == u.Source.SHA256 && dest.Size == u.Source.Size {
			return u, fault.New(fault.FailedPrecondition, "destination may be committed; run upload commit to recover the receipt")
		}
	}
	u.State = "aborted"
	if err = m.save(u); err != nil {
		return u, err
	}
	return u, m.removeChunks(u)
}
func (m Manager) removeChunks(u Upload) error {
	entries, err := os.ReadDir(m.directory(u.ID))
	if err != nil {
		return err
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".chunk") {
			if err = os.Remove(filepath.Join(m.directory(u.ID), e.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}
func (m Manager) Commit(ctx context.Context, id string) (Upload, error) {
	lock, err := m.lock(ctx)
	if err != nil {
		return Upload{}, err
	}
	defer lock.Close()
	u, err := m.read(id)
	if err != nil {
		return u, err
	}
	if u.State == "committed" {
		return u, nil
	}
	if u.Expires <= time.Now().Unix() || u.State == "aborted" || u.Offset != u.Source.Size {
		return u, fault.New(fault.FailedPrecondition, "upload incomplete, aborted or expired")
	}
	if u.State == "committing" {
		dest, e := files.Stat(ctx, u.Root, u.Path, true)
		if e != nil {
			return u, e
		}
		if dest.SHA256 == u.Source.SHA256 && dest.Size == u.Source.Size && dest.Modified == u.Source.Modified && dest.Mode == u.Source.Mode {
			u.State = "committed"
			if err = m.save(u); err != nil {
				return u, err
			}
			return u, m.removeChunks(u)
		}
	}
	u.State = "committing"
	if err = m.save(u); err != nil {
		return u, err
	}
	reader := &chunkReader{directory: m.directory(u.ID), size: u.Source.Size}
	defer reader.Close()
	if err = files.Publish(ctx, u.Root, u.Path, u.Expected, u.Source, reader); err != nil {
		return u, err
	}
	u.State = "committed"
	if err = m.save(u); err != nil {
		return u, err
	}
	return u, m.removeChunks(u)
}

type chunkReader struct {
	directory    string
	size, offset int64
	file         *os.File
}

func (r *chunkReader) Read(b []byte) (int, error) {
	if r.offset == r.size {
		return 0, io.EOF
	}
	if r.file == nil {
		f, err := os.Open(filepath.Join(r.directory, fmt.Sprintf("%016x.chunk", r.offset)))
		if err != nil {
			return 0, err
		}
		info, e := f.Stat()
		if e != nil {
			_ = f.Close()
			return 0, e
		}
		if info.Size() != min(int64(files.ChunkSize), r.size-r.offset) {
			_ = f.Close()
			return 0, io.ErrUnexpectedEOF
		}
		r.file = f
	}
	n, err := r.file.Read(b)
	r.offset += int64(n)
	if errors.Is(err, io.EOF) {
		_ = r.file.Close()
		r.file = nil
		if r.offset%files.ChunkSize != 0 && r.offset != r.size {
			return n, io.ErrUnexpectedEOF
		}
		if n == 0 {
			return r.Read(b)
		}
		err = nil
	}
	return n, err
}
func (r *chunkReader) Close() error {
	if r.file != nil {
		return r.file.Close()
	}
	return nil
}
