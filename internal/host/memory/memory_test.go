package memory

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"

	"github.com/dbpprt/dieter/internal/engine"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	storememory "github.com/dbpprt/dieter/internal/store/memory"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

// memoryStore is an enrolled store with a Git project that has memory on.
func memoryStore(t *testing.T, daemonID string) (*store.Store, model.Project) {
	t.Helper()
	data := testkit.PeerStore(t, daemonID)
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Atlas", Path: testkit.GitRepo(t), BaseBranch: "main", InitialBoardName: "Delivery"})
	if err != nil {
		t.Fatal(err)
	}
	if project, err = data.Kanban.SetProjectMemory(project.ID, true); err != nil {
		t.Fatal(err)
	}
	return data, project
}

func newService(t *testing.T, data *store.Store, app *engine.Service, name string) *Service {
	t.Helper()
	service := New(Options{Store: data, App: app, Name: name})
	if app != nil {
		app.Memory = service
	}
	t.Cleanup(func() { _ = service.index.Close() })
	return service
}

// runService runs the background work until the test ends.
func runService(t *testing.T, service *Service) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		service.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
}

// engineFor is an engine on runner. When the test ends (after the memory
// service stopped) it waits for every turn to settle and flushes
// conversation checkpoints, so the home can be removed.
func engineFor(t *testing.T, data *store.Store, runner harness.Runner) *engine.Service {
	t.Helper()
	noReserve := uint64(0)
	app := engine.NewWithOptions(data, engine.Options{Runner: runner, Catalog: testkit.MockCatalog(), MinimumFreeBytes: &noReserve})
	t.Cleanup(func() {
		testkit.Poll(testkit.Budget(30*time.Second), func() bool {
			cards, err := data.Kanban.ListAllCards(true)
			if err != nil {
				return false
			}
			for _, card := range cards {
				if card.Runtime == "running" {
					return false
				}
			}
			return true
		})
		data.Conversations.FlushCheckpoints()
		// Turns end with bookkeeping writes; let them settle.
		last, _ := data.ChangeCount()
		stable := time.Now()
		testkit.Poll(testkit.Budget(20*time.Second), func() bool {
			next, err := data.ChangeCount()
			if err != nil || next != last {
				last, stable = next, time.Now()
				return false
			}
			return time.Since(stable) >= 300*time.Millisecond
		})
	})
	return app
}

// storeCard is a local conversation of the project, as if its first prompt
// was sent.
func storeCard(t *testing.T, data *store.Store, project model.Project, title string, memory bool) model.Card {
	t.Helper()
	card, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: title, Prompt: title, Provider: "mock", Model: "mock", Memory: memory})
	if err != nil {
		t.Fatal(err)
	}
	if card, err = data.Kanban.MarkPromptSent(card.ID); err != nil {
		t.Fatal(err)
	}
	return card
}

// seedTurn writes one finished turn: the prompt, an edit of file and the
// answer.
func seedTurn(t *testing.T, data *store.Store, cardID, prompt, file, answer string) {
	t.Helper()
	turnID := "turn_" + cardID
	if _, err := data.Conversations.StartTurn(cardID, turnID, "user_"+cardID, prompt); err != nil {
		t.Fatal(err)
	}
	input, _ := json.Marshal(map[string]string{"file_path": file})
	chunks := []string{
		`{"type":"start","messageId":"assistant_` + cardID + `"}`,
		`{"type":"tool-input-available","toolCallId":"edit_1","toolName":"Edit","input":` + string(input) + `}`,
		`{"type":"tool-output-available","toolCallId":"edit_1","output":"The file was updated."}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":` + mustJSON(answer) + `}`,
		`{"type":"text-end","id":"text"}`,
		`{"type":"finish","finishReason":"stop"}`,
	}
	var raw []json.RawMessage
	for _, chunk := range chunks {
		raw = append(raw, json.RawMessage(chunk))
	}
	if _, _, err := data.Conversations.AppendUIChunks(cardID, turnID, raw); err != nil {
		t.Fatal(err)
	}
}

func mustJSON(value any) string {
	raw, _ := json.Marshal(value)
	return string(raw)
}

// faultKind is err's kind; -1 for no error.
func faultKind(err error) fault.Kind {
	if err == nil {
		return -1
	}
	kind, _ := fault.KindOf(err)
	return kind
}

func storeHit(card, at string) storememory.Hit {
	return storememory.Hit{CardID: card, LastActivityAt: at}
}

