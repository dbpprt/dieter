package store

import (
	"errors"
	"os"
	"sync"
	"syscall"
	"testing"
)

func TestReadersKeepDurableConversationWhenCommitRecoveryRunsOutOfSpace(t *testing.T) {
	for _, capacity := range []error{syscall.ENOSPC, syscall.EDQUOT} {
		t.Run(capacity.Error(), func(t *testing.T) {
			data, card := batchFixture(t)
			before, err := data.MetadataRevision()
			if err != nil {
				t.Fatal(err)
			}
			data.syncWrite = func(path string, _ []byte, _ os.FileMode) error {
				return &os.PathError{Op: "write", Path: path, Err: capacity}
			}
			if _, _, err := data.AppendUIChunks(card.ID, "turn", tokenBatch(1, "durable reply")); err != nil {
				t.Fatal(err)
			}
			if !data.SyncMutationPending() {
				t.Fatal("failed counter publication must retain its recovery marker")
			}
			active, err := data.MetadataRevision()
			if err != nil || active != before {
				t.Fatalf("text invalidated metadata before a reader boundary: %+v %v", active, err)
			}
			if err := data.WaitForWriter(t.Context()); err != nil {
				t.Fatalf("reader needs no free disk space: %v", err)
			}
			after, err := data.MetadataRevision()
			if err != nil || after.Sequence <= before.Sequence {
				t.Fatalf("durable but unpublished change was missed: %+v %v", after, err)
			}
			conversation, err := data.Conversation(card.ID)
			if err != nil || len(conversation.Messages) != 2 || conversation.Messages[1].Parts[0].Text != "durable reply" {
				t.Fatalf("durable reply became unreadable: %+v %v", conversation, err)
			}
			if _, err := data.GlobalState(); err != nil {
				t.Fatalf("the workspace became unreadable: %v", err)
			}
			if _, _, err := data.AppendUIChunks(card.ID, "turn", tokenBatch(1, "cannot commit")); !errors.Is(err, capacity) {
				t.Fatalf("writers must still report storage failure: %v", err)
			}
			if !data.SyncMutationPending() {
				t.Fatal("reader must not discard the pending commit")
			}
			data.syncWrite = nil
			if err := data.WaitForWriter(t.Context()); err != nil {
				t.Fatal(err)
			}
			if data.SyncMutationPending() {
				t.Fatal("recovery must finish when storage returns")
			}
			committed, err := data.MetadataRevision()
			if err != nil || committed != after {
				t.Fatalf("recovery changed the observed revision: %+v %v", committed, err)
			}
		})
	}
}

func TestReaderRecoveryDoesNotHideNonCapacityFailures(t *testing.T) {
	data, card := batchFixture(t)
	data.syncWrite = func(string, []byte, os.FileMode) error { return syscall.EIO }
	if _, _, err := data.AppendUIChunks(card.ID, "turn", tokenBatch(1, "reply")); err != nil {
		t.Fatal(err)
	}
	if err := data.WaitForWriter(t.Context()); !errors.Is(err, syscall.EIO) {
		t.Fatalf("lost storage corruption failure: %v", err)
	}
}

// changeCounters reads the committed change counter and its metadata part.
func changeCounters(t *testing.T, s *Store) (changes, metadata uint64) {
	t.Helper()
	changes, err := readCounter(s.syncHighwaterPath())
	if err != nil {
		t.Fatal(err)
	}
	metadata, err = readCounter(s.syncMetadataPath())
	if err != nil {
		t.Fatal(err)
	}
	return changes, metadata
}

func TestChangeCounterIsDurableAndMonotonic(t *testing.T) {
	data := New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	initial, err := data.MetadataRevision()
	if err != nil || initial.Epoch == "" || initial.Sequence != 0 {
		t.Fatalf("initial revision=%#v err=%v", initial, err)
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
	if changes, metadata := changeCounters(t, data); changes != writers || metadata != writers {
		t.Fatalf("counters changes=%d metadata=%d", changes, metadata)
	}
	reopened := New(data.Root)
	revision, err := reopened.MetadataRevision()
	if err != nil || revision != (StoreRevision{Epoch: initial.Epoch, Sequence: writers}) {
		t.Fatalf("reopened revision=%#v err=%v", revision, err)
	}
}

func TestChangeCounterAdvancesOnlyAfterCommit(t *testing.T) {
	data := New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	release, err := data.beginWrite()
	if err != nil {
		t.Fatal(err)
	}
	if changes, _ := changeCounters(t, data); changes != 0 || !data.SyncMutationPending() {
		release()
		t.Fatalf("prepared write changed=%d pending=%v", changes, data.SyncMutationPending())
	}
	release()
	if changes, metadata := changeCounters(t, data); changes != 1 || metadata != 1 || data.SyncMutationPending() {
		t.Fatalf("committed changes=%d metadata=%d pending=%v", changes, metadata, data.SyncMutationPending())
	}
}

func TestConversationTextAdvancesOnlyTheChangeCounter(t *testing.T) {
	data := New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	release, err := data.beginWriteKind(conversationChange)
	if err != nil {
		t.Fatal(err)
	}
	release()
	if changes, metadata := changeCounters(t, data); changes != 1 || metadata != 0 {
		t.Fatalf("text changes=%d metadata=%d", changes, metadata)
	}
}

func TestRecoveredWriteCountsAsMetadataChange(t *testing.T) {
	data := New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	release, err := data.beginWriteLock()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = data.prepareSyncMutation(conversationChange); err != nil {
		release()
		t.Fatal(err)
	}
	release() // a writer killed before its commit
	if err := data.WaitForWriter(t.Context()); err != nil {
		t.Fatal(err)
	}
	if changes, metadata := changeCounters(t, data); changes != 1 || metadata != 1 || data.SyncMutationPending() {
		t.Fatalf("recovered changes=%d metadata=%d pending=%v", changes, metadata, data.SyncMutationPending())
	}
}
