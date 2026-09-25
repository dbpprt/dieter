package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/protocol"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/shirou/gopsutil/v4/process"
	"google.golang.org/protobuf/proto"
)

// Opt-in steady-state process counters: fixture setup and cold projections are
// outside the sample. This covers eight real projection subscriptions, not the
// network stack or an operator daemon with unknown concurrent work.
func TestIdleSubscriptionProcessCost(t *testing.T) {
	setting := os.Getenv("DIETER_IDLE_SYNC")
	if setting == "" {
		t.Skip("set DIETER_IDLE_SYNC=30s for idle CPU/RSS evidence")
	}
	duration, err := time.ParseDuration(setting)
	if err != nil || duration < time.Second {
		t.Fatal("DIETER_IDLE_SYNC must be at least one second")
	}
	api, card := performanceConversation(t, nil)
	ctx, cancel := context.WithCancel(t.Context())
	var group sync.WaitGroup
	var initial atomic.Int64
	var active atomic.Int64
	for range 4 {
		group.Add(2)
		go func() {
			defer group.Done()
			active.Add(1)
			defer active.Add(-1)
			_ = api.watchConversation(ctx, &dieterv1.WatchConversationRequest{CardId: card.ID}, func(*dieterv1.ConversationUpdate) error { initial.Add(1); return nil })
		}()
		go func() {
			defer group.Done()
			active.Add(1)
			defer active.Add(-1)
			_ = api.watchSync(ctx, &dieterv1.SyncRequest{ProtocolVersion: protocol.Number}, func(frame *dieterv1.SyncFrame) error {
				if frame.GetSnapshot() != nil {
					initial.Add(1)
				}
				return nil
			})
		}()
	}
	defer func() { cancel(); group.Wait() }()
	deadline := time.Now().Add(5 * time.Second)
	for initial.Load() < 8 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if initial.Load() != 8 || active.Load() != 8 {
		t.Fatal("subscriptions did not become ready")
	}
	p, err := process.NewProcess(int32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	before, err := p.Times()
	if err != nil {
		t.Fatal(err)
	}
	resident, err := p.MemoryInfo()
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	time.Sleep(duration)
	if active.Load() != 8 {
		t.Fatal("a subscription exited during the idle measurement")
	}
	after, err := p.Times()
	if err != nil {
		t.Fatal(err)
	}
	end, err := p.MemoryInfo()
	if err != nil {
		t.Fatal(err)
	}
	cpu := after.User + after.System - before.User - before.System
	t.Logf("idle subscriptions=8 wall=%s cpuSeconds=%.6f oneCorePercent=%.3f rssStartMiB=%.2f rssEndMiB=%.2f", time.Since(started), cpu, 100*cpu/time.Since(started).Seconds(), float64(resident.RSS)/(1<<20), float64(end.RSS)/(1<<20))
	if initial.Load() != 8 {
		t.Fatal("idle subscriptions rebuilt visible content")
	}
}

func TestSyncHydratesOnlyOwnerBeforeApplyingRecentBudget(t *testing.T) {
	var logs bytes.Buffer
	api, localCard := performanceConversation(t, slog.New(slog.NewTextHandler(&logs, nil)))
	local := api.server.store
	identity, err := local.BindPeerAccount("performance", "subject", "local", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	remoteAPI, remoteCard := performanceConversation(t, nil)
	remote := remoteAPI.server.store
	if _, err := remote.BindPeerAccount("performance", "subject", "remote", "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	if _, err := remote.UpdateCardCache(remoteCard.ID, store.CardCacheInput{Runtime: "running"}); err != nil {
		t.Fatal(err)
	}
	data, err := remote.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	records := data.Sorted()
	for len(records) > 0 {
		n := min(peerstore.PageSize, len(records))
		if err := local.MergePeerRecords(identity, records[:n]); err != nil {
			t.Fatal(err)
		}
		records = records[n:]
	}
	projection, err := api.globalSnapshot(30, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(projection.snapshot.State.Chats) != 2 || len(projection.snapshot.Conversations) != 1 || projection.snapshot.Conversations[0].Detail.Card.Id != localCard.ID {
		t.Fatalf("remote metadata must remain visible without consuming local hydration budget: %v", projection.snapshot)
	}
	if logs.Len() != 0 {
		t.Fatalf("normal remote ownership produced warnings: %s", &logs)
	}
}

func performanceConversation(tb testing.TB, logger *slog.Logger) (*grpcAPI, model.Card) {
	tb.Helper()
	repo := tb.TempDir()
	if err := os.Mkdir(filepath.Join(repo, ".git"), 0700); err != nil {
		tb.Fatal(err)
	}
	data := store.New(tb.TempDir())
	tb.Cleanup(func() { _ = data.Close() })
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Performance", Path: repo})
	if err != nil {
		tb.Fatal(err)
	}
	card, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Bounded transcript"})
	if err != nil {
		tb.Fatal(err)
	}
	messages := make([]model.UIMessage, 30)
	for i := range messages {
		messages[i] = model.UIMessage{ID: string(rune('a' + i)), Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: strings.Repeat("text ", 1600)}}}
	}
	if _, err := data.InitializeForkConversation(card.ID, messages); err != nil {
		tb.Fatal(err)
	}
	return &grpcAPI{server: NewWithRunner(data, logger, &fakeRunner{})}, card
}

func TestIdleConversationWatchBuildsOnlyOnce(t *testing.T) {
	var logs bytes.Buffer
	api, card := performanceConversation(t, slog.New(slog.NewJSONHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	ctx, cancel := context.WithTimeout(context.Background(), 550*time.Millisecond)
	defer cancel()
	frames := 0
	err := api.watchConversation(ctx, &dieterv1.WatchConversationRequest{CardId: card.ID, IntervalMs: 100}, func(*dieterv1.ConversationUpdate) error {
		frames++
		return nil
	})
	if err != context.DeadlineExceeded || frames != 1 {
		t.Fatalf("idle watch: frames=%d err=%v", frames, err)
	}
	var metrics struct {
		Polls          int `json:"polls"`
		SnapshotBuilds int `json:"snapshotBuilds"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(logs.Bytes()), &metrics); err != nil {
		t.Fatal(err)
	}
	if metrics.Polls != 1 || metrics.SnapshotBuilds != 1 {
		t.Fatalf("idle work was not eliminated: %+v", metrics)
	}
}

func TestResumedConversationAcknowledgesFreshMetadataWithoutResendingMessages(t *testing.T) {
	api, card := performanceConversation(t, nil)
	initial, err := api.conversationSnapshot(card.ID, 30, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := api.server.store.RenameCard(card.ID, "Updated metadata"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	frames := 0
	err = api.watchConversation(ctx, &dieterv1.WatchConversationRequest{CardId: card.ID, Limit: 30, AfterSeq: initial.Conversation.LastSeq}, func(update *dieterv1.ConversationUpdate) error {
		frames++
		if update.Snapshot != nil || len(update.ChangedMessages) != 0 || len(update.RemovedMessageIds) != 0 {
			t.Fatal("resumed acknowledgement retransmitted unchanged transcript")
		}
		if update.LastSeq != initial.Conversation.LastSeq || update.Status != initial.Conversation.Status || update.GetDetail().GetCard().GetTitle() != "Updated metadata" || !proto.Equal(update.Page, initial.Page) {
			t.Fatalf("incomplete freshness acknowledgement: %v", update)
		}
		cancel()
		return nil
	})
	if err != context.Canceled || frames != 1 {
		t.Fatalf("resume waited for a future mutation: frames=%d err=%v", frames, err)
	}
}

func TestConversationWatchRefreshesMetadataAndCrossProcessTranscript(t *testing.T) {
	api, card := performanceConversation(t, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	other := store.New(api.server.store.Root)
	defer other.Close()
	frames := 0
	err := api.watchConversation(ctx, &dieterv1.WatchConversationRequest{CardId: card.ID, IntervalMs: 100}, func(update *dieterv1.ConversationUpdate) error {
		frames++
		switch frames {
		case 1:
			_, err := other.RenameCard(card.ID, "Updated metadata")
			return err
		case 2:
			if update.GetDetail().GetCard().GetTitle() != "Updated metadata" {
				t.Fatal("metadata-only update was skipped")
			}
			_, err := other.StartConversationTurn(card.ID, "turn", "new-message", "A new message")
			return err
		case 3:
			if len(update.ChangedMessages) != 1 || update.ChangedMessages[0].Id != "new-message" {
				t.Fatal("cross-process message was skipped")
			}
			cancel()
		}
		return nil
	})
	if err != context.Canceled || frames != 3 {
		t.Fatalf("watch: frames=%d err=%v", frames, err)
	}
}

func TestConversationWatchSkipsTranscriptBuildForOtherCardMetadata(t *testing.T) {
	var logs bytes.Buffer
	api, card := performanceConversation(t, slog.New(slog.NewJSONHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	other := store.New(api.server.store.Root)
	defer other.Close()
	unrelated, err := other.CreateChat(store.CreateCardInput{Project: card.ProjectID, Title: "Other card"})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	ready := make(chan struct{})
	done := make(chan error, 1)
	frames := 0
	go func() {
		done <- api.watchConversation(ctx, &dieterv1.WatchConversationRequest{CardId: card.ID, IntervalMs: 100}, func(update *dieterv1.ConversationUpdate) error {
			frames++
			if frames == 1 {
				close(ready)
			} else {
				if update.GetDetail().GetCard().GetTitle() != "Updated metadata" {
					return fmt.Errorf("selected metadata was lost")
				}
				cancel()
			}
			return nil
		})
	}()
	select {
	case <-ready:
	case <-ctx.Done():
		t.Fatal("watch did not start")
	}
	for range 2 {
		if _, err := other.RenameCard(unrelated.ID, "Updated metadata"); err != nil {
			cancel()
			<-done
			t.Fatal(err)
		}
		// Give the real notification/debounce path a separate delivery window.
		time.Sleep(350 * time.Millisecond)
	}
	if _, err := other.RenameCard(card.ID, "Updated metadata"); err != nil {
		cancel()
		<-done
		t.Fatal(err)
	}
	if err := <-done; err != context.Canceled || frames != 2 {
		t.Fatalf("frames=%d error=%v", frames, err)
	}
	var metrics struct {
		Polls          int `json:"polls"`
		SnapshotBuilds int `json:"snapshotBuilds"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(logs.Bytes()), &metrics); err != nil {
		t.Fatal(err)
	}
	if metrics.Polls < 3 || metrics.SnapshotBuilds != 2 {
		t.Fatalf("unrelated metadata rebuilt the selected transcript: %+v", metrics)
	}
}

func TestConversationWatchRevisionIgnoresUnrelatedTokens(t *testing.T) {
	api, card := performanceConversation(t, nil)
	other, err := api.server.store.CreateChat(store.CreateCardInput{Project: card.ProjectID, Title: "other stream"})
	if err != nil {
		t.Fatal(err)
	}
	before, _, err := api.conversationWatchRevision(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	for range 5 {
		if _, _, err := api.server.store.AppendUIChunk(other.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"token"}`)); err != nil {
			t.Fatal(err)
		}
	}
	after, pending, err := api.conversationWatchRevision(card.ID)
	if err != nil || pending || after != before {
		t.Fatalf("unrelated tokens invalidated selected transcript: %+v %+v %v", before, after, err)
	}
	if _, err := api.server.store.RenameCard(card.ID, "Updated metadata"); err != nil {
		t.Fatal(err)
	}
	after, _, err = api.conversationWatchRevision(card.ID)
	if err != nil || after == before {
		t.Fatal("metadata no longer invalidates selected transcript")
	}
}

func TestConversationCommitDeliveryDoesNotWaitForRecoveryPoll(t *testing.T) {
	api, card := performanceConversation(t, nil)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	frames := 0
	var committed time.Time
	err := api.watchConversation(ctx, &dieterv1.WatchConversationRequest{CardId: card.ID}, func(update *dieterv1.ConversationUpdate) error {
		frames++
		if frames == 1 {
			_, err := api.server.store.RenameCard(card.ID, "Updated metadata")
			committed = time.Now()
			return err
		}
		t.Logf("commit-to-frame=%s", time.Since(committed))
		if update.GetDetail().GetCard().GetTitle() != "Updated metadata" {
			t.Fatal("commit notification delivered stale metadata")
		}
		cancel()
		return nil
	})
	if err != context.Canceled || frames != 2 {
		t.Fatalf("commit notification was lost: frames=%d error=%v", frames, err)
	}
}

// Matched warm workloads, with setup outside the timer. snapshot is the former
// idle poll (including serialization); revision is the unchanged fast path.
func BenchmarkConversationIdleRead(b *testing.B) {
	api, card := performanceConversation(b, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if _, err := api.conversationSnapshot(card.ID, 30, nil); err != nil {
		b.Fatal(err)
	}
	b.Run("snapshot", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			snapshot, err := api.conversationSnapshot(card.ID, 30, nil)
			if err != nil {
				b.Fatal(err)
			}
			if _, err := (proto.MarshalOptions{Deterministic: true}).Marshal(snapshot); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("revision", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			if _, _, err := api.conversationWatchRevision(card.ID); err != nil {
				b.Fatal(err)
			}
		}
	})
}

// Windowed snapshots still need the durable conversation projection. Track a
// tool-heavy fork as well as the small text-only fixture so historical payload
// cloning and preview work cannot disappear behind a 30-message output limit.
func BenchmarkToolHeavyConversationSnapshot(b *testing.B) {
	for _, count := range []int{30, 300} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			api, card := performanceToolConversation(b, count)
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				result, err := api.conversationSnapshot(card.ID, 30, nil)
				if err != nil {
					b.Fatal(err)
				}
				if len(result.GetConversation().GetMessages()) != 30 {
					b.Fatal("missing window")
				}
			}
		})
	}
}

func performanceToolConversation(tb testing.TB, count int) (*grpcAPI, model.Card) {
	tb.Helper()
	api, card := performanceConversation(tb, slog.New(slog.NewTextHandler(io.Discard, nil)))
	messages := make([]model.UIMessage, count)
	for i := range messages {
		output, _ := json.Marshal(map[string]any{"index": i, "content": strings.Repeat("output ", 2048)})
		messages[i] = model.UIMessage{ID: fmt.Sprint(i), Role: "assistant", Parts: []model.UIMessagePart{
			{Type: "tool", ToolCallID: fmt.Sprint(i), ToolName: "exec", State: "output-available", Output: output},
		}}
	}
	if _, err := api.server.store.InitializeForkConversation(card.ID, messages); err != nil {
		tb.Fatal(err)
	}
	if _, err := api.conversationSnapshot(card.ID, 30, nil); err != nil {
		tb.Fatal(err)
	}
	return api, card
}

// Same selected detail comparison used when another card changes the shared
// metadata cursor. Compare with BenchmarkToolHeavyConversationSnapshot/300;
// both exclude the common revision lookup and fixture setup.
func BenchmarkToolHeavyConversationMetadata(b *testing.B) {
	api, card := performanceToolConversation(b, 300)
	snapshot, err := api.conversationSnapshot(card.ID, 30, nil)
	if err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	for b.Loop() {
		detail, err := api.server.store.CardDetail(card.ID)
		if err != nil {
			b.Fatal(err)
		}
		if !proto.Equal(protoCardDetail(detail), snapshot.Detail) {
			b.Fatal("changed detail")
		}
	}
}
