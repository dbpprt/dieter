package link

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/dbpprt/dieter/internal/platform/fsx"
)

// RuntimeLock excludes a second daemon using the same DIETER_HOME. Store write
// locks serialize individual mutations, but only this lifetime lock prevents
// duplicate schedulers, gateway tunnels, and process managers.
type RuntimeLock struct{ lock *fsx.Lock }

func AcquireRuntimeLock(root string) (*RuntimeLock, error) {
	dir := filepath.Join(root, "runtime")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	lock, err := fsx.TryLock(filepath.Join(dir, "daemon.lock"))
	if errors.Is(err, fsx.ErrLocked) {
		return nil, fmt.Errorf("another Dieter daemon already owns %s", root)
	}
	if err != nil {
		return nil, err
	}
	return &RuntimeLock{lock: lock}, nil
}

func (l *RuntimeLock) Close() error {
	if l == nil {
		return nil
	}
	return l.lock.Close()
}
