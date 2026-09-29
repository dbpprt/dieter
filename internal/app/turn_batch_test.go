package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

type batchRunnerFunc func(context.Context, harness.Request, func(harness.Output) error) error

func (f batchRunnerFunc) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	return f(ctx, request, emit)
}

func tokenOutput(token string) harness.Output {
	raw, _ := json.Marshal(map[string]string{"type": "text-delta", "id": "text", "delta": token})
	return harness.Output{Type: "chunk", Chunk: raw}
}

func TestTurnBatchBoundsOrderAndOwnedBuffers(t *testing.T) {
	var want, got []string
	var sizes []int
	runner := batchRunnerFunc(func(_ context.Context, _ harness.Request, emit func(harness.Output) error) error {
		buffer := make([]byte, 100)
		for i := range 70 {
			value := fmt.Sprintf("%02d", i)
			want = append(want, value)
			output := tokenOutput(value)
			copy(buffer, output.Chunk)
			output.Chunk = buffer[:len(output.Chunk)]
			if err := emit(output); err != nil {
				return err
			}
		}
		// Reuse the provider's scratch space immediately after emit returns.
		clear(buffer)
		for _, kind := range []string{"session", "capability", "present-content", "error"} {
			want = append(want, kind)
			if err := emit(harness.Output{Type: kind}); err != nil {
				return err
			}
		}
		for _, length := range []int{40000, 40000, store.MaxUIChunkBatchBytes + 1} {
			value := strings.Repeat("x", length)
			want = append(want, value)
			if err := emit(tokenOutput(value)); err != nil {
				return err
			}
		}
		return nil
	})
	collect := func(chunks []json.RawMessage) error {
		for _, raw := range chunks {
			var chunk struct{ Delta string }
			if err := json.Unmarshal(raw, &chunk); err != nil {
				return err
			}
			got = append(got, chunk.Delta)
		}
		return nil
	}
	err := runBatchedTurnOutputs(t.Context(), runner, harness.Request{}, func(chunks []json.RawMessage) error {
		size := 0
		for _, chunk := range chunks {
			size += len(chunk)
		}
		if size > store.MaxUIChunkBatchBytes || len(chunks) > store.MaxUIChunkBatchEvents {
			t.Errorf("unbounded batch: %d events %d bytes", len(chunks), size)
		}
		sizes = append(sizes, len(chunks))
		return collect(chunks)
	}, func(output harness.Output) error {
		if output.Type == "chunk" {
			return collect([]json.RawMessage{output.Chunk})
		}
		got = append(got, output.Type)
		return nil
	})
	if err != nil || !reflect.DeepEqual(want, got) {
		t.Fatalf("batched output changed order/content: entries=%d want=%d err=%v", len(got), len(want), err)
	}
	batched := false
	for _, n := range sizes {
		batched = batched || n > 1
	}
	if !batched {
		t.Fatal("token burst was never batched")
	}
}

func TestTurnBatchTimerFlushesWhileRunnerWaits(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	flushed := make(chan struct{})
	runner := batchRunnerFunc(func(ctx context.Context, _ harness.Request, emit func(harness.Output) error) error {
		if err := emit(tokenOutput("visible while running")); err != nil {
			return err
		}
		select {
		case <-flushed:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	})
	err := runBatchedTurnOutputs(ctx, runner, harness.Request{}, func(chunks []json.RawMessage) error {
		close(flushed)
		return nil
	}, func(harness.Output) error { return nil })
	if err != nil {
		t.Fatalf("timer did not publish while runner was idle: %v", err)
	}
}

func TestTurnBatchDrainsOnExitFailureAndCancellation(t *testing.T) {
	for _, ending := range []string{"success", "error", "cancel"} {
		t.Run(ending, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			var order []string
			failure := errors.New("worker diagnostic")
			runner := batchRunnerFunc(func(ctx context.Context, _ harness.Request, emit func(harness.Output) error) error {
				if err := emit(tokenOutput("retained")); err != nil {
					return err
				}
				switch ending {
				case "error":
					return failure
				case "cancel":
					cancel()
					// Restart suspension may emit continuation under a canceled
					// context; it must follow the buffered text durably.
					if err := emit(harness.Output{Type: "session"}); err != nil {
						return err
					}
					return ctx.Err()
				}
				return nil
			})
			err := runBatchedTurnOutputs(ctx, runner, harness.Request{}, func([]json.RawMessage) error {
				order = append(order, "persist")
				return nil
			}, func(output harness.Output) error {
				order = append(order, output.Type)
				return nil
			})
			want := []string{"persist"}
			if ending == "cancel" {
				want = append(want, "session")
			}
			if !reflect.DeepEqual(order, want) || ending == "success" && err != nil || ending == "error" && !errors.Is(err, failure) || ending == "cancel" && !errors.Is(err, context.Canceled) {
				t.Fatalf("exit lost data/diagnostics: %v %v", order, err)
			}
		})
	}
}

