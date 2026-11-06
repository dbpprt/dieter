//go:build linux

package linuxfs

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

// ReflinkTree recreates src at dst: directories, symlinks and fifos are
// recreated, regular files are cloned with FICLONE (falling back to a full
// copy on EOPNOTSUPP, EXDEV, EINVAL or ENOTTY), and mode, xattrs and
// atime/mtime are copied. Hard links become independent clones; sockets and
// devices are skipped. dst must not exist or be empty. It returns the
// elapsed time and the number of files that needed the copy fallback.
func ReflinkTree(src, dst string) (time.Duration, int, error) {
	start := time.Now()
	var rootSt unix.Stat_t
	if err := unix.Stat(src, &rootSt); err != nil {
		return 0, 0, &fs.PathError{Op: "stat", Path: src, Err: err}
	}
	if err := os.MkdirAll(dst, 0o700); err != nil {
		return 0, 0, err
	}
	if ents, err := os.ReadDir(dst); err != nil {
		return 0, 0, err
	} else if len(ents) > 0 {
		return 0, 0, fmt.Errorf("linuxfs: reflink destination %s is not empty", dst)
	}
	type dirMeta struct {
		src, dst string
		st       unix.Stat_t
	}
	dirs := []dirMeta{{src, dst, rootSt}}
	var files []dirMeta
	var werr error
	err := walk(src, func(n node) bool {
		if werr != nil {
			return false
		}
		target := filepath.Join(dst, n.rel)
		switch n.st.Mode & unix.S_IFMT {
		case unix.S_IFDIR:
			if werr = os.Mkdir(target, 0o700); werr == nil {
				dirs = append(dirs, dirMeta{n.full, target, n.st})
			}
			return werr == nil
		case unix.S_IFLNK:
			var link string
			if link, werr = os.Readlink(n.full); werr == nil {
				if werr = os.Symlink(link, target); werr == nil {
					werr = setTimes(target, &n.st)
				}
			}
		case unix.S_IFREG:
			files = append(files, dirMeta{n.full, target, n.st})
		case unix.S_IFIFO:
			if werr = unix.Mkfifo(target, n.st.Mode&0o7777); werr == nil {
				werr = setTimes(target, &n.st)
			}
		}
		return false
	})
	if err == nil {
		err = werr
	}
	if err != nil {
		return time.Since(start), 0, err
	}
	var fallbacks atomic.Int64
	err = parallel(len(files), func(buf []byte, i int) error {
		f := &files[i]
		fell, err := cloneFile(f.src, f.dst, &f.st, buf)
		if fell {
			fallbacks.Add(1)
		}
		return err
	})
	if err != nil {
		return time.Since(start), int(fallbacks.Load()), err
	}
	// Deepest first, so a read-only parent never blocks a child.
	for i := len(dirs) - 1; i >= 0; i-- {
		d := &dirs[i]
		copyXattrs(d.src, d.dst)
		if err := os.Chmod(d.dst, os.FileMode(d.st.Mode&0o777)|modeBits(d.st.Mode)); err != nil {
			return time.Since(start), int(fallbacks.Load()), err
		}
		if err := setTimes(d.dst, &d.st); err != nil {
			return time.Since(start), int(fallbacks.Load()), err
		}
	}
	return time.Since(start), int(fallbacks.Load()), nil
}

func modeBits(m uint32) os.FileMode {
	var out os.FileMode
	if m&unix.S_ISUID != 0 {
		out |= os.ModeSetuid
	}
	if m&unix.S_ISGID != 0 {
		out |= os.ModeSetgid
	}
	if m&unix.S_ISVTX != 0 {
		out |= os.ModeSticky
	}
	return out
}

func cloneFile(src, dst string, st *unix.Stat_t, buf []byte) (fallback bool, err error) {
	in, err := os.Open(src)
	if err != nil {
		return false, err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return false, err
	}
	defer func() {
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		if err == nil {
			err = setTimes(dst, st)
		}
	}()
	if err := unix.IoctlFileClone(int(out.Fd()), int(in.Fd())); err != nil {
		if !cloneUnsupported(err) {
			return false, &fs.PathError{Op: "ficlone", Path: dst, Err: err}
		}
		fallback = true
		if _, err := io.CopyBuffer(struct{ io.Writer }{out}, struct{ io.Reader }{in}, buf); err != nil {
			return true, err
		}
	}
	copyXattrs(src, dst)
	if err := unix.Fchmod(int(out.Fd()), st.Mode&0o7777); err != nil {
		return fallback, &fs.PathError{Op: "fchmod", Path: dst, Err: err}
	}
	return fallback, nil
}

func cloneUnsupported(err error) bool {
	return errors.Is(err, unix.EOPNOTSUPP) || errors.Is(err, unix.EXDEV) ||
		errors.Is(err, unix.EINVAL) || errors.Is(err, unix.ENOTTY) || errors.Is(err, unix.ENOSYS)
}

// copyXattrs copies what it can (user.* and system.* for an owner); names
// the caller may not set are skipped.
func copyXattrs(src, dst string) {
	x, err := readXattrs(src)
	if err != nil {
		return
	}
	for name, v := range x {
		_ = unix.Lsetxattr(dst, name, v, 0)
	}
}

func setTimes(path string, st *unix.Stat_t) error {
	ts := []unix.Timespec{st.Atim, st.Mtim}
	if err := unix.UtimesNanoAt(unix.AT_FDCWD, path, ts, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return &fs.PathError{Op: "utimensat", Path: path, Err: err}
	}
	return nil
}
