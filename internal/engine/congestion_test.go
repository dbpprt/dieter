package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

// Bursts have semantic barriers so every turn offers the same number of
// batches. Admission and fixture construction are outside the measured window.
func TestConcurrentTurnWriterCost(t *testing.T) {
	if os.Getenv("DIETER_TEST_CONGESTION") != "1" {
		t.Skip("set DIETER_TEST_CONGESTION=1 for the 100-card concurrent writer qualification")
	}
	for _, turns := range []int{1, 8, 16} {
		t.Run(fmt.Sprint(turns), func(t *testing.T) {
			service, _, project, board := appSetup(t)
			defer service.Store.Close()
			var mu sync.Mutex
			var samples []home.WriterSample
			service.Store.SetWriterObserver(func(sample home.WriterSample) {
				mu.Lock()
				samples = append(samples, sample)
				mu.Unlock()
			})
			ready := make(chan struct{}, turns)
			run := make(chan struct{})
			service.Runner = batchRunnerFunc(func(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
				for _, chunk := range []string{`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`, `{"type":"text-start","id":"text"}`} {
					if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
						return err
					}
				}
				ready <- struct{}{}
				select {
				case <-run:
				case <-ctx.Done():
					return ctx.Err()
				}
				for range 20 {
					for range 32 {
						if err := emit(tokenOutput("x")); err != nil {
							return err
						}
					}
					if err := emit(harness.Output{Type: "heartbeat"}); err != nil {
						return err
					}
				}
				return emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(`{"type":"finish"}`)})
			})
			var cards []model.Card
			for range 100 {
				card, err := service.Store.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "contention", Provider: "codex", Model: "gpt-5.5", WorkspaceMode: model.WorkspaceModeProject})
				if err != nil {
					t.Fatal(err)
				}
				cards = append(cards, card)
			}
			var drains sync.WaitGroup
			for _, card := range cards[:turns] {
				updates, err := service.StartCard(card.ID, "stream", "", "", "")
				if err != nil {
					t.Fatal(err)
				}
				drains.Go(func() {
					for update := range updates {
						if update.Err != nil {
							t.Error(update.Err)
						}
					}
				})
			}
			for range turns {
				<-ready
			}
			mu.Lock()
			samples = nil
			mu.Unlock()
			started := time.Now()
			close(run)
			drains.Wait()
			elapsed := time.Since(started)
			for _, card := range cards[:turns] {
				c, err := service.Store.Conversations.Get(card.ID)
				if err != nil || c.Status != "idle" || len(c.Messages) != 2 || c.Messages[1].Parts[0].Text != strings.Repeat("x", 640) {
					t.Fatalf("lost stream: card=%s status=%s err=%v", card.ID, c.Status, err)
				}
				current, err := service.Store.Kanban.ResolveCard(card.ID)
				if err != nil || current.Runtime != "idle" || current.ResponseSeq == 0 {
					t.Fatalf("lost completion: %+v %v", current, err)
				}
			}
			mu.Lock()
			defer mu.Unlock()
			waits, held := make([]time.Duration, 0, len(samples)), make([]time.Duration, 0, len(samples))
			for _, sample := range samples {
				if sample.Err != nil {
					t.Error(sample.Err)
				}
				waits = append(waits, sample.Wait)
				held = append(held, sample.Held)
			}
			sort.Slice(waits, func(i, j int) bool { return waits[i] < waits[j] })
			sort.Slice(held, func(i, j int) bool { return held[i] < held[j] })
			t.Logf("turns=%d tokens=%d elapsed=%s writerAdmissions=%d waitP99=%s holdP99=%s", turns, turns*640, elapsed, len(samples), waits[(len(waits)-1)*99/100], held[(len(held)-1)*99/100])
		})
	}
}
