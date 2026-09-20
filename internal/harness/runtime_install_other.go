//go:build !unix

package harness

import (
	"context"
	"errors"
	"os"
	"time"
)

type runtimeInstallLock struct {
	path string
	file *os.File
}

func acquireRuntimeInstallLock(ctx context.Context, path string) (*runtimeInstallLock, error) {
	for {
		file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
		if err == nil {
			return &runtimeInstallLock{path: path, file: file}, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		timer := time.NewTimer(50 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}

func (l *runtimeInstallLock) Close() error {
	if l == nil {
		return nil
	}
	var closeErr error
	if l.file != nil {
		closeErr = l.file.Close()
	}
	return errors.Join(closeErr, os.Remove(l.path))
}
