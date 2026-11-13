package filetransfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"golang.org/x/sys/unix"
	"golang.org/x/text/unicode/norm"
)

// Entry kinds a scan reports besides file and directory. They are skipped,
// never synced, and never followed.
const (
	KindSymlink = "symlink"
	KindSpecial = "special"
)

// fileMode maps a raw mode exactly as package os does, so an observation from
// fstatat has the same revision as one from (*os.File).Stat.
func fileMode(raw uint32) fs.FileMode {
	mode := fs.FileMode(raw & 0o777)
	switch raw & unix.S_IFMT {
	case unix.S_IFBLK:
		mode |= fs.ModeDevice
	case unix.S_IFCHR:
		mode |= fs.ModeDevice | fs.ModeCharDevice
	case unix.S_IFDIR:
		mode |= fs.ModeDir
	case unix.S_IFIFO:
		mode |= fs.ModeNamedPipe
	case unix.S_IFLNK:
		mode |= fs.ModeSymlink
	case unix.S_IFSOCK:
		mode |= fs.ModeSocket
	}
	if raw&unix.S_ISGID != 0 {
		mode |= fs.ModeSetgid
	}
	if raw&unix.S_ISUID != 0 {
		mode |= fs.ModeSetuid
	}
	if raw&unix.S_ISVTX != 0 {
		mode |= fs.ModeSticky
	}
	return mode
}

// observation is observed() for a raw stat taken without following links.
func observation(p string, st *unix.Stat_t) Entry {
	mode := fileMode(uint32(st.Mode))
	kind := KindSpecial
	switch {
	case mode.IsDir():
		kind = "directory"
	case mode.IsRegular():
		kind = "file"
	case mode&fs.ModeSymlink != 0:
		kind = KindSymlink
	}
	modified := st.Mtim.Sec*1e9 + st.Mtim.Nsec
	identity := fmt.Sprintf("%d:%d:%d", st.Dev, st.Ino, st.Ctim.Sec*1e9+st.Ctim.Nsec)
	revision := Digest([]byte(fmt.Sprintf("%s:%d:%d:%d", identity, st.Size, modified, mode)))
	return Entry{Path: p, Kind: kind, Size: st.Size, Modified: modified, Revision: revision, Mode: uint32(mode.Perm())}
}

// Skipped is a path a scan found but does not sync.
type Skipped struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

// ScanOptions bounds and filters a scan.
type ScanOptions struct {
	// Limit bounds the entries; exceeding it fails with ResourceExhausted.
	Limit int
	// Exclude prunes a path (and, for a directory, everything below it).
	Exclude func(p string) bool
}

// ScanResult is one walk of a tree.
type ScanResult struct {
	Entries []Entry
	Skipped []Skipped
}

// Scan walks root recursively without following symbolic links. Every
// directory is opened relative to its pinned parent with O_NOFOLLOW, so a
// substituted symlink is never traversed. Protected names (.git, transfer
// partials) are never reported. Other file systems mounted inside the tree,
// symlinks and special files are reported as skipped. Paths are NFC; a name
// that is not NFC is skipped where the file system distinguishes forms.
func Scan(ctx context.Context, root string, options ScanOptions) (ScanResult, error) {
	fd, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return ScanResult{}, err
	}
	dir := os.NewFile(uintptr(fd), root)
	defer dir.Close()
	var rootStat unix.Stat_t
	if err = unix.Fstat(fd, &rootStat); err != nil {
		return ScanResult{}, err
	}
	result := ScanResult{}
	limit := options.Limit
	if limit <= 0 {
		limit = MaxEntries
	}
	var walk func(dir *os.File, rel string) error
	walk = func(dir *os.File, rel string) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		names, err := dir.Readdirnames(-1)
		if err != nil {
			return err
		}
		for _, name := range names {
			if name == ".git" || strings.HasPrefix(name, TemporaryPrefix) {
				continue
			}
			p := name
			if rel != "" {
				p = rel + "/" + name
			}
			canonical := norm.NFC.String(p)
			if canonical != p && !normalizationInsensitive {
				result.Skipped = append(result.Skipped, Skipped{Path: p, Reason: "name is not NFC"})
				continue
			}
			if options.Exclude != nil && options.Exclude(canonical) {
				continue
			}
			var st unix.Stat_t
			if err := unix.Fstatat(int(dir.Fd()), name, &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
				if errors.Is(err, unix.ENOENT) {
					continue
				}
				return fmt.Errorf("cannot stat %s: %w", p, err)
			}
			entry := observation(canonical, &st)
			switch entry.Kind {
			case KindSymlink:
				result.Skipped = append(result.Skipped, Skipped{Path: canonical, Reason: "symbolic link"})
				continue
			case KindSpecial:
				result.Skipped = append(result.Skipped, Skipped{Path: canonical, Reason: "special file"})
				continue
			}
			if entry.Kind == "directory" && uint64(st.Dev) != uint64(rootStat.Dev) {
				result.Skipped = append(result.Skipped, Skipped{Path: canonical, Reason: "another file system is mounted here"})
				continue
			}
			if len(result.Entries) >= limit {
				return fault.New(fault.ResourceExhausted, fmt.Sprintf("more than %d entries; exclude some or choose a smaller folder", limit))
			}
			result.Entries = append(result.Entries, entry)
			if entry.Kind != "directory" {
				continue
			}
			child, err := unix.Openat(int(dir.Fd()), name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
			if errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR) {
				continue
			}
			if err != nil {
				return fmt.Errorf("cannot open %s: %w", p, err)
			}
			childDir := os.NewFile(uintptr(child), name)
			err = walk(childDir, p)
			_ = childDir.Close()
			if err != nil {
				return err
			}
		}
		return nil
	}
	return result, walk(dir, "")
}

