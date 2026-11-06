// Package filetransfer contains bounded, rooted filesystem transfer primitives.
// It does not access Dieter's central storage or select a daemon.
package filetransfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"sort"
	"strings"
	"syscall"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"golang.org/x/sys/unix"
)

const ChunkSize = 1 << 20
const Missing = "missing"
const TemporaryPrefix = ".dieter-transfer-"

// Entry revisions describe a local observation, not a filesystem snapshot.
type Entry struct {
	Path     string `json:"path"`
	Kind     string `json:"kind"`
	Size     int64  `json:"size"`
	Modified int64  `json:"modifiedNanos"`
	Revision string `json:"revision"`
	SHA256   string `json:"sha256,omitempty"`
	Mode     uint32 `json:"mode"`
}

func Clean(p string) (string, error) {
	if strings.ContainsAny(p, "\\\x00") || strings.HasPrefix(p, "/") || len(p) > 4096 {
		return "", fault.Invalidf("invalid relative transfer path")
	}
	p = path.Clean(p)
	if p == ".." || strings.HasPrefix(p, "../") {
		return "", fault.Invalidf("transfer path escapes workspace")
	}
	for _, part := range strings.Split(p, "/") {
		if part == ".git" || strings.HasPrefix(part, TemporaryPrefix) {
			return "", fault.New(fault.PermissionDenied, "protected transfer path")
		}
	}
	return p, nil
}

// Parent walks with O_NOFOLLOW on every component. The returned directory
// descriptor pins the parent against rename and symlink substitution races.
func Parent(root, p string, create bool) (*os.File, string, error) {
	p, err := Clean(p)
	if err != nil {
		return nil, "", err
	}
	fd, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, "", err
	}
	dir := os.NewFile(uintptr(fd), root)
	parts := strings.Split(p, "/")
	for _, part := range parts[:len(parts)-1] {
		next, e := unix.Openat(int(dir.Fd()), part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if errors.Is(e, unix.ENOENT) && create {
			if e = unix.Mkdirat(int(dir.Fd()), part, 0o755); e == nil || errors.Is(e, unix.EEXIST) {
				if e = dir.Sync(); e != nil {
					_ = dir.Close()
					return nil, "", e
				}
				next, e = unix.Openat(int(dir.Fd()), part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
			}
		}
		_ = dir.Close()
		if e != nil {
			return nil, "", e
		}
		dir = os.NewFile(uintptr(next), part)
	}
	return dir, parts[len(parts)-1], nil
}

func Open(root, p string) (*os.File, error) {
	dir, name, err := Parent(root, p, false)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	fd, err := unix.Openat(int(dir.Fd()), name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), p), nil
}

func observed(p string, info os.FileInfo) Entry {
	kind := "unsupported"
	if info.IsDir() {
		kind = "directory"
	} else if info.Mode().IsRegular() {
		kind = "file"
	}
	st, _ := info.Sys().(*syscall.Stat_t)
	identity := ""
	if st != nil {
		identity = fmt.Sprintf("%d:%d:%d", st.Dev, st.Ino, changeTime(st))
	}
	revision := Digest([]byte(fmt.Sprintf("%s:%d:%d:%d", identity, info.Size(), info.ModTime().UnixNano(), info.Mode())))
	return Entry{Path: p, Kind: kind, Size: info.Size(), Modified: info.ModTime().UnixNano(), Revision: revision, Mode: uint32(info.Mode().Perm())}
}

func Stat(ctx context.Context, root, p string, checksum bool) (Entry, error) {
	p, err := Clean(p)
	if err != nil {
		return Entry{}, err
	}
	f, err := Open(root, p)
	if errors.Is(err, os.ErrNotExist) {
		return Entry{Path: p, Kind: Missing, Revision: Missing}, nil
	}
	if err != nil {
		return Entry{}, err
	}
	defer f.Close()
	return Describe(ctx, f, p, checksum)
}

func Describe(ctx context.Context, f *os.File, p string, checksum bool) (Entry, error) {
	info, err := f.Stat()
	if err != nil {
		return Entry{}, err
	}
	e := observed(p, info)
	if e.Kind == "unsupported" {
		return Entry{}, fault.Invalidf("unsupported file type: %s", p)
	}
	if checksum && e.Kind == "file" {
		h := sha256.New()
		if _, err = io.CopyBuffer(h, &contextReader{ctx, f}, make([]byte, ChunkSize)); err != nil {
			return Entry{}, err
		}
		e.SHA256 = hex.EncodeToString(h.Sum(nil))
		after, err := f.Stat()
		if err != nil {
			return Entry{}, err
		}
		if observed(p, after).Revision != e.Revision {
			return Entry{}, fault.New(fault.Conflict, "source changed while hashing")
		}
	}
	return e, nil
}

