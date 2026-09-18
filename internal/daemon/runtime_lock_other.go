//go:build !darwin && !linux

package daemon

type RuntimeLock struct{}

func AcquireRuntimeLock(string) (*RuntimeLock, error) { return &RuntimeLock{}, nil }
func (*RuntimeLock) Close() error                     { return nil }