func TestSaveReinforcesSupersedesHintsAndExpires(t *testing.T) {
	t.Parallel()
	data, project := memoryStore(t, "dm_alpha")
	service := newService(t, data, nil, "alpha")

	off, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Quiet", Path: testkit.GitRepo(t), BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = service.Save(SaveInput{Project: off.ID, Content: "This project has memory off and refuses saves."}); faultKind(err) != fault.FailedPrecondition {
		t.Fatalf("save into a project with memory off: %v", err)
	}
	if _, err = service.Save(SaveInput{Project: project.ID, Content: "short"}); faultKind(err) != fault.Invalid {
		t.Fatalf("too short memory: %v", err)
	}

	first, err := service.Save(SaveInput{Project: project.ID, Content: "The release pipeline signs macOS builds with the Developer ID key in CI only."})
	if err != nil || !strings.HasPrefix(first.Memory.ID, "mem_") || first.Memory.Record.Kind != schema.MemoryKindFact {
		t.Fatalf("first save = %+v, %v", first, err)
	}
	lesson, err := service.Save(SaveInput{Project: project.ID, Kind: "lesson", Content: "Run gofmt before handing over Go changes."})
	if err != nil || lesson.Memory.Confidence != 0.5 {
		t.Fatalf("lesson = %+v, %v", lesson, err)
	}
	again, err := service.Save(SaveInput{Project: project.ID, Kind: "lesson", Content: "run gofmt before handing over go changes"})
	if err != nil || !again.Reinforced || again.Memory.ID != lesson.Memory.ID || again.Memory.Confidence != 0.55 {
		t.Fatalf("identical lesson did not reinforce: %+v, %v", again, err)
	}

	corrected, err := service.Save(SaveInput{Project: project.ID, Content: "The release pipeline signs macOS builds with the Developer ID key, in CI only!"})
	if err != nil || corrected.SupersededID != first.Memory.ID {
		t.Fatalf("near-identical save did not supersede: %+v, %v", corrected, err)
	}
	previous, _, err := data.KV.Memory(project.ID, first.Memory.ID)
	if err != nil || previous.Record.Status != schema.MemorySuperseded || previous.Record.SupersededBy != corrected.Memory.ID {
		t.Fatalf("superseded record = %+v, %v", previous.Record, err)
	}

	nearby, err := service.Save(SaveInput{Project: project.ID, Content: "The release pipeline signs Windows builds with the Authenticode key in CI only."})
	if err != nil || nearby.SimilarTo == nil || nearby.SimilarTo.ID != corrected.Memory.ID || nearby.SupersededID != "" {
		t.Fatalf("similar memory was not hinted: %+v, %v", nearby, err)
	}
	if _, err = service.Save(SaveInput{Project: project.ID, Content: "Replaces a memory that does not exist.", ReplacesID: "mem_missing"}); faultKind(err) != fault.NotFound {
		t.Fatalf("replacing a missing memory: %v", err)
	}
	replaced, err := service.Save(SaveInput{Project: project.ID, Content: "Windows builds are signed by the release workflow's Azure signing step.", ReplacesID: nearby.Memory.ID})
	if err != nil || replaced.SupersededID != nearby.Memory.ID {
		t.Fatalf("replaces did not supersede: %+v, %v", replaced, err)
	}

	// A fake key, built at runtime so secret scanners do not flag the test.
	fakeKey := strings.Repeat("ab12", 4)
	secret, err := service.Save(SaveInput{Project: project.ID, Content: "The staging deploy uses api_key=" + fakeKey + " and <private>the root password</private> for now."})
	if err != nil || strings.Contains(secret.Memory.Record.Content, fakeKey) || strings.Contains(secret.Memory.Record.Content, "root password") {
		t.Fatalf("secrets reached a saved memory: %q, %v", secret.Memory.Record.Content, err)
	}

	result, err := service.Search(context.Background(), SearchInput{Project: project.ID, Query: "how are macOS builds signed"})
	if err != nil || len(result.Memories) == 0 || result.Memories[0].ID != corrected.Memory.ID {
		t.Fatalf("recall of saved memories = %+v, %v", result.Memories, err)
	}
	for _, memory := range result.Memories {
		if memory.ID == first.Memory.ID || memory.ID == nearby.Memory.ID {
			t.Fatalf("recall returned superseded memory %s", memory.ID)
		}
	}
	// Saved memories are replicated, so a local-only search answers them too.
	if local, err := service.Search(context.Background(), SearchInput{Project: project.ID, Query: "how are macOS builds signed", LocalOnly: true}); err != nil || len(local.Memories) == 0 {
		t.Fatalf("local-only recall of saved memories = %+v, %v", local.Memories, err)
	}

	brief, err := service.Save(SaveInput{Project: project.ID, Content: "The demo environment is frozen until the board review.", TTLDays: 1})
	if err != nil || brief.Memory.Record.ExpiresAt == "" {
		t.Fatalf("ttl save = %+v, %v", brief, err)
	}
	later := time.Now().Add(49 * time.Hour)
	service.now = func() time.Time { return later }
	active, err := service.activeMemories(project.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, memory := range active {
		if memory.ID == brief.Memory.ID {
			t.Fatal("an expired memory is still active")
		}
	}
	service.expireMemories()
	if _, found, _ := data.KV.Memory(project.ID, brief.Memory.ID); found {
		t.Fatal("the expired memory was not deleted by its writer")
	}
	if err = service.Forget(project.ID, lesson.Memory.ID, "", false); err != nil {
		t.Fatal(err)
	}
	if _, found, _ := data.KV.Memory(project.ID, lesson.Memory.ID); found {
		t.Fatal("forget kept the memory")
	}
	if err = service.Forget(project.ID, lesson.Memory.ID, "card", true); faultKind(err) != fault.Invalid {
		t.Fatalf("forget with two targets: %v", err)
	}
}