// RootIdentity is the device and inode of root, so a replaced or unmounted
// location is never mistaken for a tree whose files were deleted.
func RootIdentity(root string) (uint64, uint64, error) {
	var st unix.Stat_t
	if err := unix.Stat(root, &st); err != nil {
		return 0, 0, err
	}
	if st.Mode&unix.S_IFMT != unix.S_IFDIR {
		return 0, 0, fault.Invalidf("not a directory: %s", root)
	}
	return uint64(st.Dev), st.Ino, nil
}

// Mkdir creates directory p (and missing parents) under root. An existing
// directory is fine; an existing file is a conflict.
func Mkdir(root, p string) error {
	dir, name, err := Parent(root, p, true)
	if err != nil {
		return err
	}
	defer dir.Close()
	if err = unix.Mkdirat(int(dir.Fd()), name, 0o755); err == nil {
		return dir.Sync()
	}
	if !errors.Is(err, unix.EEXIST) {
		return err
	}
	var st unix.Stat_t
	if err = unix.Fstatat(int(dir.Fd()), name, &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if st.Mode&unix.S_IFMT != unix.S_IFDIR {
		return fault.New(fault.Conflict, "a file is in the way of directory "+p)
	}
	return nil
}

// RemoveEmptyDir removes directory p if it is empty. A missing directory is
// fine; a non-empty one is a conflict.
func RemoveEmptyDir(root, p string) error {
	dir, name, err := Parent(root, p, false)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer dir.Close()
	err = unix.Unlinkat(int(dir.Fd()), name, unix.AT_REMOVEDIR)
	switch {
	case err == nil:
		return dir.Sync()
	case errors.Is(err, unix.ENOENT):
		return nil
	case errors.Is(err, unix.ENOTEMPTY), errors.Is(err, unix.EEXIST):
		return fault.New(fault.Conflict, "directory is not empty: "+p)
	case errors.Is(err, unix.ENOTDIR):
		return fault.New(fault.Conflict, "not a directory: "+p)
	}
	return err
}

// OpenRevision opens file p only while it still has the observed revision.
// Callers verify again with Unchanged after reading.
func OpenRevision(ctx context.Context, root, p, revision string) (*os.File, Entry, error) {
	f, err := Open(root, p)
	if err != nil {
		return nil, Entry{}, err
	}
	entry, err := Describe(ctx, f, p, false)
	if err == nil && (entry.Kind != "file" || entry.Revision != revision) {
		err = fault.New(fault.Conflict, "source revision changed")
	}
	if err != nil {
		_ = f.Close()
		return nil, entry, err
	}
	return f, entry, nil
}

// Unchanged reports a conflict when f no longer has revision.
func Unchanged(ctx context.Context, f *os.File, p, revision string) error {
	entry, err := Describe(ctx, f, p, false)
	if err != nil {
		return err
	}
	if entry.Revision != revision {
		return fault.New(fault.Conflict, "source changed during read")
	}
	return nil
}

// Blocks hashes every ChunkSize block of file p at revision.
func Blocks(ctx context.Context, root, p, revision string) ([]string, string, error) {
	f, _, err := OpenRevision(ctx, root, p, revision)
	if err != nil {
		return nil, "", err
	}
	defer f.Close()
	whole := sha256.New()
	buffer := make([]byte, ChunkSize)
	var blocks []string
	for {
		n, err := io.ReadFull(&contextReader{ctx, f}, buffer)
		if n > 0 {
			sum := sha256.Sum256(buffer[:n])
			blocks = append(blocks, hex.EncodeToString(sum[:]))
			whole.Write(buffer[:n])
		}
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			break
		}
		if err != nil {
			return nil, "", err
		}
	}
	if err = Unchanged(ctx, f, p, revision); err != nil {
		return nil, "", err
	}
	return blocks, hex.EncodeToString(whole.Sum(nil)), nil
}

