//go:build e2e

package topology_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/emptypb"
)

type congestionRun struct {
	ready, emitted chan struct{}
	run, finish    chan struct{}
}
type congestionRunner struct {
	mu   sync.Mutex
	runs map[string]*congestionRun
}

func (r *congestionRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	r.mu.Lock()
	run := r.runs[request.SessionID]
	r.mu.Unlock()
	chunk := func(raw string) error { return emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(raw)}) }
	if err := chunk(`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`); err != nil {
		return err
	}
	if err := chunk(`{"type":"text-start","id":"text"}`); err != nil {
		return err
	}
	run.ready <- struct{}{}
	select {
	case <-run.run:
	case <-ctx.Done():
		return ctx.Err()
	}
	for range 20 {
		for range 32 {
			if err := chunk(`{"type":"text-delta","id":"text","delta":"x"}`); err != nil {
				return err
			}
		}
		if err := emit(harness.Output{Type: "heartbeat"}); err != nil {
			return err
		}
	}
	run.emitted <- struct{}{}
	select {
	case <-run.finish:
	case <-ctx.Done():
		return ctx.Err()
	}
	return chunk(`{"type":"finish"}`)
}

// Real RPC admission, watches, concurrent shared edits, peer exchange and cold
// journal reads under streaming load. Every home, checkout and listener belongs
// to the topology. No external provider or operator daemon participates.
func TestConcurrentTurnsStayResponsiveAcrossRoutes(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(8*time.Minute))
	defer cancel()
	runner := &congestionRunner{runs: map[string]*congestionRun{}}
	var disconnects atomic.Int64
	var stores []*store.Store
	t.Cleanup(func() {
		for _, s := range stores {
			if err := s.Close(); err != nil {
				t.Error(err)
			}
		}
	})
	network := topology.Start(t, topology.GatewayOptions{}, topology.DaemonOptions{Direct: true, API: api.Options{Runner: runner, Catalog: testkit.MockCatalog()}, Tunnel: func(tunnel *link.GatewayClient) {
		tunnel.OnStatus = func(event link.GatewayEvent) {
			if event.State == link.GatewayDisconnected {
				disconnects.Add(1)
			}
		}
	}}, topology.DaemonOptions{})
	daemon, peer := network.Daemons[0], network.Daemons[1]
	stores = []*store.Store{daemon.Store, peer.Store}
	scope := crdt.Revision([]string{daemon.Identity.Issuer(), "github:42"})
	for _, owner := range network.Daemons {
		if _, err := owner.Store.Replica.BindPeerAccount(scope, "github:42", owner.Identity.ID, owner.Identity.Issuer()); err != nil {
			t.Fatal(err)
		}
	}
	phone := topology.StartClient(t, network.Gateway, daemon, "Contention client")
	localConn, err := grpc.NewClient(daemon.Address, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithPerRPCCredentials(localauth.Credentials{Token: daemon.Token}))
	if err != nil {
		t.Fatal(err)
	}
	defer localConn.Close()
	clients := []struct {
		name   string
		turns  int
		client dieterclient.Client
	}{{"local", 8, dieterclient.New(localConn)}, {"direct", 8, dieterclient.New(topology.DialDaemon(t, phone, daemon, topology.Direct))}, {"relay", 16, dieterclient.New(topology.DialDaemon(t, phone, daemon, topology.Tunnel))}}
	created, err := clients[0].client.CreateProject(ctx, &dieterv1.CreateProjectRequest{Mode: "open", Path: testkit.GitRepo(t), Name: "Contention"})
	if err != nil {
		t.Fatal(err)
	}
	var cards []*dieterv1.Card
	for i := range 100 {
		card, err := clients[0].client.CreateCard(ctx, &dieterv1.CreateConversationRequest{ProjectId: created.GetProject().GetId(), BoardId: created.GetBoard().GetId(), Title: fmt.Sprintf("card %d", i), Prompt: "stream", Provider: "mock", Model: "mock", WorkspaceMode: "project", DeferStart: true, Lane: "todo"})
		if err != nil {
			t.Fatal(err)
		}
		cards = append(cards, card)
	}
	offset := 0
	for _, route := range clients {
		t.Run(route.name, func(t *testing.T) {
			selected := cards[offset : offset+route.turns]
			offset += route.turns
			run := &congestionRun{ready: make(chan struct{}, route.turns), emitted: make(chan struct{}, route.turns), run: make(chan struct{}), finish: make(chan struct{})}
			runner.mu.Lock()
			for _, card := range selected {
				runner.runs[card.GetId()] = run
			}
			runner.mu.Unlock()
			// Release gates even on an assertion failure, then join every admitted
			// turn before topology cleanup closes its stores.
			var openRun, openFinish sync.Once
			defer func() {
				openRun.Do(func() { close(run.run) })
				openFinish.Do(func() { close(run.finish) })
				testkit.Eventually(t, 30*time.Second, func() bool {
					for _, card := range selected {
						current, err := daemon.Store.Kanban.ResolveCard(card.GetId())
						leased, leaseErr := daemon.Store.Leases.CardActive(card.GetId())
						if err != nil || leaseErr != nil || leased || model.RuntimeHoldsTurn(current.Runtime) {
							return false
						}
					}
					return true
				}, "active turn remained during cleanup")
			}()
			for _, card := range selected {
				if _, err := route.client.StartCard(ctx, &dieterv1.StartCardRequest{CardId: card.GetId(), ClientId: "contention", CommandId: "start-" + card.GetId()}); err != nil {
					t.Fatal(err)
				}
			}
			for range route.turns {
				select {
				case <-run.ready:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
			}
			watchCtx, stopWatch := context.WithCancel(ctx)
			var watchers sync.WaitGroup
			defer func() { stopWatch(); watchers.Wait() }()
			watchReady := make(chan struct{}, 2)
			var seenSeq atomic.Int64
			conversation, err := route.client.WatchConversation(watchCtx, &dieterv1.WatchConversationRequest{CardId: selected[0].GetId()})
			if err != nil {
				t.Fatal(err)
			}
			watchers.Go(func() {
				first := true
				for {
					frame, err := conversation.Recv()
					if err != nil {
						if watchCtx.Err() == nil {
							t.Error(err)
						}
						return
					}
					seenSeq.Store(frame.GetLastSeq())
					if first {
						watchReady <- struct{}{}
						first = false
					}
				}
			})
			directory, err := route.client.WatchChanges(watchCtx, &dieterv1.ChangesRequest{})
			if err != nil {
				t.Fatal(err)
			}
			watchers.Go(func() {
				first := true
				for {
					_, err := directory.Recv()
					if err != nil {
						if watchCtx.Err() == nil {
							t.Error(err)
						}
						return
					}
					if first {
						watchReady <- struct{}{}
						first = false
					}
				}
			})
			for range 2 {
				select {
				case <-watchReady:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
			}
			probeCtx, stopProbe := context.WithCancel(ctx)
			var probes sync.WaitGroup
			var probeMu sync.Mutex
			var latencies []time.Duration
			probes.Go(func() {
				ticker := time.NewTicker(100 * time.Millisecond)
				defer ticker.Stop()
				for {
					select {
					case <-probeCtx.Done():
						return
					case <-ticker.C:
					}
					started := time.Now()
					if _, err := route.client.Health(probeCtx, &emptypb.Empty{}); err != nil {
						if probeCtx.Err() == nil {
							t.Error(err)
						}
						return
					}
					if _, err := route.client.GetCard(probeCtx, &dieterv1.GetCardRequest{CardId: selected[0].GetId()}); err != nil {
						if probeCtx.Err() == nil {
							t.Error(err)
						}
						return
					}
					probeMu.Lock()
					latencies = append(latencies, time.Since(started))
					probeMu.Unlock()
				}
			})
			defer func() { stopProbe(); probes.Wait() }()
			before := disconnects.Load()
			started := time.Now()
			openRun.Do(func() { close(run.run) })
			if _, err := route.client.RenameCard(ctx, &dieterv1.RenameCardRequest{CardId: selected[0].GetId(), Title: "renamed during streaming"}); err != nil {
				t.Fatal(err)
			}
			syncer := &peersync.PeerSync{Identity: daemon.Identity, Trust: daemon.Trust, Store: daemon.Store}
			if err := syncer.Round(ctx); err != nil {
				t.Fatal(err)
			}
			replicated, err := peer.Store.Kanban.ResolveCard(selected[0].GetId())
			if err != nil || replicated.Title != "renamed during streaming" {
				t.Fatalf("concurrent peer exchange lost card: %s %v", replicated.Title, err)
			}
			for range route.turns {
				select {
				case <-run.emitted:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
			}
			openFinish.Do(func() { close(run.finish) })
			for _, card := range selected {
				testkit.Eventually(t, 30*time.Second, func() bool {
					detail, err := route.client.GetCard(ctx, &dieterv1.GetCardRequest{CardId: card.GetId()})
					return err == nil && detail.GetCard().GetRuntime() == "idle"
				}, "turn did not finish")
				view, err := route.client.GetConversation(ctx, &dieterv1.GetConversationRequest{CardId: card.GetId()})
				if err != nil {
					t.Fatal(err)
				}
				messages := view.GetConversation().GetMessages()
				if len(messages) != 2 || messages[1].GetParts()[0].GetText() != strings.Repeat("x", 640) || view.GetDetail().GetCard().GetResponseSeq() == 0 {
					t.Fatalf("stream lost durable output: %s", card.GetId())
				}
				cold := store.New(daemon.Store.Root)
				c, err := cold.Conversations.Get(card.GetId())
				_ = cold.Close()
				if err != nil || len(c.Messages) != 2 || c.Messages[1].Parts[0].Text != strings.Repeat("x", 640) {
					t.Fatalf("cold replay lost output: %v", err)
				}
				if card == selected[0] {
					testkit.Eventually(t, 10*time.Second, func() bool { return seenSeq.Load() == view.GetConversation().GetLastSeq() }, "watch did not catch up")
					if view.GetDetail().GetCard().GetTitle() != "renamed during streaming" {
						t.Fatal("append overwrote concurrent title")
					}
				}
			}
			stopProbe()
			probes.Wait()
			probeMu.Lock()
			defer probeMu.Unlock()
			if len(latencies) == 0 {
				t.Fatal("no responsiveness probes completed")
			}
			var maximum time.Duration
			for _, latency := range latencies {
				maximum = max(maximum, latency)
			}
			if disconnects.Load() != before {
				t.Fatal("control lane disconnected during streaming")
			}
			t.Logf("route=%s turns=%d tokens=%d elapsed=%s probes=%d maxHealthAndCardLatency=%s", route.name, route.turns, route.turns*640, time.Since(started), len(latencies), maximum)
		})
	}
}