func TestMemoryTurnsAreIndexedRecalledAndGetTheTools(t *testing.T) {
	t.Parallel()
	data, project := memoryStore(t, "dm_alpha")
	runner := &testkit.FakeRunner{Reply: func(request harness.Request) string {
		if strings.Contains(request.Prompt, "scheduler") {
			return "The scheduler test was flaky because it slept; it now uses a fake clock."
		}
		return "Nothing to remember here."
	}}
	app := engineFor(t, data, runner)
	service := newService(t, data, app, "alpha")
	runService(t, service)
	ctx := context.Background()

	remembered, err := app.CreateChat(ctx, engine.CardInput{Project: project.ID, Title: "Flaky scheduler", Prompt: "Why is the scheduler test flaky?", Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	if !remembered.Memory {
		t.Fatal("a conversation of a memory project did not default to memory on")
	}
	disabled := false
	private, err := app.CreateChat(ctx, engine.CardInput{Project: project.ID, Title: "Private scheduler", Prompt: "Private scheduler notes", Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject, Memory: &disabled})
	if err != nil {
		t.Fatal(err)
	}
	testkit.Eventually(t, 30*time.Second, func() bool {
		cards, _ := service.Index().Cards(project.ID)
		return runner.Count() == 2 && len(cards) == 1
	}, "the memory turn to be indexed")
	for _, request := range runner.Requests() {
		wantMemory := strings.Contains(request.Prompt, "flaky")
		if request.MemoryEnabled != wantMemory || (wantMemory && (request.Memory == nil || !strings.Contains(request.MemoryCommand, "memory search --project "+project.ID))) {
			t.Fatalf("turn %q memory=%v command=%q", request.Prompt, request.MemoryEnabled, request.MemoryCommand)
		}
		if request.MemoryRole != "" {
			t.Fatalf("an ordinary turn got the memory role %q", request.MemoryRole)
		}
	}
	cards, _ := service.Index().Cards(project.ID)
	if cards[0].ID != remembered.ID || cards[0].Observations == 0 {
		t.Fatalf("indexed cards = %+v", cards)
	}

	result, err := service.Search(ctx, SearchInput{Project: project.ID, Query: "flaky scheduler fake clock"})
	if err != nil || len(result.Hits) != 1 {
		t.Fatalf("search = %+v, %v", result, err)
	}
	hit := result.Hits[0]
	if hit.CardID != remembered.ID || hit.MachineID != "dm_alpha" || hit.Machine != "alpha" || !strings.Contains(hit.FinalAnswer, "fake clock") {
		t.Fatalf("hit = %+v", hit)
	}
	if recalls, _ := service.Index().Recalls(project.ID); recalls[remembered.ID] != 1 {
		t.Fatalf("recall was not counted: %v", recalls)
	}

	card, err := data.Kanban.ResolveCard(remembered.ID)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := service.ToolCall(ctx, card, "mock", harness.ProcessCall{Operation: "recall", Arguments: json.RawMessage(`{"query":"fake clock"}`)})
	if err != nil || !strings.Contains(string(raw), remembered.ID) || !strings.Contains(string(raw), "may be out of date") {
		t.Fatalf("memory_recall = %s, %v", raw, err)
	}
	raw, err = service.ToolCall(ctx, card, "mock", harness.ProcessCall{Operation: "save", Arguments: json.RawMessage(`{"content":"Scheduler tests must use the fake clock, never sleep.","kind":"lesson"}`)})
	if err != nil || !strings.Contains(string(raw), `"status":"saved"`) {
		t.Fatalf("memory_save = %s, %v", raw, err)
	}
	var saved struct{ ID string }
	_ = json.Unmarshal(raw, &saved)
	record, _, err := data.KV.Memory(project.ID, saved.ID)
	if err != nil || record.Record.CreatedBy.Card != remembered.ID || record.Record.CreatedBy.Harness != "mock" || len(record.Record.Sources) != 1 || record.Record.Sources[0] != remembered.ID {
		t.Fatalf("saved by a turn = %+v, %v", record.Record, err)
	}
	if _, err = service.ToolCall(ctx, card, "mock", harness.ProcessCall{Operation: "apply", Arguments: json.RawMessage(`{"operations":[]}`)}); faultKind(err) != fault.PermissionDenied {
		t.Fatalf("an ordinary turn applied a dream batch: %v", err)
	}
	if _, err = app.SetCardMemory(private.ID, true); err != nil {
		t.Fatal(err)
	}

	// Turning the project's memory off stops indexing and recall.
	if _, err = data.Kanban.SetProjectMemory(project.ID, false); err != nil {
		t.Fatal(err)
	}
	if _, err = service.Search(ctx, SearchInput{Project: project.ID, Query: "scheduler"}); faultKind(err) != fault.FailedPrecondition {
		t.Fatalf("search with project memory off: %v", err)
	}
}

func TestReconcileCatchesUpAndForgetsDeletedConversations(t *testing.T) {
	t.Parallel()
	data, project := memoryStore(t, "dm_alpha")
	service := newService(t, data, nil, "alpha")
	card := storeCard(t, data, project, "Deploy rollback", true)
	seedTurn(t, data, card.ID, "How do we roll back a deploy?", "internal/deploy/rollback.go", "Run the rollback job with the previous release tag.")
	off := storeCard(t, data, project, "Not remembered", false)
	seedTurn(t, data, off.ID, "Unrelated", "README.md", "Nothing.")

	service.reconcile()
	drain := func() {
		for {
			select {
			case id := <-service.queue:
				service.mu.Lock()
				delete(service.pending, id)
				service.mu.Unlock()
				if err := service.IndexNow(id); err != nil {
					t.Fatal(err)
				}
			default:
				return
			}
		}
	}
	drain()
	cards, _ := service.Index().Cards(project.ID)
	if len(cards) != 1 || cards[0].ID != card.ID {
		t.Fatalf("reconciled cards = %+v", cards)
	}
	result, err := service.Search(context.Background(), SearchInput{Project: project.ID, Query: "rollback", Files: []string{"deploy/rollback.go"}})
	if err != nil || len(result.Hits) != 1 {
		t.Fatalf("file-filtered search = %+v, %v", result.Hits, err)
	}
	if _, err = data.Kanban.RenameCard(card.ID, "Deploy rollback runbook"); err != nil {
		t.Fatal(err)
	}
	service.reconcile()
	drain()
	if cards, _ = service.Index().Cards(project.ID); cards[0].Title != "Deploy rollback runbook" {
		t.Fatalf("rename did not reach the index: %+v", cards)
	}
	if err = service.Forget(project.ID, "", card.ID, false); err != nil {
		t.Fatal(err)
	}
	if cards, _ = service.Index().Cards(project.ID); len(cards) != 0 {
		t.Fatalf("forget --card kept rows: %+v", cards)
	}
	if err = service.Reindex(project.ID); err != nil {
		t.Fatal(err)
	}
	if cards, _ = service.Index().Cards(project.ID); len(cards) != 1 {
		t.Fatalf("reindex = %+v", cards)
	}
}

// peerClient answers SearchMemory from another daemon's memory service, as
// the peer's API would.
type peerClient struct {
	dieterclient.Client
	service *Service
}

func (p peerClient) SearchMemory(ctx context.Context, request *dieterv1.SearchMemoryRequest, _ ...grpc.CallOption) (*dieterv1.MemorySearchResult, error) {
	result, err := p.service.Search(ctx, SearchInput{Project: request.GetProjectId(), Query: request.GetQuery(), Limit: int(request.GetLimit()), Files: request.GetFiles(), LocalOnly: request.GetLocalOnly()})
	if err != nil {
		return nil, err
	}
	out := &dieterv1.MemorySearchResult{}
	for _, hit := range result.Hits {
		out.Hits = append(out.Hits, &dieterv1.MemoryHit{
			CardId: hit.CardID, MachineId: hit.MachineID, Machine: hit.Machine, Title: hit.Title, Lane: hit.Lane,
			Snippets: hit.Snippets, FinalAnswer: hit.FinalAnswer, LastActivityAt: hit.LastActivityAt,
		})
	}
	return out, nil
}

func TestRecallAcrossMachinesMergesAndReportsUnreachable(t *testing.T) {
	t.Parallel()
	alphaData, project := memoryStore(t, "dm_alpha")
	betaData := testkit.PeerStore(t, "dm_beta")
	if err := betaData.Ensure(); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, alphaData, betaData)
	if _, err := betaData.Kanban.AttachCheckout(project.ID, testkit.GitRepo(t), "beta checkout"); err != nil {
		t.Fatal(err)
	}
	alpha := newService(t, alphaData, nil, "alpha")
	beta := newService(t, betaData, nil, "beta")

	local := storeCard(t, alphaData, project, "Rollback on alpha", true)
	seedTurn(t, alphaData, local.ID, "Roll back the staging deploy", "internal/deploy/rollback.go", "Rolled back staging with the previous release tag.")
	if err := alpha.IndexNow(local.ID); err != nil {
		t.Fatal(err)
	}
	remote := storeCard(t, betaData, project, "Rollback on beta", true)
	seedTurn(t, betaData, remote.ID, "Why did the production rollback fail?", "deploy/rollback.sh", "The rollback failed because the release tag was missing; tag before deploying.")
	if err := beta.IndexNow(remote.ID); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, betaData, alphaData)
	if got := alpha.projectDaemons(project.ID, "dm_alpha"); len(got) != 1 || got[0] != "dm_beta" {
		t.Fatalf("project daemons = %v", got)
	}

	dialed := 0
	alpha.SetDialer(func(ctx context.Context, daemonID string) (dieterclient.Client, func(), error) {
		dialed++
		if daemonID != "dm_beta" {
			return nil, nil, errors.New("unknown daemon")
		}
		return peerClient{service: beta}, func() {}, nil
	})
	ctx := context.Background()
	result, err := alpha.Search(ctx, SearchInput{Project: project.ID, Query: "rollback release tag"})
	if err != nil || len(result.Hits) != 2 || len(result.Unreachable) != 0 {
		t.Fatalf("federated search = %+v, %v", result, err)
	}
	machines := map[string]string{}
	for _, hit := range result.Hits {
		machines[hit.CardID] = hit.MachineID + "/" + hit.Machine
	}
	if machines[local.ID] != "dm_alpha/alpha" || machines[remote.ID] != "dm_beta/beta" {
		t.Fatalf("hit machines = %v", machines)
	}

	onlyHere, err := alpha.Search(ctx, SearchInput{Project: project.ID, Query: "rollback release tag", LocalOnly: true})
	if err != nil || len(onlyHere.Hits) != 1 || onlyHere.Hits[0].CardID != local.ID || dialed != 1 {
		t.Fatalf("local-only search = %+v, dialed %d, %v", onlyHere.Hits, dialed, err)
	}

	alpha.SetDialer(func(context.Context, string) (dieterclient.Client, func(), error) {
		return nil, nil, errors.New("offline")
	})
	degraded, err := alpha.Search(ctx, SearchInput{Project: project.ID, Query: "rollback release tag"})
	if err != nil || len(degraded.Hits) != 1 || len(degraded.Unreachable) != 1 || degraded.Unreachable[0] != "dm_beta" {
		t.Fatalf("search with an offline peer = %+v, %v", degraded, err)
	}
	raw := recallToolResult(degraded, "dieter")
	if !strings.Contains(string(raw), `"unreachableMachines":["dm_beta"]`) {
		t.Fatalf("recall tool result does not name the unreachable machine: %s", raw)
	}

	// Saved memories replicate: a memory saved on beta is recalled on alpha.
	if _, err = beta.Save(SaveInput{Project: project.ID, Kind: "lesson", Content: "Tag the release before deploying so rollbacks can find it."}); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, betaData, alphaData)
	replicated, err := alpha.Search(ctx, SearchInput{Project: project.ID, Query: "tag release rollback", LocalOnly: false})
	if err != nil || len(replicated.Memories) != 1 || replicated.Memories[0].Record.CreatedBy.Daemon != "dm_beta" {
		t.Fatalf("replicated memory recall = %+v, %v", replicated.Memories, err)
	}
	// Reinforcements from two daemons add up.
	if _, err = alpha.Save(SaveInput{Project: project.ID, Kind: "lesson", Content: "Tag the release before deploying so rollbacks can find it."}); err != nil {
		t.Fatal(err)
	}
	if _, err = beta.Save(SaveInput{Project: project.ID, Kind: "lesson", Content: "Tag the release before deploying so rollbacks can find it."}); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, alphaData, betaData)
	testkit.JoinPeers(t, betaData, alphaData)
	merged, _ := alpha.activeMemories(project.ID)
	if len(merged) != 1 || merged[0].Reinforcements != 2 {
		t.Fatalf("merged reinforcements = %+v", merged)
	}
}

