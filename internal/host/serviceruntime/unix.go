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

	"github.com/dbpprt/dieter/internal/platform/fsx"
	"golang.org/x/sys/unix"
)

func (r Runtime) installLock(ctx context.Context) (*fsx.Lock, error) {
	return fsx.LockContext(ctx, r.path("install.lock"), 20*time.Millisecond)
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
		file, err = fsx.OpenLockFile(path)
		if err != nil {
			return nil, err
		}
	}
	if err := fsx.TryLockFile(file); err != nil {
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