func TestTurnBatchPersistenceFailureCancelsAndJoinsIdleRunner(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	failure := errors.New("journal fsync failed")
	runner := batchRunnerFunc(func(ctx context.Context, _ harness.Request, emit func(harness.Output) error) error {
		if err := emit(tokenOutput("unacknowledged")); err != nil {
			return err
		}
		<-ctx.Done()
		// A provider that attempts a trailing output receives the original
		// persistence error; no uncertain batch is replayed.
		return emit(harness.Output{Type: "session"})
	})
	attempts := 0
	err := runBatchedTurnOutputs(ctx, runner, harness.Request{}, func([]json.RawMessage) error {
		attempts++
		return failure
	}, func(harness.Output) error {
		t.Error("output handled after persistence failed")
		return nil
	})
	if !errors.Is(err, failure) || attempts != 1 || ctx.Err() != nil {
		t.Fatalf("failed append replayed or runner leaked: attempts=%d err=%v", attempts, err)
	}
}

func TestBatchedTurnPublishesOnlyPersistedChunksAndRetainsTrailingSession(t *testing.T) {
	service, _, project, board := appSetup(t)
	defer service.Store.Close()
	service.Runner = batchRunnerFunc(func(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
		for _, chunk := range []string{`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`, `{"type":"text-start","id":"text"}`} {
			if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
				return err
			}
		}
		for i := range 96 {
			if err := emit(tokenOutput(fmt.Sprintf("%02d ", i))); err != nil {
				return err
			}
		}
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(`{"type":"finish"}`)}); err != nil {
			return err
		}
		card, err := service.Store.ResolveCard(request.SessionID)
		if err != nil || card.Runtime != "running" {
			return fmt.Errorf("turn became idle before trailing state: runtime=%s error=%v", card.Runtime, err)
		}
		return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"session":"batch"}}`)})
	})
	card, err := service.Store.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: "batched", Provider: "codex", Model: "gpt-5.5", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	before, _, _ := service.Store.SyncEvents(0, 256)
	updates, err := service.StartCard(card.ID, "stream", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	reader := store.New(service.Store.Root)
	defer reader.Close()
	var visible strings.Builder
	deltas, done := 0, false
	for update := range updates {
		if update.Err != nil {
			t.Error(update.Err)
		}
		var chunk struct{ Type, Delta string }
		_ = json.Unmarshal(update.Chunk, &chunk)
		if chunk.Type == "text-delta" {
			visible.WriteString(chunk.Delta)
			deltas++
			conversation, err := reader.Conversation(card.ID)
			if err != nil || len(conversation.Messages) < 2 || !strings.HasPrefix(conversation.Messages[1].Parts[0].Text, visible.String()) {
				t.Errorf("client saw an unpersisted chunk: %v", err)
			}
		}
		done = done || update.Done
	}
	conversation, err := reader.Conversation(card.ID)
	if err != nil || !done || deltas != 96 || conversation.Status != "idle" || !strings.Contains(string(conversation.Session), "batch") || conversation.Messages[1].Parts[0].Text != visible.String() {
		t.Fatalf("completed batch turn lost data: deltas=%d done=%v conversation=%+v err=%v", deltas, done, conversation, err)
	}
	after, _, err := service.Store.SyncEvents(before.Sequence, 256)
	if err != nil || after.Sequence-before.Sequence >= 96 {
		t.Fatalf("token transactions were not reduced: %d %v", after.Sequence-before.Sequence, err)
	}
	t.Logf("96 token deltas retained; complete turn used %d sync transactions", after.Sequence-before.Sequence)
}

func TestBatchedTurnJournalFailureDoesNotPublishOrReplayTokens(t *testing.T) {
	service, _, project, board := appSetup(t)
	defer service.Store.Close()
	service.Runner = batchRunnerFunc(func(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`)}); err != nil {
			return err
		}
		// Only this disposable fixture is changed. Make the real journal append
		// fail, then restore it for the owning turn's final error publication.
		path := filepath.Join(service.Store.Root, "conversations", request.SessionID, "events.ndjson")
		if err := os.Rename(path, path+".saved"); err != nil {
			return err
		}
		defer os.Rename(path+".saved", path)
		if err := os.Mkdir(path, 0700); err != nil {
			return err
		}
		defer os.Remove(path)
		if err := emit(tokenOutput("must not be acknowledged")); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return emit(harness.Output{Type: "session"})
		case <-time.After(3 * time.Second):
			return errors.New("failed persistence did not stop the runner")
		}
	})
	card, err := service.Store.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: "write failure", Provider: "codex", Model: "gpt-5.5", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "stream", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	var failure error
	for update := range updates {
		if strings.Contains(string(update.Chunk), "must not be acknowledged") {
			t.Error("failed journal content was exposed to client")
		}
		if update.Err != nil {
			failure = update.Err
		}
	}
	reader := store.New(service.Store.Root)
	defer reader.Close()
	conversation, err := reader.Conversation(card.ID)
	raw, _ := json.Marshal(conversation)
	if err != nil || failure == nil || !strings.Contains(failure.Error(), "events.ndjson") || conversation.Status != "failed" || strings.Contains(string(raw), "must not be acknowledged") {
		t.Fatalf("persistence failure lost/replayed: failure=%v conversation=%s err=%v", failure, raw, err)
	}
}