// heldRunner holds every turn until one release token arrives.
func heldRunner(release chan struct{}) *testkit.FakeRunner {
	return &testkit.FakeRunner{Script: func(ctx context.Context, _ harness.Request, emit func(harness.Output) error) error {
		select {
		case <-release:
		case <-ctx.Done():
			return ctx.Err()
		}
		return testkit.EmitText(emit, "Dream report.", testkit.FakeThreadID)
	}}
}

type dreamFixture struct {
	data     *store.Store
	project  model.Project
	service  *Service
	runner   *testkit.FakeRunner
	release  chan struct{}
	source   model.Card
	memories []string
}

func dreamSetup(t *testing.T, apply string) dreamFixture {
	t.Helper()
	data, project := memoryStore(t, "dm_alpha")
	release := make(chan struct{}, 8)
	runner := heldRunner(release)
	app := engineFor(t, data, runner)
	service := newService(t, data, app, "alpha")
	runService(t, service)
	settings := schema.DefaultMemorySettings()
	settings.Harness, settings.Model, settings.Apply, settings.MaxOperations, settings.MaxRetire = "mock", "mock", apply, 10, 75
	if _, err := data.KV.PutMemorySettings(settings, ""); err != nil {
		t.Fatal(err)
	}
	source := storeCard(t, data, project, "Release signing", true)
	fixture := dreamFixture{data: data, project: project, service: service, runner: runner, release: release, source: source}
	for _, content := range []string{
		"macOS builds are signed with the Developer ID key in CI.",
		"The Developer ID key signs the macOS app during the release workflow.",
		"Windows builds are not signed yet.",
		"Release notes live in site/content/releases.",
	} {
		saved, err := service.Save(SaveInput{Project: project.ID, Content: content, Sources: []string{source.ID}})
		if err != nil {
			t.Fatal(err)
		}
		fixture.memories = append(fixture.memories, saved.Memory.ID)
	}
	return fixture
}

