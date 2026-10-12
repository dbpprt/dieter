package home

import (
	"testing"
	"time"
)

func TestCommitNotificationsBroadcastAcrossStoresAndReleaseWatcher(t *testing.T) {
	t.Parallel()
	s := New(t.TempDir())
	if err := s.EnsureSyncEpoch(); err != nil {
		t.Fatal(err)
	}
	other := New(s.Root)
	defer other.CloseNotifications()
	first, stopFirst := other.SubscribeChanges()
	second, stopSecond := other.SubscribeChanges()
	defer stopFirst()
	defer stopSecond()
	// A commit by another process reaches the watcher only through the filesystem.
	release, err := s.BeginWrite()
	if err != nil {
		t.Fatal(err)
	}
	release()
	for _, ch := range []<-chan struct{}{first, second} {
		select {
		case <-ch:
		case <-time.After(time.Second):
			t.Fatal("filesystem commit did not wake every subscriber")
		}
	}
	stopFirst()
	stopFirst()
	stopSecond()
	other.notifications.mu.Lock()
	defer other.notifications.mu.Unlock()
	if other.notifications.watcher != nil || len(other.notifications.listeners) != 0 {
		t.Fatal("watcher leaked after last subscription")
	}
}

func TestCommitNotificationsCoalesceSlowConsumers(t *testing.T) {
	t.Parallel()
	s := New(t.TempDir())
	ch, stop := s.SubscribeChanges()
	defer stop()
	for range 10000 {
		s.NotifyChanges()
	}
	if len(ch) != 1 {
		t.Fatalf("unbounded notification queue: %d", len(ch))
	}
}
