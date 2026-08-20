package store

import (
	"sync"
	"testing"
)

func TestSyncEventsAreDurableAndGloballyMonotonic(t *testing.T) {
	data := New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	initial, events, err := data.SyncEvents(0, 256)
	if err != nil || initial.Epoch == "" || initial.Sequence != 0 || len(events) != 0 {
		t.Fatalf("initial cursor=%#v events=%#v err=%v", initial, events, err)
	}

	const writers = 24
	var group sync.WaitGroup
	errors := make(chan error, writers)
	for range writers {
		group.Add(1)
		go func() {
			defer group.Done()
			release, beginErr := data.beginWrite()
			if beginErr != nil {
				errors <- beginErr
				return
			}
			release()
		}()
	}
	group.Wait()
	close(errors)
	for writerErr := range errors {
		t.Fatal(writerErr)
	}

	cursor, events, err := data.SyncEvents(0, 256)
	if err != nil {
		t.Fatal(err)
	}
	if cursor.Epoch != initial.Epoch || cursor.Sequence != writers || len(events) != writers {
		t.Fatalf("cursor=%#v events=%d", cursor, len(events))
	}
	for index, event := range events {
		want := uint64(index + 1)
		if event.Sequence != want || event.Kind != "store_changed" || event.CreatedAt == "" {
			t.Fatalf("event[%d]=%#v want sequence %d", index, event, want)
		}
	}

	reopened := New(data.Root)
	resumed, tail, err := reopened.SyncEvents(writers-1, 10)
	if err != nil || resumed != cursor || len(tail) != 1 || tail[0].Sequence != writers {
		t.Fatalf("reopened cursor=%#v tail=%#v err=%v", resumed, tail, err)
	}
}

func TestSyncEventPrecedesMutationAndWriterBarrier(t *testing.T) {
	data := New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	release, err := data.beginWrite()
	if err != nil {
		t.Fatal(err)
	}
	cursor, events, err := data.SyncEvents(0, 10)
	if err != nil || cursor.Sequence != 1 || len(events) != 1 {
		release()
		t.Fatalf("prepared cursor=%#v events=%#v err=%v", cursor, events, err)
	}
	release()

	resumed, events, err := data.SyncEvents(0, 10)
	if err != nil || resumed.Sequence != 1 || len(events) != 1 {
		t.Fatalf("committed cursor=%#v events=%#v err=%v", resumed, events, err)
	}
}

func TestSyncCompactionChangesEpochAndRetainsTail(t *testing.T) {
	data := New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	for range 7 {
		release, err := data.beginWrite()
		if err != nil {
			t.Fatal(err)
		}
		release()
	}
	before, _, err := data.SyncEvents(0, 20)
	if err != nil {
		t.Fatal(err)
	}
	if err := data.compactSyncJournal(3); err != nil {
		t.Fatal(err)
	}
	after, events, err := data.SyncEvents(0, 20)
	if err != nil {
		t.Fatal(err)
	}
	if after.Epoch == before.Epoch || after.Sequence != 7 || len(events) != 3 || events[0].Sequence != 5 || events[2].Sequence != 7 {
		t.Fatalf("before=%#v after=%#v events=%#v", before, after, events)
	}
}