func (f dreamFixture) start(t *testing.T) (Dream, model.Card) {
	t.Helper()
	dream, err := f.service.StartDream(context.Background(), f.project.ID)
	if err != nil {
		t.Fatal(err)
	}
	card, err := f.data.Kanban.ResolveCard(dream.CardID)
	if err != nil {
		t.Fatal(err)
	}
	return dream, card
}

func (f dreamFixture) validBatch() json.RawMessage {
	return json.RawMessage(`{"summary":"Merged the signing memories.","operations":[
		{"op":"merge","targets":["` + f.memories[0] + `","` + f.memories[1] + `"],"kind":"fact","content":"macOS builds are signed with the Developer ID key by the release workflow in CI.","sources":["` + f.source.ID + `"],"reason":"duplicates"},
		{"op":"retire","targets":["` + f.memories[2] + `"],"reason":"Windows signing shipped"},
		{"op":"verify","targets":["` + f.memories[3] + `"],"reason":"still true"},
		{"op":"add","kind":"decision","content":"Windows builds are signed with Azure Trusted Signing since the 0.7 line.","sources":["` + f.source.ID + `"],"reason":"decided in the release card"}
	]}`)
}

func (f dreamFixture) record(t *testing.T, id string) schema.MemoryRecord {
	t.Helper()
	saved, found, err := f.data.KV.Memory(f.project.ID, id)
	if err != nil || !found {
		t.Fatalf("memory %s: found=%v %v", id, found, err)
	}
	return saved.Record
}

