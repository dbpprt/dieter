package store

import (
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

func TestCommitNotificationsBroadcastAcrossStoresAndReleaseWatcher(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	other := New(s.Root)
	defer other.Close()
	first, stopFirst := other.SubscribeChanges()
	second, stopSecond := other.SubscribeChanges()
	defer stopFirst()
	defer stopSecond()
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "cross-process filesystem hint"})
	if err != nil {
		t.Fatal(err)
	}
	for _, ch := range []<-chan struct{}{first, second} {
		select {
		case <-ch:
			if _, err := other.ResolveCard(card.ID); err != nil {
				t.Fatal(err)
			}
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
	s := New(t.TempDir())
	ch, stop := s.SubscribeChanges()
	defer stop()
	for range 10000 {
		s.notifyChanges()
	}
	if len(ch) != 1 {
		t.Fatalf("unbounded notification queue: %d", len(ch))
	}
}