type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r *contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.r.Read(p)
}
func Digest(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func ValidDigest(s string) bool {
	b, e := hex.DecodeString(s)
	return e == nil && len(b) == sha256.Size && s == strings.ToLower(s)
}

// List scans in bounded batches and retains only the requested lexicographic
// page. A changed directory invalidates the continuation, never truncates it.
func List(ctx context.Context, root, p, after, revision string, limit int) ([]Entry, string, string, error) {
	if limit < 1 || limit > 512 {
		return nil, "", "", fault.Invalidf("page size must be 1..512")
	}
	f, err := Open(root, p)
	if err != nil {
		return nil, "", "", err
	}
	defer f.Close()
	before, err := f.Stat()
	if err != nil {
		return nil, "", "", err
	}
	rev := observed(p, before).Revision
	if !before.IsDir() {
		return nil, "", "", fault.Invalidf("not a directory: %s", p)
	}
	if revision != "" && revision != rev {
		return nil, "", "", fault.New(fault.Conflict, "directory changed; restart enumeration")
	}
	names := make([]string, 0, limit+1)
	for {
		if err = ctx.Err(); err != nil {
			return nil, "", "", err
		}
		batch, e := f.ReadDir(128)
		if e != nil && !errors.Is(e, io.EOF) {
			return nil, "", "", e
		}
		for _, item := range batch {
			n := item.Name()
			if n == ".git" || strings.HasPrefix(n, TemporaryPrefix) || n <= after {
				continue
			}
			i := sort.SearchStrings(names, n)
			if i > limit {
				continue
			}
			names = append(names, "")
			copy(names[i+1:], names[i:])
			names[i] = n
			if len(names) > limit+1 {
				names = names[:limit+1]
			}
		}
		if errors.Is(e, io.EOF) {
			break
		}
	}
	next := ""
	if len(names) > limit {
		names = names[:limit]
		next = names[len(names)-1]
	}
	entries := make([]Entry, 0, len(names))
	for _, n := range names {
		fd, e := unix.Openat(int(f.Fd()), n, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
		if errors.Is(e, unix.ELOOP) {
			// Enumerate the link without following it. The planner can then exclude
			// it; included unsupported entries still fail before any mutation.
			entries = append(entries, Entry{Path: path.Join(p, n), Kind: "unsupported"})
			continue
		}
		if e != nil {
			return nil, "", "", fmt.Errorf("cannot enumerate %s: %w", path.Join(p, n), e)
		}
		child := os.NewFile(uintptr(fd), n)
		info, e := child.Stat()
		_ = child.Close()
		if e != nil {
			return nil, "", "", e
		}
		entries = append(entries, observed(path.Join(p, n), info))
	}
	end, err := f.Stat()
	if err != nil {
		return nil, "", "", err
	}
	if observed(p, end).Revision != rev {
		return nil, "", "", fault.New(fault.Conflict, "directory changed during enumeration")
	}
	return entries, next, rev, nil
}

func Read(ctx context.Context, root, p, revision string, offset int64, length int) ([]byte, error) {
	if revision == "" || offset < 0 || length < 1 || length > ChunkSize {
		return nil, fault.Invalidf("revision and bounded range required")
	}
	f, err := Open(root, p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	before, err := Describe(ctx, f, p, false)
	if err != nil {
		return nil, err
	}
	if before.Kind != "file" || before.Revision != revision {
		return nil, fault.New(fault.Conflict, "source revision changed")
	}
	if offset > before.Size {
		return nil, fault.New(fault.OutOfRange, "offset exceeds file size")
	}
	b := make([]byte, min(int64(length), before.Size-offset))
	_, err = f.ReadAt(b, offset)
	if err != nil {
		return nil, err
	}
	after, err := Describe(ctx, f, p, false)
	if err != nil {
		return nil, err
	}
	if after.Revision != revision {
		return nil, fault.New(fault.Conflict, "source changed during read")
	}
	return b, nil
}

// Remove never recursively removes a directory; sync deletes observed files only.
func Remove(ctx context.Context, root, p, revision string) error {
	if revision == "" || revision == Missing {
		return fault.Invalidf("observed file revision required")
	}
	dir, name, err := Parent(root, p, false)
	if err != nil {
		return err
	}
	defer dir.Close()
	// Stat through the pinned parent, never an untrusted absolute path.
	fd, err := unix.Openat(int(dir.Fd()), name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fd), p)
	e, err := Describe(ctx, f, p, false)
	_ = f.Close()
	if err != nil {
		return err
	}
	if e.Kind != "file" || e.Revision != revision {
		return fault.New(fault.Conflict, "destination changed before delete")
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if err = unix.Unlinkat(int(dir.Fd()), name, 0); err != nil {
		return err
	}
	return dir.Sync()
}