func (f dreamFixture) waitStatus(t *testing.T, cardID, status string) Dream {
	t.Helper()
	var dream Dream
	testkit.Eventually(t, 30*time.Second, func() bool {
		dream, _ = f.service.Dream(cardID)
		return dream.Status == status
	}, "dream %s to be %s", cardID, status)
	return dream
}

func TestDreamValidatesAppliesAndUndoes(t *testing.T) {
	t.Parallel()
	f := dreamSetup(t, "auto")
	ctx := context.Background()
	dream, card := f.start(t)
	if dream.Status != DreamRunning || card.MemoryRole != engine.MemoryRoleDreamer || !card.Memory || card.Lane != model.LaneRunning {
		t.Fatalf("dream = %+v card role=%q memory=%v lane=%s", dream, card.MemoryRole, card.Memory, card.Lane)
	}
	board, err := f.data.Kanban.InitialBoard(f.project.ID)
	if err != nil {
		t.Fatal(err)
	}
	labelled := false
	for _, label := range board.Labels {
		if label.Name == MemoryLabel && strings.Contains(label.Instructions, "memory dream") {
			labelled = len(card.LabelIDs) == 1 && card.LabelIDs[0] == label.ID
		}
	}
	if !labelled {
		t.Fatalf("dream card labels %v, board labels %+v", card.LabelIDs, board.Labels)
	}
	testkit.Eventually(t, 30*time.Second, func() bool { return f.runner.Count() == 1 }, "the dream turn to start")
	request := f.runner.Request(0)
	if !request.MemoryEnabled || request.MemoryRole != engine.MemoryRoleDreamer || !strings.Contains(request.Prompt, f.memories[0]) || !strings.Contains(request.Prompt, "retire or supersede at most 3 of the 4") {
		t.Fatalf("dream request memory=%v role=%q prompt=%q", request.MemoryEnabled, request.MemoryRole, request.Prompt)
	}
	if _, err = f.service.StartDream(ctx, f.project.ID); faultKind(err) != fault.FailedPrecondition {
		t.Fatalf("a second dream started while one runs: %v", err)
	}
	if _, err = engineSetMemoryOff(f, card.ID); faultKind(err) != fault.FailedPrecondition {
		t.Fatalf("a dream's memory was switched off: %v", err)
	}

	invalid := json.RawMessage(`{"operations":[
		{"op":"retire","targets":["` + f.memories[0] + `","` + f.memories[1] + `","` + f.memories[2] + `","` + f.memories[3] + `"],"reason":"too much"},
		{"op":"verify","targets":["mem_unknown"],"reason":"missing"},
		{"op":"add","content":"A memory without sources is refused.","reason":"no source"}
	]}`)
	_, err = f.service.ToolCall(ctx, card, "mock", harness.ProcessCall{Operation: "apply", Arguments: invalid})
	if faultKind(err) != fault.Invalid || !strings.Contains(err.Error(), "the limit is 3 of 4") || !strings.Contains(err.Error(), "mem_unknown is not an active memory") || !strings.Contains(err.Error(), "cite at least one card ID") {
		t.Fatalf("invalid batch: %v", err)
	}
	if record := f.record(t, f.memories[0]); record.Status != schema.MemoryActive {
		t.Fatalf("a rejected batch changed a memory: %+v", record)
	}

	raw, err := f.service.ToolCall(ctx, card, "mock", harness.ProcessCall{Operation: "apply", Arguments: f.validBatch()})
	if err != nil || !strings.Contains(string(raw), `"status":"applied"`) || !strings.Contains(string(raw), "dream undo "+card.ID) {
		t.Fatalf("valid batch = %s, %v", raw, err)
	}
	if _, err = f.service.ToolCall(ctx, card, "mock", harness.ProcessCall{Operation: "apply", Arguments: f.validBatch()}); faultKind(err) != fault.FailedPrecondition {
		t.Fatalf("a second batch was accepted: %v", err)
	}
	merged := f.record(t, f.memories[0])
	if merged.Status != schema.MemorySuperseded || merged.SupersededBy == "" || f.record(t, f.memories[1]).SupersededBy != merged.SupersededBy {
		t.Fatalf("merge targets = %+v", merged)
	}
	if replacement := f.record(t, merged.SupersededBy); replacement.DreamCard != card.ID || replacement.CreatedBy.Card != card.ID || replacement.Status != schema.MemoryActive {
		t.Fatalf("merged memory = %+v", replacement)
	}
	if retired := f.record(t, f.memories[2]); retired.Status != schema.MemoryRetired || retired.Reason != "Windows signing shipped" {
		t.Fatalf("retired = %+v", retired)
	}
	if !f.record(t, f.memories[3]).Verified {
		t.Fatal("verify did not mark the memory")
	}
	active, _ := f.service.activeMemories(f.project.ID)
	if len(active) != 3 {
		t.Fatalf("active after the dream = %d", len(active))
	}

	f.release <- struct{}{}
	applied := f.waitStatus(t, card.ID, DreamApplied)
	if applied.Added != 1 || applied.Merged != 1 || applied.Retired != 1 || applied.Verified != 1 || len(applied.Changes) != 6 {
		t.Fatalf("applied dream = %+v", applied)
	}
	// A dream quotes every memory: it is never indexed for recall.
	if err := f.service.IndexNow(card.ID); err != nil {
		t.Fatal(err)
	}
	cards, _ := f.service.Index().Cards(f.project.ID)
	for _, indexed := range cards {
		if indexed.ID == card.ID {
			t.Fatalf("the dream conversation was indexed: %+v", cards)
		}
	}
	if status, err := f.service.Status(f.project.ID); err != nil || len(status.Projects) != 1 || status.Projects[0].LastDreamCard != card.ID {
		t.Fatalf("status after a dream = %+v, %v", status, err)
	}

	undone, err := f.service.UndoDream(card.ID)
	if err != nil || undone.Status != DreamUndone {
		t.Fatalf("undo = %+v, %v", undone, err)
	}
	for _, id := range f.memories {
		if record := f.record(t, id); record.Status != schema.MemoryActive || record.Verified || record.SupersededBy != "" {
			t.Fatalf("undo left %s as %+v", id, record)
		}
	}
	if _, found, _ := f.data.KV.Memory(f.project.ID, merged.SupersededBy); found {
		t.Fatal("undo kept the memory the dream created")
	}
	if _, err = f.service.UndoDream(card.ID); faultKind(err) != fault.FailedPrecondition {
		t.Fatalf("second undo: %v", err)
	}
}

