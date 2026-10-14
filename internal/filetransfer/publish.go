package filetransfer

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"golang.org/x/sys/unix"
)

// Publish streams into a private sibling file and atomically replaces the
// observed destination. Temporary files contain payload only, never metadata.
func Publish(ctx context.Context, root, p, expected string, source Entry, r io.Reader) error {
	if expected == "" || !ValidDigest(source.SHA256) || source.Size < 0 {
		return fault.Invalidf("destination revision, size and SHA-256 required")
	}
	dir, name, err := Parent(root, p, true)
	if err != nil {
		return err
	}
	defer dir.Close()
	tmp := TemporaryPrefix + rand.Text()
	fd, err := unix.Openat(int(dir.Fd()), tmp, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return err
	}
	defer func() { _ = unix.Unlinkat(int(dir.Fd()), tmp, 0) }()
	f := os.NewFile(uintptr(fd), tmp)
	h := sha256.New()
	n, err := io.CopyBuffer(io.MultiWriter(f, h), io.LimitReader(&contextReader{ctx, r}, source.Size+1), make([]byte, ChunkSize))
	if err == nil && (n != source.Size || hex.EncodeToString(h.Sum(nil)) != source.SHA256) {
		err = fault.New(fault.DataLoss, "transfer size or SHA-256 mismatch")
	}
	if err == nil {
		err = f.Chmod(os.FileMode(source.Mode & 0o777))
	}
	if err == nil {
		times := []unix.Timespec{unix.NsecToTimespec(source.Modified), unix.NsecToTimespec(source.Modified)}
		err = unix.UtimesNanoAt(int(dir.Fd()), tmp, times, unix.AT_SYMLINK_NOFOLLOW)
	}
	if err == nil {
		err = f.Sync()
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		return err
	}
	current := Missing
	targetFD, e := unix.Openat(int(dir.Fd()), name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if e == nil {
		target := os.NewFile(uintptr(targetFD), p)
		entry, se := Describe(ctx, target, p, false)
		_ = target.Close()
		if se != nil {
			return se
		}
		if entry.Kind != "file" {
			return fault.Invalidf("destination is not a regular file")
		}
		current = entry.Revision
	} else if !errors.Is(e, os.ErrNotExist) {
		return e
	}
	if current != expected {
		return fault.New(fault.Conflict, "destination changed before commit")
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if expected == Missing {
		// Link is create-only; it never overwrites a concurrently created file.
		err = unix.Linkat(int(dir.Fd()), tmp, int(dir.Fd()), name, 0)
	} else {
		err = unix.Renameat(int(dir.Fd()), tmp, int(dir.Fd()), name)
	}
	if err != nil {
		return err
	}
	return dir.Sync()
}
