//go:build linux

package linuxfs

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"dieter.spike/workspaces/core"
	"golang.org/x/sys/unix"
)

// Overlay xattr names on userxattr (unprivileged) mounts.
const (
	xattrOpaque   = "user.overlay.opaque"
	xattrWhiteout = "user.overlay.whiteout"
	xattrRedirect = "user.overlay.redirect"
	xattrMetacopy = "user.overlay.metacopy"
)

// node is one walked entry.
type node struct {
	rel  string // normalized relative path
	full string
	st   unix.Stat_t
}

// ReadUpper reads the upper directory. Character devices 0/0 (and zero-size
// files carrying user.overlay.whiteout) are whiteouts; directories with
// user.overlay.opaque=y are opaque. Paths at or below the root .git are only
// counted.
func (o Overlay) ReadUpper() (map[string]UpperEntry, UpperStats, error) {
	start := time.Now()
	var st UpperStats
	var nodes []node
	err := walk(o.Upper, func(n node) bool {
		if isGitPath(n.rel) {
			st.GitInternal++
			return true
		}
		nodes = append(nodes, n)
		return true
	})
	if err != nil {
		return nil, st, err
	}
	type result struct {
		u                  UpperEntry
		redirect, metacopy bool
	}
	res := make([]result, len(nodes))
	err = parallel(len(nodes), func(buf []byte, i int) error {
		n := &nodes[i]
		if n.st.Mode&unix.S_IFMT == unix.S_IFCHR && n.st.Rdev == 0 {
			res[i].u = UpperEntry{Path: n.rel, Deleted: true}
			return nil
		}
		e, x, err := readEntry(n.full, &n.st, buf)
		if err != nil {
			return err
		}
		r := result{u: UpperEntry{Path: n.rel, Entry: e}}
		_, r.redirect = x[xattrRedirect]
		_, r.metacopy = x[xattrMetacopy]
		switch {
		case e.Type == core.Dir && string(x[xattrOpaque]) == "y":
			r.u.Opaque = true
		case e.Type == core.File && e.Size == 0 && x[xattrWhiteout] != nil:
			r.u = UpperEntry{Path: n.rel, Deleted: true}
		}
		res[i] = r
		return nil
	})
	if err != nil {
		return nil, st, err
	}
	out := make(map[string]UpperEntry, len(res))
	for _, r := range res {
		out[r.u.Path] = r.u
		if r.redirect {
			st.Redirects++
		}
		if r.metacopy {
			st.Metacopy++
		}
		switch {
		case r.u.Deleted:
			st.Whiteouts++
		case r.u.Entry.Type == core.Dir:
			st.Dirs++
			if r.u.Opaque {
				st.Opaque++
			}
		case r.u.Entry.Type == core.File:
			st.Files++
			st.Bytes += r.u.Entry.Size
		case r.u.Entry.Type == core.Symlink:
			st.Symlinks++
		default:
			st.Others++
		}
	}
	st.Entries = len(out)
	st.Elapsed = time.Since(start)
	return out, st, nil
}

// Changes is the cumulative change set of the session against the lower
// tree. Copy-ups equal to their lower entry are counted, not reported.
// Whiteouts delete the path and every lower path below it; opaque
// directories delete every lower child missing from the upper. The root
// .git subtree is excluded (counted in Upper.GitInternal).
func (o Overlay) Changes(lowerTree core.Tree) (core.ChangeSet, CopyUpStats, error) {
	start := time.Now()
	upper, ust, err := o.ReadUpper()
	if err != nil {
		return nil, CopyUpStats{Upper: ust}, err
	}
	cs, st := diffUpper(lowerTree, upper)
	st.Upper = ust
	st.Elapsed = time.Since(start)
	return cs, st, nil
}

// ScanTree scans root fully, skipping the root .git, with the same entry
// conventions as ReadUpper.
func ScanTree(root string) (core.Tree, error) {
	var nodes []node
	err := walk(root, func(n node) bool {
		if n.rel == ".git" {
			return false
		}
		nodes = append(nodes, n)
		return true
	})
	if err != nil {
		return nil, err
	}
	entries := make([]core.Entry, len(nodes))
	err = parallel(len(nodes), func(buf []byte, i int) error {
		e, _, err := readEntry(nodes[i].full, &nodes[i].st, buf)
		entries[i] = e
		return err
	})
	if err != nil {
		return nil, err
	}
	out := make(core.Tree, len(nodes))
	for i, n := range nodes {
		out[n.rel] = entries[i]
	}
	return out, nil
}

func isGitPath(p string) bool { return p == ".git" || strings.HasPrefix(p, ".git/") }

// walk visits every entry below root in pre-order; visit returns whether to
// descend into a directory. Directories the owner cannot read are opened
// up for the duration of their walk and restored afterwards. Entries that
// vanish mid-walk are skipped.
func walk(root string, visit func(n node) bool) error {
	return walkDir(root, "", visit)
}

func walkDir(dir, rel string, visit func(n node) bool) error {
	names, err := readNames(dir)
	if errors.Is(err, fs.ErrPermission) {
		var st unix.Stat_t
		if unix.Lstat(dir, &st) == nil && unix.Chmod(dir, st.Mode&0o7777|0o700) == nil {
			defer unix.Chmod(dir, st.Mode&0o7777)
			names, err = readNames(dir)
		}
	}
	if err != nil {
		return err
	}
	for _, name := range names {
		n := node{full: dir + "/" + name, rel: name}
		if rel != "" {
			n.rel = rel + "/" + name
		}
		if err := unix.Lstat(n.full, &n.st); err != nil {
			if err == unix.ENOENT {
				continue
			}
			return &fs.PathError{Op: "lstat", Path: n.full, Err: err}
		}
		n.rel = core.NormPath(n.rel)
		if !visit(n) || n.st.Mode&unix.S_IFMT != unix.S_IFDIR {
			continue
		}
		if err := walkDir(n.full, n.rel, visit); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
	}
	return nil
}