func engineSetMemoryOff(f dreamFixture, cardID string) (model.Card, error) {
	return f.service.app.SetCardMemory(cardID, false)
}

func TestDreamReviewModeStagesUntilAppliedOrDiscarded(t *testing.T) {
	t.Parallel()
	f := dreamSetup(t, "review")
	ctx := context.Background()
	_, card := f.start(t)
	testkit.Eventually(t, 30*time.Second, func() bool { return f.runner.Count() == 1 }, "the dream turn to start")
	raw, err := f.service.ToolCall(ctx, card, "mock", harness.ProcessCall{Operation: "apply", Arguments: f.validBatch()})
	if err != nil || !strings.Contains(string(raw), "staged for review") {
		t.Fatalf("staged batch = %s, %v", raw, err)
	}
	if record := f.record(t, f.memories[0]); record.Status != schema.MemoryActive {
		t.Fatalf("review mode applied at once: %+v", record)
	}
	f.release <- struct{}{}
	f.waitStatus(t, card.ID, DreamStaged)
	if _, err = f.service.UndoDream(card.ID); faultKind(err) != fault.FailedPrecondition {
		t.Fatalf("undo of a staged dream: %v", err)
	}
	applied, err := f.service.ApplyDream(card.ID)
	if err != nil || applied.Status != DreamApplied || f.record(t, f.memories[2]).Status != schema.MemoryRetired {
		t.Fatalf("apply staged = %+v, %v", applied, err)
	}
	if _, err = f.service.ApplyDream(card.ID); faultKind(err) != fault.FailedPrecondition {
		t.Fatalf("second apply: %v", err)
	}

	// The next dream stages a batch that a person discards.
	_, second := f.start(t)
	testkit.Eventually(t, 30*time.Second, func() bool { return f.runner.Count() == 2 }, "the second dream turn to start")
	batch := json.RawMessage(`{"operations":[{"op":"retire","targets":["` + f.memories[3] + `"],"reason":"no longer needed"}]}`)
	if _, err = f.service.ToolCall(ctx, second, "mock", harness.ProcessCall{Operation: "apply", Arguments: batch}); err != nil {
		t.Fatal(err)
	}
	f.release <- struct{}{}
	f.waitStatus(t, second.ID, DreamStaged)
	discarded, err := f.service.DiscardDream(second.ID)
	if err != nil || discarded.Status != DreamDiscarded || f.record(t, f.memories[3]).Status != schema.MemoryActive {
		t.Fatalf("discard = %+v, %v", discarded, err)
	}
	dreams, err := f.service.Dreams(f.project.ID)
	if err != nil || len(dreams) != 2 || dreams[0].CardID != second.ID {
		t.Fatalf("dreams = %+v, %v", dreams, err)
	}
}