// Rename moves file p at revision to the missing path to, under the same
// root. It never replaces an existing destination: the link is create-only.
func Rename(ctx context.Context, root, p, revision, to string) error {
	if _, err := Clean(to); err != nil {
		return err
	}
	src, name, err := Parent(root, p, false)
	if err != nil {
		return err
	}
	defer src.Close()
	dst, toName, err := Parent(root, to, true)
	if err != nil {
		return err
	}
	defer dst.Close()
	fd, err := unix.Openat(int(src.Fd()), name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fd), p)
	entry, err := Describe(ctx, f, p, false)
	_ = f.Close()
	if err != nil {
		return err
	}
	if entry.Kind != "file" || entry.Revision != revision {
		return fault.New(fault.Conflict, "source changed before rename")
	}
	if err = unix.Linkat(int(src.Fd()), name, int(dst.Fd()), toName, 0); err != nil {
		if errors.Is(err, unix.EEXIST) {
			return fault.New(fault.Conflict, "destination exists: "+to)
		}
		return err
	}
	if err = unix.Unlinkat(int(src.Fd()), name, 0); err != nil {
		return err
	}
	return errors.Join(dst.Sync(), src.Sync())
}

// MoveOut moves file p at revision out of root into directory into, named
// name: a rename on the same file system, otherwise a verified copy followed
// by removal. copied reports the second case.
func MoveOut(ctx context.Context, root, p, revision, into, name string) (copied bool, err error) {
	src, base, err := Parent(root, p, false)
	if err != nil {
		return false, err
	}
	defer src.Close()
	fd, err := unix.Openat(int(src.Fd()), base, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return false, err
	}
	f := os.NewFile(uintptr(fd), p)
	defer f.Close()
	entry, err := Describe(ctx, f, p, false)
	if err != nil {
		return false, err
	}
	if entry.Kind != "file" || entry.Revision != revision {
		return false, fault.New(fault.Conflict, "file changed before it could be moved")
	}
	if err = os.MkdirAll(into, 0o700); err != nil {
		return false, err
	}
	dfd, err := unix.Open(into, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return false, err
	}
	dst := os.NewFile(uintptr(dfd), into)
	defer dst.Close()
	err = unix.Renameat(int(src.Fd()), base, int(dst.Fd()), name)
	if err == nil {
		return false, errors.Join(dst.Sync(), src.Sync())
	}
	if !errors.Is(err, unix.EXDEV) {
		return false, err
	}
	out, err := os.OpenFile(path.Join(into, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return true, err
	}
	_, err = io.CopyBuffer(out, &contextReader{ctx, f}, make([]byte, ChunkSize))
	err = errors.Join(err, out.Sync(), out.Close())
	if err == nil {
		err = Unchanged(ctx, f, p, revision)
	}
	if err != nil {
		_ = os.Remove(path.Join(into, name))
		return true, err
	}
	if err = unix.Unlinkat(int(src.Fd()), base, 0); err != nil {
		return true, err
	}
	return true, src.Sync()
}

// Preserve keeps a copy of file p at revision in directory into, named name,
// without removing it: a hard link on the same file system (the inode keeps
// the old content when p is later replaced by rename), otherwise a verified
// copy. A replaced file can then be restored from the trash. A link changes
// the file's ctime and so its observed revision; Preserve returns the
// revision p has afterwards, for the replacement's compare-and-swap.
func Preserve(ctx context.Context, root, p, revision, into, name string) (string, error) {
	src, base, err := Parent(root, p, false)
	if err != nil {
		return "", err
	}
	defer src.Close()
	fd, err := unix.Openat(int(src.Fd()), base, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	f := os.NewFile(uintptr(fd), p)
	defer f.Close()
	entry, err := Describe(ctx, f, p, false)
	if err != nil {
		return "", err
	}
	if entry.Kind != "file" || entry.Revision != revision {
		return "", fault.New(fault.Conflict, "file changed before it could be preserved")
	}
	before, err := f.Stat()
	if err != nil {
		return "", err
	}
	if err = os.MkdirAll(into, 0o700); err != nil {
		return "", err
	}
	dfd, err := unix.Open(into, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	dst := os.NewFile(uintptr(dfd), into)
	defer dst.Close()
	err = unix.Linkat(int(src.Fd()), base, int(dst.Fd()), name, 0)
	if err == nil {
		if err = dst.Sync(); err != nil {
			return "", err
		}
		after, err := f.Stat()
		if err != nil {
			return "", err
		}
		// Only the link count and ctime may differ: same size and mtime.
		if after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) || after.Mode() != before.Mode() {
			_ = unix.Unlinkat(int(dst.Fd()), name, 0)
			return "", fault.New(fault.Conflict, "file changed while it was preserved")
		}
		return observed(p, after).Revision, nil
	}
	if !errors.Is(err, unix.EXDEV) && !errors.Is(err, unix.EPERM) && !errors.Is(err, unix.ENOTSUP) {
		return "", err
	}
	out, err := os.OpenFile(path.Join(into, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	_, err = io.CopyBuffer(out, &contextReader{ctx, f}, make([]byte, ChunkSize))
	err = errors.Join(err, out.Sync(), out.Close())
	if err == nil {
		err = Unchanged(ctx, f, p, revision)
	}
	if err != nil {
		_ = os.Remove(path.Join(into, name))
		return "", err
	}
	return revision, nil
}
