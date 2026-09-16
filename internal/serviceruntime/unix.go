//go:build darwin || linux

package serviceruntime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func openLock(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}

func (r Runtime) installLock(ctx context.Context) (*os.File, error) {
	file, err := openLock(r.path("install.lock"))
	if err != nil {
		return nil, err
	}
	for {
		err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			return file, nil
		}
		if !errors.Is(err, unix.EWOULDBLOCK) {
			file.Close()
			return nil, err
		}
		select {
		case <-ctx.Done():
			file.Close()
			return nil, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

func serviceLock(path, inherited string) (*os.File, error) {
	var file *os.File
	if inherited != "" {
		fd, err := strconv.Atoi(inherited)
		if err != nil || fd < 3 {
			return nil, errors.New("invalid inherited service lock")
		}
		file = os.NewFile(uintptr(fd), path)
		actual, err := file.Stat()
		expected, statErr := os.Lstat(path)
		if err != nil || statErr != nil || !os.SameFile(actual, expected) {
			file.Close()
			return nil, errors.New("inherited service lock does not match runtime")
		}
		unix.CloseOnExec(fd)
		os.Unsetenv(lockEnv)
	} else {
		var err error
		file, err = openLock(path)
		if err != nil {
			return nil, err
		}
	}
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		file.Close()
		return nil, fmt.Errorf("service runtime is already in use: %w", err)
	}
	return file, nil
}

func inheritLock(file *os.File) error {
	_, err := unix.FcntlInt(file.Fd(), unix.F_SETFD, 0)
	return err
}
func execProcess(path string, args, env []string) error { return syscall.Exec(path, args, env) }
