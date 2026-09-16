package server

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/proto"
)

// Opt-in soak: DIETER_SYNC_SOAK=30m go test ./internal/server -run
// TestSyncLargeWorkspaceSoak -count=1 -timeout=40m -v. Every file and listener
// belongs to this test; no enrolled machine or operator daemon is involved.
func TestSyncLargeWorkspaceSoak(t *testing.T) {
	durationText := os.Getenv("DIETER_SYNC_SOAK")
	if durationText == "" {
		t.Skip("set DIETER_SYNC_SOAK to run sustained large-history validation")
	}
	duration, err := time.ParseDuration(durationText)
	if err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	var hot []model.Card
	for p := range 8 {
		project, err := data.CreateProject(store.CreateProjectInput{Name: fmt.Sprintf("Project %d", p), Path: testRepository(t)})
		if err != nil {
			t.Fatal(err)
		}
		for c := range 20 {
			card, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: fmt.Sprintf("Chat %d", c)})
			if err != nil {
				t.Fatal(err)
			}
			if c == 0 && p < 4 {
				hot = append(hot, card)
			}
		}
	}
	// Old-format, large snapshots exercise migration-free recovery as well as the
	// warm append path. Each authoritative journal is retained throughout soak.
	for _, card := range hot {
		if _, err := data.UpdateCardCache(card.ID, store.CardCacheInput{Runtime: "running"}); err != nil {
			t.Fatal(err)
		}
		conversation := model.Conversation{ProjectionVersion: 5, CardID: card.ID, Status: "running"}
		var journal strings.Builder
		for i := range 100 {
			message := model.UIMessage{ID: fmt.Sprintf("m%d", i), Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: strings.Repeat("h", 256<<10)}}}
			conversation.Messages = append(conversation.Messages, message)
			raw, _ := json.Marshal(message)
			line, _ := json.Marshal(model.ConversationEvent{Seq: int64(i + 1), Type: "user-message", Data: raw, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano)})
			journal.Write(line)
			journal.WriteByte('\n')
		}
		conversation.LastSeq = 100
		dir := filepath.Join(data.Root, "conversations", card.ID)
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		raw, _ := json.Marshal(conversation)
		if err := os.WriteFile(filepath.Join(dir, "snapshot.json"), raw, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "events.ndjson"), []byte(journal.String()), 0600); err != nil {
			t.Fatal(err)
		}
	}
	api := &grpcAPI{server: NewWithRunner(data, nil, &fakeRunner{})}
	start := time.Now()
	if _, err := api.globalSnapshot(0, 0, nil); err != nil {
		t.Fatal(err)
	}
	t.Logf("cold metadata: %s; 8 projects, 160 chats, four 25 MiB histories", time.Since(start))
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	var group sync.WaitGroup
	var mu sync.Mutex
	var appendTimes, firstTimes []time.Duration
	acknowledged := make(map[string]int)
	var frames, resumes int
	var maxFrame int
	var maxGap time.Duration
	failures := make(chan error, 8)
	baselineGoroutines := runtime.NumGoroutine()
	group.Add(1)
	go func() {
		defer group.Done()
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				mu.Lock()
				appends, reads := len(appendTimes), append([]time.Duration(nil), firstTimes...)
				connections, count, gap := resumes, frames, maxGap
				mu.Unlock()
				var memory runtime.MemStats
				runtime.ReadMemStats(&memory)
				t.Logf("progress elapsed=%s appends=%d reconnects=%d frames=%d first projection p95=%s maxGap=%s heapMiB=%d goroutines=%d", time.Since(start).Round(time.Second), appends, connections, count, syncLoadPercentile(reads, 95), gap, memory.HeapAlloc>>20, runtime.NumGoroutine())
			}
		}
	}()
	for _, card := range hot {
		group.Add(1)
		go func() {
			defer group.Done()
			previousStart := time.Now()
			for ctx.Err() == nil {
				rate := []int{1, 10, 20}[min(2, int(time.Since(start)/(duration/3)))]
				wait := time.NewTimer(max(time.Duration(0), time.Second/time.Duration(rate)-time.Since(previousStart)))
				select {
				case <-ctx.Done():
					wait.Stop()
					return
				case <-wait.C:
				}
				began := time.Now()
				previousStart = began
				_, _, err := data.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"small streamed text "}`))
				if err != nil {
					failures <- err
					return
				}
				mu.Lock()
				appendTimes = append(appendTimes, time.Since(began))
				acknowledged[card.ID]++
				mu.Unlock()
			}
		}()
	}
	for range 4 {
		group.Add(1)
		go func() {
			defer group.Done()
			var after *dieterv1.SyncCursor
			for ctx.Err() == nil {
				// At least 100 resume cycles in a 30-minute run; short runs stress them more.
				life := max(500*time.Millisecond, duration/120)
				streamCtx, stop := context.WithTimeout(ctx, life)
				began := time.Now()
				last := began
				first := true
				err := api.watchSync(streamCtx, &dieterv1.SyncRequest{ProtocolVersion: 1, After: after, HeartbeatMs: 1000, ConversationLimit: 30, RecentConversationLimit: 8}, func(frame *dieterv1.SyncFrame) error {
					now := time.Now()
					mu.Lock()
					defer mu.Unlock()
					frames++
					maxFrame = max(maxFrame, proto.Size(frame))
					maxGap = max(maxGap, now.Sub(last))
					last = now
					if first && !frame.TransportOnly {
						firstTimes = append(firstTimes, now.Sub(began))
						first = false
					}
					if frame.Cursor != nil && !frame.Heartbeat {
						after = proto.Clone(frame.Cursor).(*dieterv1.SyncCursor)
					}
					return nil
				})
				stop()
				if err != nil && streamCtx.Err() == nil {
					failures <- err
					return
				}
				mu.Lock()
				resumes++
				mu.Unlock()
			}
		}()
	}
	group.Wait()
	close(failures)
	for err := range failures {
		t.Error(err)
	}
	t.Logf("elapsed=%s appends=%d append p50=%s p95=%s p99=%s; reconnects=%d frames=%d first projection p95=%s max=%s; max frame=%d bytes max frame gap=%s", duration, len(appendTimes), syncLoadPercentile(appendTimes, 50), syncLoadPercentile(appendTimes, 95), syncLoadPercentile(appendTimes, 99), resumes, frames, syncLoadPercentile(firstTimes, 95), syncLoadPercentile(firstTimes, 100), maxFrame, maxGap)
	if syncLoadPercentile(firstTimes, 95) > time.Second {
		t.Error("warm metadata p95 exceeds one second")
	}
	if maxFrame > maxSyncFrameBytes {
		t.Error("frame exceeds byte budget")
	}
	if maxGap > 3*time.Second {
		t.Error("sync frame gap exceeds three seconds")
	}
	if runtime.NumGoroutine() > baselineGoroutines+32 {
		t.Error("reconnect cycles accumulated background goroutines")
	}
	// Reopen with empty in-memory caches, then verify every acknowledged delta.
	for _, card := range hot {
		fresh, err := store.New(data.Root).Conversation(card.ID)
		if err != nil {
			t.Fatal(err)
		}
		if fresh.LastSeq != int64(100+acknowledged[card.ID]) {
			t.Fatalf("%s recovered sequence %d; expected %d acknowledged events", card.ID, fresh.LastSeq, 100+acknowledged[card.ID])
		}
		var streamedText strings.Builder
		for _, message := range fresh.Messages[100:] {
			for _, part := range message.Parts {
				if part.Type == "text" {
					streamedText.WriteString(part.Text)
				}
			}
		}
		if streamedText.String() != strings.Repeat("small streamed text ", acknowledged[card.ID]) {
			t.Fatalf("%s recovered text does not match all acknowledged deltas", card.ID)
		}
	}
}

func syncLoadPercentile(values []time.Duration, p int) time.Duration {
	if len(values) == 0 {
		return 0
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	return values[(len(values)-1)*p/100]
}
