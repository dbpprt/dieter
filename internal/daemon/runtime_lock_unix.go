//go:build darwin || linux

package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// RuntimeLock excludes a second daemon using the same DIETER_HOME. Store write
// locks serialize individual mutations, but only this lifetime lock prevents
// duplicate schedulers, gateway tunnels, and process managers.
type RuntimeLock struct{ file *os.File }

func AcquireRuntimeLock(root string) (*RuntimeLock, error) {
	dir := filepath.Join(root, "runtime")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "daemon.lock")
	fd, err := unix.Open(path, unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = file.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, fmt.Errorf("another Dieter daemon already owns %s", root)
		}
		return nil, err
	}
	return &RuntimeLock{file: file}, nil
}

func (l *RuntimeLock) Close() error {
	if l == nil || l.file == nil {
		return nil
	}
	err := l.file.Close()
	l.file = nil
	return err
}
