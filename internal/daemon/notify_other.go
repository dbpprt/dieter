//go:build !linux

package daemon

func notifyServiceReady(string, string) error { return nil }
