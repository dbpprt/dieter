package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestRetryWhileStoreBusyRetriesOnlyBoundedBusyWrites(t *testing.T) {
	busy := fmt.Errorf("%w: %w", store.ErrWriterBusy, context.DeadlineExceeded)
	attempts := 0
	if err := retryWhileStoreBusy(context.Background(), func() error {
		attempts++
		if attempts < 3 {
			return busy
		}
		return nil
	}); err != nil || attempts != 3 {
		t.Fatalf("recovered write err=%v attempts=%d", err, attempts)
	}
	attempts = 0
	if err := retryWhileStoreBusy(context.Background(), func() error { attempts++; return busy }); !errors.Is(err, store.ErrWriterBusy) || attempts != storeBusyWriteAttempts {
		t.Fatalf("persistent busy err=%v attempts=%d", err, attempts)
	}
	attempts = 0
	failure := errors.New("disk full")
	if err := retryWhileStoreBusy(context.Background(), func() error { attempts++; return failure }); !errors.Is(err, failure) || attempts != 1 {
		t.Fatalf("uncertain write was retried: err=%v attempts=%d", err, attempts)
	}
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	attempts = 0
	if err := retryWhileStoreBusy(canceled, func() error { attempts++; return busy }); !errors.Is(err, store.ErrWriterBusy) || attempts != 1 {
		t.Fatalf("canceled turn kept retrying: err=%v attempts=%d", err, attempts)
	}
}

// A worker calls back into the daemon for background processes. While the
// daemon answers, it cannot read the worker's queued heartbeats.
type backgroundProcessCallRunner struct {
	started chan struct{}
}

func (runner backgroundProcessCallRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	if err := emit(harness.Output{Type: "heartbeat"}); err != nil {
		return err
	}
	close(runner.started)
	if _, err := request.BackgroundProcess(ctx, harness.ProcessCall{ID: "call", Operation: "start"}); err != nil {
		return err
	}
	for _, chunk := range []string{`{"type":"start","messageId":"assistant"}`, `{"type":"text-start","id":"t"}`, `{"type":"text-delta","id":"t","delta":"Started."}`, `{"type":"text-end","id":"t"}`, `{"type":"finish"}`} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return nil
}

func TestWatchdogDoesNotBlameWorkerForDaemonHostWork(t *testing.T) {
	service, _, project, board := appSetup(t)
	runner := backgroundProcessCallRunner{started: make(chan struct{})}
	service.Runner = runner
	answering := make(chan struct{})
	answer := make(chan struct{})
	service.BackgroundProcesses = func(ctx context.Context, _ string, _ harness.ProcessCall) (json.RawMessage, error) {
		close(answering)
		select {
		case <-answer:
			return json.RawMessage(`{"id":"exec"}`), nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Host work", Prompt: "start a build", Provider: "codex", Model: "gpt-5.5", DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
	if err != nil {
		t.Fatal(err)
	}
	<-runner.started
	<-answering
	// Well past the heartbeat timeout, but the daemon is still answering.
	if reconciled := service.ReconcileStalledTurns(time.Now().Add(workerHeartbeatTimeout + time.Hour)); len(reconciled) != 0 {
		t.Fatalf("host work was treated as worker silence: %v", reconciled)
	}
	close(answer)
	var terminal TurnUpdate
	for update := range updates {
		if update.Done {
			terminal = update
		}
	}
	if terminal.Err != nil {
		t.Fatalf("turn failed: %v", terminal.Err)
	}
	conversation, err := service.Store.Conversation(card.ID)
	if err != nil || conversation.Status != "idle" {
		t.Fatalf("conversation status=%q err=%v", conversation.Status, err)
	}
}
