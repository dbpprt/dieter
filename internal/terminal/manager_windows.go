//go:build windows

package terminal

import "context"

type unsupportedBackend struct{}

func newBackend() backend                                      { return unsupportedBackend{} }
func (unsupportedBackend) List(string) []Session               { return nil }
func (unsupportedBackend) Get(string) (Session, error)         { return Session{}, ErrUnsupported }
func (unsupportedBackend) Create(CreateInput) (Session, error) { return Session{}, ErrUnsupported }
func (unsupportedBackend) Frames(string, uint64) ([]Frame, <-chan struct{}, error) {
	return nil, nil, ErrUnsupported
}
func (unsupportedBackend) Write(string, []byte) (Session, error)    { return Session{}, ErrUnsupported }
func (unsupportedBackend) Resize(string, int, int) (Session, error) { return Session{}, ErrUnsupported }
func (unsupportedBackend) Rename(string, string) (Session, error)   { return Session{}, ErrUnsupported }
func (unsupportedBackend) Close(string) error                       { return ErrUnsupported }
func (unsupportedBackend) Shutdown(context.Context)                 {}
