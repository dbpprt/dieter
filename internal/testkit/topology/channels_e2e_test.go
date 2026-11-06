//go:build e2e

package topology_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/engine"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
)

func isFault(err error, kind fault.Kind) bool {
	got, ok := fault.KindOf(err)
	return ok && got == kind
}

type channelMachine struct {
	daemon *topology.Daemon
	app    *engine.Service
	runner *testkit.FakeRunner
}

// startChannelMachine runs an account daemon whose engine the test drives. A
// turn whose prompt says "write:PATH" edits PATH and holds until release.
func startChannelMachine(t *testing.T, g *topology.Gateway, name string, release chan struct{}) channelMachine {
	t.Helper()
	identity := topology.Machine(t, g, name, 42)
	data := store.New(identity.Root)
	runner := &testkit.FakeRunner{Script: func(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
		if _, path, ok := strings.Cut(request.Prompt, "write:"); ok {
			input, _ := json.Marshal(map[string]any{"type": "tool-input-available", "toolCallId": "edit-1", "toolName": "edit", "input": map[string]string{"file_path": filepath.Join(request.ProjectPath, path)}})
			if err := emit(harness.Output{Type: "chunk", Chunk: input}); err != nil {
				return err
			}
			select {
			case <-release:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		return testkit.EmitText(emit, "done", testkit.FakeThreadID)
	}}
	app := engine.NewWithOptions(data, engine.Options{Runner: runner, Catalog: testkit.MockCatalog()})
	daemon := topology.StartDaemon(t, g, topology.DaemonOptions{Name: name, Identity: identity, Store: data, API: api.Options{App: app, Runner: runner, Catalog: testkit.MockCatalog()}})
	scope := crdt.Revision([]string{identity.Issuer(), "github:42"})
	if _, err := data.Replica.BindPeerAccount(scope, "github:42", identity.ID, identity.Issuer()); err != nil {
		t.Fatal(err)
	}
	return channelMachine{daemon: daemon, app: app, runner: runner}
}

// A project channel spans the account's machines: a person's post on B to a
// card on A reaches A through peer sync, A wakes the card and publishes the
// receipt, B shows how it arrived and A's claims as advisory. The gateway
// relays the sync but never sees a message.
func TestAgentChannelsSpanMachinesAndTheGatewaySeesNoMessage(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(2*time.Minute))
	defer cancel()
	traffic := &recorder{}
	g := topology.StartGateway(t, topology.GatewayOptions{Listen: traffic.wrap})
	release := make(chan struct{})
	a, b := startChannelMachine(t, g, "Channel desk A", release), startChannelMachine(t, g, "Channel desk B", release)
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	sync := func() {
		t.Helper()
		syncer := &peersync.PeerSync{Identity: a.daemon.Identity, Trust: a.daemon.Trust, Store: a.daemon.Store}
		if err := syncer.Round(ctx); err != nil {
			t.Fatal(err)
		}
	}

	project, err := a.daemon.Store.Kanban.CreateProject(kanban.CreateProjectInput{Path: testkit.CheckoutDir(t), Name: "Shared checkout"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := a.daemon.Store.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Work", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	card := func(title string) model.Card {
		t.Helper()
		created, err := a.app.CreateCard(ctx, engine.CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: title, Prompt: "Work", Provider: "mock", Model: "mock"})
		if err != nil {
			t.Fatal(err)
		}
		return created
	}
	idle, writer := card("Idle on A"), card("Writer on A")
	if _, err := a.app.SetChannelSetting("global", "", "on"); err != nil {
		t.Fatal(err)
	}
	updates, err := a.app.StartCard(writer.ID, "hold write:src/shared.go", "mock", "mock", "")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for range updates {
		}
	}()
	testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool { return len(a.app.ChannelClaims(project.ID)) == 1 }, "the writer's claim")
	a.app.SyncChannels()
	sync()

	// B sees A's card as a remote member and A's claim as advisory.
	b.app.SyncChannels()
	claims := b.app.ChannelClaims(project.ID)
	if len(claims) != 1 || !claims[0].Remote || claims[0].Path != "src/shared.go" || claims[0].CardID != writer.ID || claims[0].Daemon == "" {
		t.Fatalf("B's claims = %+v", claims)
	}
	summaries, err := b.app.ChannelSummaries(ctx)
	if err != nil {
		t.Fatal(err)
	}
	remote := false
	for _, summary := range summaries {
		for _, member := range summary.Members {
			remote = remote || summary.Project.ID == project.ID && member.Card.ID == idle.ID && member.Remote
		}
	}
	if !remote {
		t.Fatalf("B's channels do not list A's card as a remote member: %+v", summaries)
	}

	// A person on B messages the idle card on A and asks to wake it.
	body := canary(t, "channel-message")
	posted, err := b.app.PostChannelMessage(ctx, engine.ChannelCaller{DeviceID: "dv_phone"}, engine.ChannelPost{ProjectID: project.ID, To: []string{idle.ID}, Wake: true, Body: body})
	if err != nil {
		t.Fatal(err)
	}
	if b.runner.Count() != 0 {
		t.Fatal("B started a turn for a card it does not own")
	}
	// B can read the card's inbox but leaves delivery to A.
	if pending, err := b.app.ChannelInbox(engine.ChannelCaller{}, idle.ID, true); err != nil || len(pending) != 1 || pending[0].ID != posted.ID {
		t.Fatalf("B's peek = %+v, %v", pending, err)
	}
	if _, err := b.app.ChannelInbox(engine.ChannelCaller{}, idle.ID, false); !isFault(err, fault.FailedPrecondition) {
		t.Fatalf("B consumed A's inbox: %v", err)
	}
	sync()
	a.app.SyncChannels()
	testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool {
		for _, request := range a.runner.Requests() {
			if strings.Contains(request.Prompt, body) && strings.Contains(request.Prompt, "woke you") {
				return true
			}
		}
		return false
	}, "A to wake the card with B's message")
	testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool {
		message, err := a.daemon.Store.Channels.Message(project.ID, posted.ID)
		return err == nil && len(message.Deliveries) == 1 && message.Deliveries[0].Mode == model.ChannelDeliveryWoke
	}, "A to record the wake")

	// A publishes the card's receipt; B shows how the message arrived.
	a.app.SyncChannels()
	sync()
	b.app.SyncChannels()
	delivered, err := b.daemon.Store.Channels.Message(project.ID, posted.ID)
	if err != nil || len(delivered.Deliveries) != 1 || delivered.Deliveries[0].CardID != idle.ID || delivered.Deliveries[0].Mode != model.ChannelDeliveryWoke {
		t.Fatalf("B's message = %+v, %v", delivered, err)
	}

	// The released claim disappears on B.
	close(release)
	testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool { return len(a.app.ChannelClaims(project.ID)) == 0 }, "the writer's release")
	a.app.SyncChannels()
	sync()
	if claims := b.app.ChannelClaims(project.ID); len(claims) != 0 {
		t.Fatalf("B still shows released claims: %+v", claims)
	}
	settle(t, a.daemon.Store)

	// Positive control: the recorder sees what the gateway reads, such as
	// machine names.
	if !traffic.contains("Channel desk B") {
		t.Fatal("the recorder captured no gateway traffic")
	}
	if traffic.contains(body) {
		t.Error("the gateway saw the channel message on the wire")
	}
	err = filepath.WalkDir(g.Config.Root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		defer file.Close()
		raw, err := io.ReadAll(file)
		if err != nil {
			return err
		}
		if bytes.Contains(raw, []byte(body)) {
			t.Errorf("the gateway stored the channel message in %s", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
