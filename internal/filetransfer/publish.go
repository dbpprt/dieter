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

// PublishOptions adjusts Publish.
type PublishOptions struct {
	// Quarantine marks the file as received from another device (macOS).
	Quarantine bool
}

// Publish streams into a private sibling file and atomically replaces the
// observed destination. Temporary files contain payload only, never metadata.
func Publish(ctx context.Context, root, p, expected string, source Entry, r io.Reader) error {
	_, err := PublishWith(ctx, root, p, expected, source, r, PublishOptions{})
	return err
}

// PublishWith is Publish with options. It returns the published file as it
// was observed just before it took the destination's name: a later edit of
// the file can never carry the published content's revision. The rename may
// change the file's ctime, which only makes the next scan hash it again.
func PublishWith(ctx context.Context, root, p, expected string, source Entry, r io.Reader, options PublishOptions) (Entry, error) {
	published, err := publish(ctx, root, p, expected, source, r, options)
	return published, err
}

func publish(ctx context.Context, root, p, expected string, source Entry, r io.Reader, options PublishOptions) (published Entry, err error) {
	if expected == "" || !ValidDigest(source.SHA256) || source.Size < 0 {
		return Entry{}, fault.Invalidf("destination revision, size and SHA-256 required")
	}
	dir, name, err := Parent(root, p, true)
	if err != nil {
		return Entry{}, err
	}
	defer dir.Close()
	tmp := TemporaryPrefix + rand.Text()
	fd, err := unix.Openat(int(dir.Fd()), tmp, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return Entry{}, err
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
	if err == nil && options.Quarantine {
		err = quarantine(fd)
	}
	if err == nil {
		times := []unix.Timespec{unix.NsecToTimespec(source.Modified), unix.NsecToTimespec(source.Modified)}
		err = unix.UtimesNanoAt(int(dir.Fd()), tmp, times, unix.AT_SYMLINK_NOFOLLOW)
	}
	if err == nil {
		err = f.Sync()
	}
	if err == nil {
		published, err = Describe(ctx, f, p, false)
		published.SHA256 = source.SHA256
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		return Entry{}, err
	}
	current := Missing
	targetFD, e := unix.Openat(int(dir.Fd()), name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if e == nil {
		target := os.NewFile(uintptr(targetFD), p)
		entry, se := Describe(ctx, target, p, false)
		_ = target.Close()
		if se != nil {
			return Entry{}, se
		}
		if entry.Kind != "file" {
			return Entry{}, fault.Invalidf("destination is not a regular file")
		}
		current = entry.Revision
	} else if !errors.Is(e, os.ErrNotExist) {
		return Entry{}, e
	}
	if current != expected {
		return Entry{}, fault.New(fault.Conflict, "destination changed before commit")
	}
	if err = ctx.Err(); err != nil {
		return Entry{}, err
	}
	if expected == Missing {
		// Link is create-only; it never overwrites a concurrently created file.
		err = unix.Linkat(int(dir.Fd()), tmp, int(dir.Fd()), name, 0)
	} else {
		err = unix.Renameat(int(dir.Fd()), tmp, int(dir.Fd()), name)
	}
	if err != nil {
		return Entry{}, err
	}
	return published, dir.Sync()
}