func readNames(dir string) ([]string, error) {
	f, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return f.Readdirnames(-1)
}

// readEntry builds the entry of one path and returns its raw xattrs. Files
// and directories the owner cannot read (user.* xattrs and content both
// need read permission) get a temporary chmod u+r.
func readEntry(full string, st *unix.Stat_t, buf []byte) (core.Entry, map[string][]byte, error) {
	if st.Mode&unix.S_IFMT != unix.S_IFLNK && st.Mode&0o400 == 0 {
		perm := st.Mode & 0o7777
		if unix.Chmod(full, perm|0o400) == nil {
			defer unix.Chmod(full, perm)
		}
	}
	x, err := readXattrs(full)
	if err != nil {
		return core.Entry{}, nil, err
	}
	e := core.Entry{Mode: st.Mode & 0o7777, Xattrs: xattrHash(x)}
	switch st.Mode & unix.S_IFMT {
	case unix.S_IFREG:
		e.Type, e.Size = core.File, st.Size
		if e.Hash, err = hashFile(full, buf); err != nil {
			return e, x, err
		}
	case unix.S_IFDIR:
		e.Type = core.Dir
	case unix.S_IFLNK:
		e.Type, e.Mode = core.Symlink, 0
		if e.Target, err = os.Readlink(full); err != nil {
			return e, x, err
		}
		e.Size = int64(len(e.Target))
	default:
		e.Type = core.Other
	}
	return e, x, nil
}

// hashFile returns the sha256 of a regular file.
func hashFile(path string, buf []byte) (string, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return "", &fs.PathError{Op: "open", Path: path, Err: err}
	}
	defer unix.Close(fd)
	h := sha256.New()
	for {
		n, err := unix.Read(fd, buf)
		if n > 0 {
			h.Write(buf[:n])
		}
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return "", &fs.PathError{Op: "read", Path: path, Err: err}
		}
		if n == 0 {
			return hex.EncodeToString(h.Sum(nil)), nil
		}
	}
}

// readXattrs returns every xattr of path (not following symlinks).
func readXattrs(path string) (map[string][]byte, error) {
	var small [512]byte
	list := small[:]
	for {
		n, err := unix.Llistxattr(path, list)
		if err == nil {
			list = list[:n]
			break
		}
		switch err {
		case unix.EINTR:
		case unix.ERANGE:
			n, err := unix.Llistxattr(path, nil)
			if err != nil {
				return nil, &fs.PathError{Op: "llistxattr", Path: path, Err: err}
			}
			list = make([]byte, n+64)
		case unix.ENOTSUP, unix.ENOENT:
			return nil, nil
		default:
			return nil, &fs.PathError{Op: "llistxattr", Path: path, Err: err}
		}
	}
	if len(list) == 0 {
		return nil, nil
	}
	out := map[string][]byte{}
	for _, name := range strings.Split(string(list), "\x00") {
		if name == "" {
			continue
		}
		v, err := getXattr(path, name)
		if err == unix.ENODATA {
			continue
		}
		if err != nil {
			return nil, &fs.PathError{Op: "lgetxattr " + name, Path: path, Err: err}
		}
		out[name] = v
	}
	return out, nil
}

func getXattr(path, name string) ([]byte, error) {
	buf := make([]byte, 256)
	for {
		n, err := unix.Lgetxattr(path, name, buf)
		switch err {
		case nil:
			return buf[:n], nil
		case unix.EINTR:
		case unix.ERANGE:
			n, err := unix.Lgetxattr(path, name, nil)
			if err != nil {
				return nil, err
			}
			buf = make([]byte, n+64)
		default:
			return nil, err
		}
	}
}

// excludedXattr reports names the change model ignores: overlayfs's own
// bookkeeping and the kernel/LSM namespaces.
func excludedXattr(name string) bool {
	return strings.HasPrefix(name, "user.overlay.") || strings.HasPrefix(name, "security.") ||
		strings.HasPrefix(name, "trusted.")
}

// xattrHash is the sha256 of the sorted "name=value\0" pairs of the
// non-excluded xattrs, "" when none.
func xattrHash(x map[string][]byte) string {
	names := make([]string, 0, len(x))
	for n := range x {
		if !excludedXattr(n) {
			names = append(names, n)
		}
	}
	if len(names) == 0 {
		return ""
	}
	sort.Strings(names)
	h := sha256.New()
	for _, n := range names {
		h.Write([]byte(n))
		h.Write([]byte{'='})
		h.Write(x[n])
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

// parallel runs fn for 0..n-1 on a bounded worker pool, each worker with
// its own 128 KiB buffer, and returns the first error.
func parallel(n int, fn func(buf []byte, i int) error) error {
	workers := min(runtime.GOMAXPROCS(0), 16)
	if n < 256 {
		workers = 1
	}
	var next atomic.Int64
	var once sync.Once
	var first error
	var failed atomic.Bool
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 128<<10)
			for !failed.Load() {
				i := int(next.Add(1) - 1)
				if i >= n {
					return
				}
				if err := fn(buf, i); err != nil {
					once.Do(func() { first = err })
					failed.Store(true)
					return
				}
			}
		}()
	}
	wg.Wait()
	return first
}