func TestDreamGates(t *testing.T) {
	t.Parallel()
	data, project := memoryStore(t, "dm_alpha")
	service := newService(t, data, nil, "alpha")
	settings := schema.DefaultMemorySettings()
	settings.Dreaming, settings.MinNewTasks, settings.MinHours, settings.Window = true, 2, 24, ""

	reason := func(settings schema.MemorySettingsRecord, project model.Project) DreamGate {
		return service.dreamGate(settings, project, "dm_alpha")
	}
	storeCard(t, data, project, "First finished conversation", true)
	if gate := reason(settings, project); gate.Eligible || !strings.Contains(gate.Reason, "1 more finished") || gate.Machine != "dm_alpha" {
		t.Fatalf("one conversation: %+v", gate)
	}
	storeCard(t, data, project, "Second finished conversation", true)
	if gate := reason(settings, project); !gate.Eligible || gate.FinishedSince != 2 {
		t.Fatalf("two conversations: %+v", gate)
	}
	off := settings
	off.Dreaming = false
	if gate := reason(off, project); gate.Eligible || gate.Reason != "dreaming is off" {
		t.Fatalf("dreaming off: %+v", gate)
	}
	elsewhere := settings
	elsewhere.RunOn = "dm_beta"
	if gate := reason(elsewhere, project); gate.Eligible || gate.Reason != "dreams run on dm_beta" {
		t.Fatalf("run on another machine: %+v", gate)
	}
	quiet := project
	quiet.MemoryEnabled = false
	if gate := reason(settings, quiet); gate.Eligible || gate.Reason != "project memory is off" {
		t.Fatalf("memory off: %+v", gate)
	}

	time.Sleep(10 * time.Millisecond)
	now := time.Now()
	if err := service.index.SetMeta(dreamMetaLastPrefix+project.ID, now.UTC().Format(time.RFC3339Nano)+" c_previous"); err != nil {
		t.Fatal(err)
	}
	if gate := reason(settings, project); gate.Eligible || gate.FinishedSince != 0 || !strings.Contains(gate.Reason, "2 more finished") {
		t.Fatalf("right after a dream: %+v", gate)
	}
	time.Sleep(10 * time.Millisecond)
	storeCard(t, data, project, "Third", true)
	storeCard(t, data, project, "Fourth", true)
	if gate := reason(settings, project); gate.Eligible || !strings.HasPrefix(gate.Reason, "next dream after") || gate.LastDreamCard != "c_previous" {
		t.Fatalf("within min hours: %+v", gate)
	}
	service.now = func() time.Time { return now.Add(25 * time.Hour) }
	if gate := reason(settings, project); !gate.Eligible {
		t.Fatalf("after min hours: %+v", gate)
	}
	closed := settings
	at := now.Add(25 * time.Hour)
	closed.Window = at.Add(time.Hour).Format("15:04") + "-" + at.Add(2*time.Hour).Format("15:04")
	if gate := reason(closed, project); gate.Eligible || !strings.HasPrefix(gate.Reason, "waiting for the dreaming window") {
		t.Fatalf("outside the window: %+v", gate)
	}

	for _, tc := range []struct {
		window string
		clock  string
		want   bool
	}{
		{"", "12:00", true}, {"02:00-06:00", "03:30", true}, {"02:00-06:00", "06:00", false},
		{"22:00-02:00", "23:15", true}, {"22:00-02:00", "01:59", true}, {"22:00-02:00", "12:00", false},
	} {
		clock, _ := time.Parse("15:04", tc.clock)
		if got := inWindow(tc.window, clock); got != tc.want {
			t.Errorf("inWindow(%q, %s) = %v", tc.window, tc.clock, got)
		}
	}
	if retireLimit(0, 25) != 0 || retireLimit(3, 25) != 1 || retireLimit(40, 25) != 10 {
		t.Fatal("retire limit")
	}
}

func TestMergeHitsFusesRanksPerMachine(t *testing.T) {
	t.Parallel()
	hit := func(machine, card, at string) Hit {
		return Hit{MachineID: machine, Hit: storeHit(card, at)}
	}
	merged := mergeHits([][]Hit{
		{hit("dm_a", "c_1", "2026-11-01"), hit("dm_a", "c_2", "2026-11-02")},
		{hit("dm_b", "c_9", "2026-11-03"), hit("dm_b", "c_1", "2026-11-04")},
	}, 3)
	if len(merged) != 3 || merged[0].Rank != 1 || merged[2].Rank != 3 {
		t.Fatalf("merged = %+v", merged)
	}
	// Equal first ranks tie-break on recency; the same card ID on two
	// machines stays two conversations.
	if merged[0].CardID != "c_9" || merged[1].CardID != "c_1" || merged[1].MachineID != "dm_a" {
		t.Fatalf("order = %s/%s, %s/%s", merged[0].MachineID, merged[0].CardID, merged[1].MachineID, merged[1].CardID)
	}
}

func TestDreamOfAProjectWithoutBoardsIsAChatWithTheProcedure(t *testing.T) {
	t.Parallel()
	data := testkit.PeerStore(t, "dm_alpha")
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Loose", Path: testkit.GitRepo(t), BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	if project, err = data.Kanban.SetProjectMemory(project.ID, true); err != nil {
		t.Fatal(err)
	}
	runner := &testkit.FakeRunner{}
	service := newService(t, data, engineFor(t, data, runner), "alpha")
	runService(t, service)
	settings := schema.DefaultMemorySettings()
	settings.Harness, settings.Model = "mock", "mock"
	if _, err = data.KV.PutMemorySettings(settings, ""); err != nil {
		t.Fatal(err)
	}
	dream, err := service.StartDream(context.Background(), project.ID)
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.Kanban.ResolveCard(dream.CardID)
	if err != nil || card.Scope != model.ConversationScopeChat || card.MemoryRole != engine.MemoryRoleDreamer || card.WorkspaceMode != model.WorkspaceModeWorktree {
		t.Fatalf("board-less dream = %+v, %v", card, err)
	}
	testkit.Eventually(t, 30*time.Second, func() bool { return runner.Count() == 1 }, "the dream turn to start")
	if prompt := runner.Request(0).Prompt; !strings.Contains(prompt, "## Dream procedure") || !strings.Contains(prompt, "This is the project's first dream") {
		t.Fatalf("board-less dream prompt = %q", prompt)
	}
	// The turn ended without a batch: the dream is empty.
	testkit.Eventually(t, 30*time.Second, func() bool {
		dream, _ = service.Dream(card.ID)
		return dream.Status == DreamEmpty
	}, "the dream to end empty")
}
