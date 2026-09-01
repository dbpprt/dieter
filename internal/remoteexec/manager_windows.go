//go:build windows

package remoteexec

import "context"

type windowsBackend struct{}

func newBackend() backend { return &windowsBackend{} }

func (*windowsBackend) List(string, string, string) []Execution { return nil }
func (*windowsBackend) Get(string) (Execution, error)           { return Execution{}, ErrUnsupported }
func (*windowsBackend) Start(StartInput) (Execution, error)     { return Execution{}, ErrUnsupported }
func (*windowsBackend) Events(string, uint64) ([]Event, <-chan struct{}, error) {
	return nil, nil, ErrUnsupported
}
func (*windowsBackend) Write(string, []byte, bool) (Execution, error) {
	return Execution{}, ErrUnsupported
}
func (*windowsBackend) Signal(string, Signal) (Execution, error) {
	return Execution{}, ErrUnsupported
}
func (*windowsBackend) Resize(string, int, int) (Execution, error) {
	return Execution{}, ErrUnsupported
}
func (*windowsBackend) Cancel(string) (Execution, error) { return Execution{}, ErrUnsupported }
func (*windowsBackend) Close(string) error               { return ErrUnsupported }
func (*windowsBackend) Shutdown(context.Context)         {}
