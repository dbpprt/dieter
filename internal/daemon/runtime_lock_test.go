//go:build darwin || linux

package daemon

import "testing"

func TestRuntimeLockExcludesSecondDaemon(t *testing.T) {
	root := t.TempDir()
	first, err := AcquireRuntimeLock(root)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	if second, err := AcquireRuntimeLock(root); err == nil {
		_ = second.Close()
		t.Fatal("second daemon acquired the same runtime lock")
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	third, err := AcquireRuntimeLock(root)
	if err != nil {
		t.Fatalf("lock was not released: %v", err)
	}
	_ = third.Close()
}
