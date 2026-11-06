//go:build darwin || linux

package tree

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"

	"dieter.spike/workspaces/core"
	"golang.org/x/sys/unix"
)

// statInfo is the part of lstat(2) the oracle and the manifest use.
type statInfo struct {
	typ   core.EntryType
	mode  uint32 // permission bits (0o7777); 0 for symlinks
	size  int64  // bytes for files and symlinks; 0 for dirs and others
	mtime int64  // ns
	ctime int64  // ns
	ino   uint64
	dev   uint64
}

func statOf(st *unix.Stat_t) statInfo {
	s := statInfo{
		mode:  uint32(st.Mode) & 0o7777,
		mtime: st.Mtim.Nano(),
		ctime: st.Ctim.Nano(),
		ino:   uint64(st.Ino),
		dev:   uint64(st.Dev),
	}
	switch uint32(st.Mode) & unix.S_IFMT {
	case unix.S_IFREG:
		s.typ, s.size = core.File, st.Size
	case unix.S_IFDIR:
		s.typ = core.Dir
	case unix.S_IFLNK:
		s.typ, s.size, s.mode = core.Symlink, st.Size, 0
	default:
		s.typ = core.Other
	}
	return s
}

// node is one walked entry: its comparison key, its OS path and its lstat.
type node struct {
	rel  string // core.NormPath of the slash-separated relative path
	path string // absolute OS path (as found on disk, not normalized)
	st   statInfo
}

// vanished reports errors that mean the entry disappeared or changed kind
// while we looked at it; walkers skip such entries.
func vanished(err error) bool {
	return errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ENOTDIR) || errors.Is(err, unix.ELOOP) ||
		errors.Is(err, errKindChanged)
}

// errKindChanged marks an entry whose type changed between lstat and use.
var errKindChanged = errors.New("entry changed type while walking")

func defaultWorkers(n int) int {
	if n > 0 {
		return n
	}
	return runtime.GOMAXPROCS(0)
}

func absRoot(root string) (string, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	fi, err := os.Stat(abs)
	if err != nil {
		return "", err
	}
	if !fi.IsDir() {
		return "", fmt.Errorf("tree: %s is not a directory", abs)
	}
	return abs, nil
}

// dirQueue is an unbounded LIFO of directories with a pending counter, so a
// fixed pool of workers can walk a tree of any width without one goroutine
// per directory.
type dirQueue struct {
	mu      sync.Mutex
	cond    *sync.Cond
	items   [][2]string // abs, rel (raw, slash-separated)
	pending int         // queued + in progress
	stopped bool
}

func newDirQueue() *dirQueue {
	q := &dirQueue{}
	q.cond = sync.NewCond(&q.mu)
	return q
}

func (q *dirQueue) push(abs, rel string) {
	q.mu.Lock()
	q.items = append(q.items, [2]string{abs, rel})
	q.pending++
	q.mu.Unlock()
	q.cond.Signal()
}

func (q *dirQueue) pop() ([2]string, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for len(q.items) == 0 && q.pending > 0 && !q.stopped {
		q.cond.Wait()
	}
	if q.stopped || len(q.items) == 0 {
		return [2]string{}, false
	}
	it := q.items[len(q.items)-1]
	q.items = q.items[:len(q.items)-1]
	return it, true
}

func (q *dirQueue) done() {
	q.mu.Lock()
	q.pending--
	last := q.pending == 0
	q.mu.Unlock()
	if last {
		q.cond.Broadcast()
	}
}

func (q *dirQueue) stop() {
	q.mu.Lock()
	q.stopped = true
	q.mu.Unlock()
	q.cond.Broadcast()
}

// walk lstats every entry below root (excluding the root itself and a
// root-level ".git") with a pool of workers and calls visit for each entry,
// concurrently. Entries that vanish mid-walk are skipped.
func walk(root string, workers int, visit func(n node) error) error {
	q := newDirQueue()
	var (
		errOnce  sync.Once
		firstErr error
		failed   atomic.Bool
	)
	fail := func(err error) {
		errOnce.Do(func() { firstErr = err })
		failed.Store(true)
		q.stop()
	}
	process := func(abs, rel string) {
		names, err := readNames(abs, rel != "")
		if err != nil {
			if !vanished(err) {
				fail(err)
			}
			return
		}
		for _, name := range names {
			if failed.Load() {
				return
			}
			if rel == "" && name == ".git" {
				continue
			}
			childAbs := abs + "/" + name
			childRel := name
			if rel != "" {
				childRel = rel + "/" + name
			}
			var st unix.Stat_t
			if err := lstat(childAbs, &st); err != nil {
				if vanished(err) {
					continue
				}
				fail(fmt.Errorf("lstat %s: %w", childAbs, err))
				return
			}
			n := node{rel: core.NormPath(childRel), path: childAbs, st: statOf(&st)}
			if err := visit(n); err != nil {
				fail(err)
				return
			}
			if n.st.typ == core.Dir {
				q.push(childAbs, childRel)
			}
		}
	}
	q.push(root, "")
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				it, ok := q.pop()
				if !ok {
					return
				}
				process(it[0], it[1])
				q.done()
			}
		}()
	}
	wg.Wait()
	return firstErr
}

// readNames lists a directory. With nofollow it refuses a directory that was
// replaced by a symlink after it was lstat'ed, so a walk never leaves root.
func readNames(dir string, nofollow bool) ([]string, error) {
	flags := os.O_RDONLY | unix.O_DIRECTORY
	if nofollow {
		flags |= unix.O_NOFOLLOW
	}
	f, err := os.OpenFile(dir, flags, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	names, err := f.Readdirnames(-1)
	if err != nil {
		return nil, err
	}
	sort.Strings(names)
	return names, nil
}

func lstat(path string, st *unix.Stat_t) error {
	for {
		err := unix.Lstat(path, st)
		if err != unix.EINTR {
			return err
		}
	}
}

func readlink(path string) (string, error) {
	t, err := os.Readlink(path)
	if errors.Is(err, unix.EINVAL) {
		return "", errKindChanged // no longer a symlink
	}
	return t, err
}

var bufPool = sync.Pool{New: func() any { b := make([]byte, 256<<10); return &b }}

// hashRegular hashes a regular file without following symlinks and without
// blocking on a fifo that replaced the file mid-walk. It returns the hex
// sha256 and the bytes hashed.
func hashRegular(path string) (string, int64, error) {
	var fd int
	var err error
	for {
		fd, err = unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
		if err != unix.EINTR {
			break
		}
	}
	if err != nil {
		return "", 0, err
	}
	defer unix.Close(fd)
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		return "", 0, err
	}
	if uint32(st.Mode)&unix.S_IFMT != unix.S_IFREG {
		return "", 0, errKindChanged
	}
	bp := bufPool.Get().(*[]byte)
	defer bufPool.Put(bp)
	buf := *bp
	h := sha256.New()
	var n int64
	for {
		k, err := unix.Read(fd, buf)
		if err == unix.EINTR || err == unix.EAGAIN {
			continue
		}
		if err != nil {
			return "", 0, fmt.Errorf("read %s: %w", path, err)
		}
		if k == 0 {
			break
		}
		h.Write(buf[:k])
		n += int64(k)
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// HashFile returns the hex sha256 of a file's content (following symlinks).
func HashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	bp := bufPool.Get().(*[]byte)
	defer bufPool.Put(bp)
	h := sha256.New()
	if _, err := io.CopyBuffer(h, f, *bp); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// NoiseXattr reports xattr names the oracle ignores: names the OS attaches on
// its own (provenance, quarantine, last-used date) and namespaces owned by
// the kernel, security modules or overlayfs.
func NoiseXattr(name string) bool {
	switch name {
	case "com.apple.provenance", "com.apple.quarantine", "com.apple.lastuseddate#PS":
		return true
	}
	return strings.HasPrefix(name, "security.") || strings.HasPrefix(name, "trusted.") ||
		strings.HasPrefix(name, "user.overlay.")
}

// readXattrs returns the sha256 of the sorted "name=value" pairs of the
// entry's non-noise xattrs (without following symlinks), "" when none.
func readXattrs(path string) (string, error) {
	var small [1024]byte
	list := small[:]
	for {
		sz, err := unix.Llistxattr(path, list)
		if err == nil {
			list = list[:sz]
			break
		}
		switch {
		case err == unix.EINTR:
		case err == unix.ERANGE && len(list) < maxXattrBuf:
			list = make([]byte, 2*len(list))
		case xattrUnsupported(err):
			return "", nil
		default:
			return "", err
		}
	}
	var names []string
	for _, n := range strings.Split(string(list), "\x00") {
		if n != "" && !NoiseXattr(n) {
			names = append(names, n)
		}
	}
	if len(names) == 0 {
		return "", nil
	}
	sort.Strings(names)
	h := sha256.New()
	val := make([]byte, 4096)
	found := false
	for _, n := range names {
		v, ok, err := getXattr(path, n, val)
		if err != nil {
			return "", err
		}
		if !ok {
			continue // removed between list and get
		}
		found = true
		h.Write([]byte(n))
		h.Write([]byte{'='})
		h.Write(v)
		h.Write([]byte{0})
		if cap(v) > cap(val) {
			val = v[:cap(v)]
		}
	}
	if !found {
		return "", nil
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func getXattr(path, name string, buf []byte) ([]byte, bool, error) {
	for {
		sz, err := unix.Lgetxattr(path, name, buf)
		switch {
		case err == nil:
			return buf[:sz], true, nil
		case err == unix.EINTR:
		case err == errNoAttr:
			return nil, false, nil
		case err == unix.ERANGE && len(buf) < maxXattrBuf:
			buf = make([]byte, 2*len(buf))
		default:
			return nil, false, fmt.Errorf("getxattr %s %s: %w", path, name, err)
		}
	}
}

// maxXattrBuf bounds xattr list and value buffers (resource forks can be big).
const maxXattrBuf = 256 << 20

func xattrUnsupported(err error) bool {
	return err == unix.ENOTSUP || err == unix.EOPNOTSUPP || err == unix.EPERM
}
