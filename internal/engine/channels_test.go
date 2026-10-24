package engine

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/store/conversations"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

// channelRunner holds turns whose prompt contains "hold" until released,
// answers every steer frame as accepted and, for "write:PATH", emits an edit
// tool call of PATH in the turn's workspace.
type channelRunner struct {
	mu       sync.Mutex
	requests map[string][]harness.Request
	release  map[string]chan struct{}
	steered  chan string
}

func newChannelRunner() *channelRunner {
	return &channelRunner{requests: map[string][]harness.Request{}, release: map[string]chan struct{}{}, steered: make(chan string, 16)}
}

func (r *channelRunner) hold(cardID string) chan struct{} {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.release[cardID] == nil {
		r.release[cardID] = make(chan struct{})
	}
	return r.release[cardID]
}

func (r *channelRunner) turns(cardID string) []harness.Request {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]harness.Request(nil), r.requests[cardID]...)
}

func (r *channelRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	r.mu.Lock()
	r.requests[request.SessionID] = append(r.requests[request.SessionID], request)
	r.mu.Unlock()
	chunk := func(value any) error {
		raw, _ := json.Marshal(value)
		return emit(harness.Output{Type: "chunk", Chunk: raw})
	}
	if err := chunk(map[string]any{"type": "start", "messageId": request.ResponseMessageID}); err != nil {
		return err
	}
	if _, path, ok := strings.Cut(request.Prompt, "write:"); ok {
		path, _, _ = strings.Cut(path, " ")
		input := map[string]string{"file_path": filepath.Join(request.ProjectPath, strings.TrimSpace(path))}
		if err := chunk(map[string]any{"type": "tool-input-available", "toolCallId": "edit-1", "toolName": "edit", "input": input}); err != nil {
			return err
		}
	}
	if strings.Contains(request.Prompt, "hold") && !strings.Contains(request.Prompt, "woke you") {
		release := r.hold(request.SessionID)
	wait:
		for {
			select {
			case call := <-request.Steer:
				if err := emit(harness.Output{Type: "steer-result", ID: call.ID, Accepted: true}); err != nil {
					return err
				}
				r.steered <- call.Text
			case <-release:
				break wait
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
	for _, value := range []map[string]any{
		{"type": "text-start", "id": "t"}, {"type": "text-delta", "id": "t", "delta": "finished the work"},
		{"type": "text-end", "id": "t"}, {"type": "finish", "finishReason": "stop"},
	} {
		if err := chunk(value); err != nil {
			return err
		}
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"threadId":"t1"}}`)})
}

func channelSetup(t *testing.T) (*Service, *channelRunner, model.Project, model.Board) {
	t.Helper()
	service, _, project, board := appSetup(t)
	runner := newChannelRunner()
	service.Runner = runner
	t.Cleanup(func() {
		// Release every held turn, then let releases, wakes and the turns they
		// start finish before the store is removed.
		quiet := func() bool {
			runner.mu.Lock()
			for _, release := range runner.release {
				select {
				case <-release:
				default:
					close(release)
				}
			}
			runner.mu.Unlock()
			service.mu.Lock()
			defer service.mu.Unlock()
			return len(service.active) == 0 && service.channels.work.Load() == 0
		}
		// Quiet twice in a row: a finishing turn can schedule one more wake.
		waitFor(t, func() bool {
			if !quiet() {
				return false
			}
			time.Sleep(50 * time.Millisecond)
			return quiet()
		})
	})
	return service, runner, project, board
}

func channelCard(t *testing.T, service *Service, project model.Project, board model.Board, title string) model.Card {
	t.Helper()
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: title, Prompt: "Work", Provider: "codex", Model: "gpt-5.6-sol",
	})
	if err != nil {
		t.Fatal(err)
	}
	return card
}

func startChannelTurn(t *testing.T, service *Service, card model.Card, prompt string) {
	t.Helper()
	updates, err := service.StartCard(card.ID, prompt, card.Provider, card.Model, "")
	if err != nil {
		t.Fatalf("start %s: %v", card.Title, err)
	}
	go drainTurnUpdates(updates)
}

func waitIdle(t *testing.T, service *Service, cardID string) {
	t.Helper()
	waitFor(t, func() bool {
		service.mu.Lock()
		defer service.mu.Unlock()
		return service.active[cardID] == nil
	})
}

func waitSteer(t *testing.T, runner *channelRunner, contains string) string {
	t.Helper()
	return waitSteers(t, runner, contains)[0]
}

// waitSteers waits until steer texts containing every substring arrived, in
// any order (deliveries to different cards flush independently).
func waitSteers(t *testing.T, runner *channelRunner, contains ...string) []string {
	t.Helper()
	found := make([]string, len(contains))
	missing := len(contains)
	deadline := time.After(testkit.Budget(30 * time.Second))
	for missing > 0 {
		select {
		case text := <-runner.steered:
			for i, want := range contains {
				if found[i] == "" && strings.Contains(text, want) {
					found[i] = text
					missing--
				}
			}
		case <-deadline:
			t.Fatalf("steers %q: received only %q", contains, found)
		}
	}
	return found
}

func enableChannels(t *testing.T, service *Service) {
	t.Helper()
	if _, err := service.SetChannelSetting("global", "", "on"); err != nil {
		t.Fatal(err)
	}
}

func TestChannelsStayOffUntilEnabled(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	card := channelCard(t, service, project, board, "Off")
	if _, err := service.PostChannelMessage(context.Background(), ChannelCaller{}, ChannelPost{ProjectID: project.ID, Body: "hello"}); !errors.Is(err, ErrChannelsOff) {
		t.Fatalf("post with channels off = %v, want ErrChannelsOff", err)
	}
	startChannelTurn(t, service, card, "Plain work")
	waitIdle(t, service, card.ID)
	request := runner.turns(card.ID)[0]
	if request.SteerEnabled || request.ChannelHookCommand != "" || strings.Contains(request.Instructions, "Agent channels") {
		t.Fatalf("channels leaked into a turn while off: steer=%v hook=%q", request.SteerEnabled, request.ChannelHookCommand)
	}
	// A board override switches one board on without the global switch.
	if _, err := service.SetChannelSetting("board", board.ID, "on"); err != nil {
		t.Fatal(err)
	}
	if _, err := service.PostChannelMessage(context.Background(), ChannelCaller{}, ChannelPost{ProjectID: project.ID, Body: "hello"}); err != nil {
		t.Fatalf("post with a board override on: %v", err)
	}
	if _, err := service.SetChannelSetting("project", project.ID, "off"); err != nil {
		t.Fatal(err)
	}
	if !service.ChannelsEnabled(card) {
		t.Fatal("a board override must win over its project")
	}
}

func TestChannelDigestReachesTheNextTurn(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	enableChannels(t, service)
	service.CLIExecutable = "/opt/dieter's/bin/dieter"
	author := channelCard(t, service, project, board, "Pricing refactor")
	reader := channelCard(t, service, project, board, "Checkout tests")
	posted, err := service.PostChannelMessage(context.Background(), ChannelCaller{CardID: author.ID}, ChannelPost{Kind: "request", Body: "src/pricing.go now returns cents; update your assertions."})
	if err != nil {
		t.Fatal(err)
	}
	if posted.Author.Kind != model.ChannelAuthorAgent || posted.Author.CardID != author.ID || posted.ProjectID != project.ID {
		t.Fatalf("posted = %+v", posted)
	}
	startChannelTurn(t, service, reader, "Fix the checkout tests")
	waitIdle(t, service, reader.ID)
	request := runner.turns(reader.ID)[0]
	if !strings.HasPrefix(request.Prompt, "<dieter-channel-digest") || !strings.Contains(request.Prompt, "returns cents") || !strings.HasSuffix(request.Prompt, "Fix the checkout tests") {
		t.Fatalf("prompt = %q, want the digest ahead of the user prompt", request.Prompt)
	}
	cli := `'/opt/dieter'\''s/bin/dieter'`
	if !strings.Contains(request.Instructions, dieterprompt.ChannelInstructions(cli)) || !strings.Contains(request.Instructions, cli+" channel post") || !strings.Contains(request.Instructions, "-- FILE...") || !request.SteerEnabled {
		t.Fatalf("channel instructions or steering missing: steer=%v", request.SteerEnabled)
	}
	if request.ChannelHookCommand != `'/opt/dieter'\''s/bin/dieter' channel hook` {
		t.Fatalf("hook command = %q", request.ChannelHookCommand)
	}
	conversation, _ := service.Store.Conversations.Get(reader.ID)
	for _, message := range conversation.Messages {
		for _, part := range message.Parts {
			if strings.Contains(part.Text, "dieter-channel-digest") {
				t.Fatal("the digest must reach the harness only, not the stored user message")
			}
		}
	}
	stored, _ := service.Store.Channels.Message(project.ID, posted.ID)
	if len(stored.Deliveries) != 1 || stored.Deliveries[0].CardID != reader.ID || stored.Deliveries[0].Mode != model.ChannelDeliveryDigest {
		t.Fatalf("deliveries = %+v", stored.Deliveries)
	}
	// The author never receives its own message; a second turn repeats nothing.
	startChannelTurn(t, service, author, "More work")
	waitIdle(t, service, author.ID)
	startChannelTurn(t, service, reader, "Again")
	waitIdle(t, service, reader.ID)
	if prompt := runner.turns(author.ID)[0].Prompt; strings.Contains(prompt, "digest") {
		t.Fatalf("author prompt = %q", prompt)
	}
	if prompt := runner.turns(reader.ID)[1].Prompt; prompt != "Again" {
		t.Fatalf("second prompt = %q, want no repeated digest", prompt)
	}
}

func TestChannelMessageSteersIntoARunningTurn(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	enableChannels(t, service)
	card := channelCard(t, service, project, board, "Release notes")
	startChannelTurn(t, service, card, "hold while writing notes")
	waitFor(t, func() bool { return service.turnHasChannelFor(card.ID) })
	posted, err := service.PostChannelMessage(context.Background(), ChannelCaller{DeviceID: "dv_1"}, ChannelPost{ProjectID: project.ID, Body: "The release tag is PAPAYA-7."})
	if err != nil {
		t.Fatal(err)
	}
	text := waitSteer(t, runner, "PAPAYA-7")
	if !strings.Contains(text, `<dieter-channel-message id="`+posted.ID+`"`) || !strings.Contains(text, `from="human"`) {
		t.Fatalf("steer text = %q", text)
	}
	waitFor(t, func() bool {
		message, _ := service.Store.Channels.Message(project.ID, posted.ID)
		return len(message.Deliveries) == 1 && message.Deliveries[0].Mode == model.ChannelDeliverySteered
	})
	close(runner.hold(card.ID))
	waitIdle(t, service, card.ID)
	conversation, _ := service.Store.Conversations.Get(card.ID)
	last := conversation.Messages[len(conversation.Messages)-1]
	if last.Role != "assistant" || len(last.Parts) < 2 || last.Parts[0].Type != conversations.PeerNoticePartType {
		t.Fatalf("assistant parts = %+v, want the peer notice before the reply", last.Parts)
	}
	var notice struct {
		MessageID string              `json:"messageId"`
		Author    model.ChannelAuthor `json:"author"`
	}
	if err := json.Unmarshal(last.Parts[0].Data, &notice); err != nil || notice.MessageID != posted.ID || notice.Author.Kind != model.ChannelAuthorHuman || last.Parts[0].Text != posted.Body {
		t.Fatalf("notice = %+v (%s), %v", notice, last.Parts[0].Text, err)
	}
	if card, _ := service.Store.Kanban.ResolveCard(card.ID); card.Runtime == model.RuntimeFailed {
		t.Fatal("a reply with a notice was treated as empty")
	}
}

func TestChannelClaimsHoldWritersAndReleaseWakesThem(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	enableChannels(t, service)
	holder := channelCard(t, service, project, board, "Rename tiers")
	waiter := channelCard(t, service, project, board, "Add tier cap")
	startChannelTurn(t, service, holder, "hold write:src/module3.js")
	waitFor(t, func() bool { return len(service.ChannelClaims(project.ID)) == 1 })
	claim := service.ChannelClaims(project.ID)[0]
	if claim.CardID != holder.ID || claim.Path != "src/module3.js" {
		t.Fatalf("claim = %+v", claim)
	}
	startChannelTurn(t, service, waiter, "hold write:src/module5.js before patching")
	waitFor(t, func() bool { return service.turnHasChannelFor(waiter.ID) })
	// Codex's PreToolUse hook: the patch touches the held file and is denied.
	event := `{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/module3.js\n@@\n-a\n+b\n*** End Patch"}}`
	output, err := service.HandleChannelHook(ChannelCaller{CardID: waiter.ID}, []byte(event))
	if err != nil {
		t.Fatal(err)
	}
	var decision struct {
		Output struct {
			Decision string `json:"permissionDecision"`
			Reason   string `json:"permissionDecisionReason"`
		} `json:"hookSpecificOutput"`
	}
	if json.Unmarshal(output, &decision) != nil || decision.Output.Decision != "deny" || !strings.Contains(decision.Output.Reason, holder.ID) {
		t.Fatalf("hook output = %s", output)
	}
	if output, _ := service.HandleChannelHook(ChannelCaller{CardID: waiter.ID}, []byte(`{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"go test ./..."}}`)); len(output) != 0 {
		t.Fatalf("a read-only command got an opinion: %s", output)
	}
	// The holder hears that someone waits, once.
	waitSteer(t, runner, "wants to change src/module3.js")
	if _, err := service.HandleChannelHook(ChannelCaller{CardID: waiter.ID}, []byte(event)); err != nil {
		t.Fatal(err)
	}
	registered := false
	for _, claim := range service.ChannelClaims(project.ID) {
		registered = registered || claim.Path == "src/module3.js" && claim.CardID == holder.ID && len(claim.Waiting) == 1 && claim.Waiting[0] == waiter.ID
	}
	if !registered {
		t.Fatalf("claims = %+v, want the waiter registered on src/module3.js", service.ChannelClaims(project.ID))
	}
	close(runner.hold(waiter.ID))
	waitIdle(t, service, waiter.ID)
	// The waiter ended its turn waiting on a running holder: its own claim
	// (uncommitted work) stays parked instead of being released.
	waitFor(t, func() bool {
		for _, claim := range service.ChannelClaims(project.ID) {
			if claim.Path == "src/module5.js" && claim.CardID == waiter.ID && claim.Parked {
				return true
			}
		}
		return false
	})
	close(runner.hold(holder.ID))
	waitIdle(t, service, holder.ID)
	// The release wakes the idle waiter with the release message.
	waitFor(t, func() bool { return len(runner.turns(waiter.ID)) == 2 })
	woke := runner.turns(waiter.ID)[1]
	// Dieter states only what it observed; the holder's own words never
	// appear under Dieter's name.
	if !strings.Contains(woke.Prompt, "src/module3.js is free now") || !strings.Contains(woke.Prompt, "finished its turn") || strings.Contains(woke.Prompt, "finished the work") {
		t.Fatalf("wake prompt = %q", woke.Prompt)
	}
	waitIdle(t, service, waiter.ID)
	conversation, _ := service.Store.Conversations.Get(waiter.ID)
	var origin string
	for _, message := range conversation.Messages {
		if message.Role == "user" && model.IsChannelWakeMessage(message.ID) {
			var metadata map[string]string
			_ = json.Unmarshal(message.Metadata, &metadata)
			origin = metadata["origin"]
		}
	}
	if origin != "channel" {
		t.Fatalf("wake message origin = %q, want channel", origin)
	}
	if claims := service.ChannelClaims(project.ID); len(claims) != 0 {
		t.Fatalf("claims after both turns ended = %+v", claims)
	}
}

func TestObservedWriteToAHeldFileWarnsBothCards(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	enableChannels(t, service)
	holder := channelCard(t, service, project, board, "Holder")
	writer := channelCard(t, service, project, board, "Writer")
	startChannelTurn(t, service, holder, "hold write:src/app.go")
	waitFor(t, func() bool { return len(service.ChannelClaims(project.ID)) == 1 })
	startChannelTurn(t, service, writer, "hold write:src/app.go")
	waitSteers(t, runner, "You just changed src/app.go", "wants to change src/app.go")
	if claims := service.ChannelClaims(project.ID); len(claims) != 1 || claims[0].CardID != holder.ID {
		t.Fatalf("claims = %+v, want the holder to keep its claim", claims)
	}
}

func TestChannelWakeBudget(t *testing.T) {
	t.Parallel()
	service, _, _, _ := channelSetup(t)
	for i := 0; i < channelWakeChain+2; i++ {
		service.requestChannelWake("c_budget")
	}
	service.channels.mu.Lock()
	scheduled := len(service.channels.wakes["c_budget"])
	service.channels.mu.Unlock()
	if scheduled != channelWakeChain {
		t.Fatalf("scheduled %d wakes in a row, want %d", scheduled, channelWakeChain)
	}
	// A human message resets the chain; the hourly budget still applies.
	service.channelTurnStarted("c_budget", "msg_human")
	for i := 0; i < channelWakesPerHour; i++ {
		service.requestChannelWake("c_budget")
	}
	service.channels.mu.Lock()
	scheduled = len(service.channels.wakes["c_budget"])
	service.channels.mu.Unlock()
	if scheduled != channelWakesPerHour {
		t.Fatalf("scheduled %d wakes in an hour, want %d", scheduled, channelWakesPerHour)
	}
}

func TestChannelWritePathsAndRendering(t *testing.T) {
	t.Parallel()
	workspace := t.TempDir()
	if err := writeTestFile(filepath.Join(workspace, "src", "app.go")); err != nil {
		t.Fatal(err)
	}
	raw := func(value any) json.RawMessage { encoded, _ := json.Marshal(value); return encoded }
	for _, check := range []struct {
		tool  string
		input json.RawMessage
		want  string
	}{
		{"edit", raw(map[string]string{"file_path": filepath.Join(workspace, "src/app.go")}), "src/app.go"},
		{"Write", raw(map[string]string{"file_path": "docs/new.md"}), "docs/new.md"},
		{"fileChange", raw(map[string]string{"event": "modify", "path": "src/app.go"}), "src/app.go"},
		{"apply_patch", raw(map[string]string{"command": "*** Begin Patch\n*** Add File: a/b.txt\n*** Update File: src/app.go\n*** Move to: src/new.go\n*** End Patch"}), "a/b.txt,src/app.go,src/new.go"},
		{"Bash", raw(map[string]string{"command": "sed -i '' 's/a/b/' src/app.go && go test ./..."}), "src/app.go"},
		{"Bash", raw(map[string]string{"command": "echo '// reviewed' >> src/app.go"}), "src/app.go"},
		{"Bash", raw(map[string]string{"command": "cat src/app.go"}), ""},
		{"Bash", raw(map[string]string{"command": "git add src/app.go missing/nowhere.go"}), "src/app.go"},
		{"exec_command", raw(map[string]string{"cmd": "python3 - <<'PY'\nfrom pathlib import Path\np = Path('src/app.go')\np.write_text(p.read_text() + '// x')\nPY"}), "src/app.go"},
		{"Bash", raw(map[string]string{"command": "node -e \"require('fs').writeFileSync('src/app.go', 'x')\""}), "src/app.go"},
		{"Bash", raw(map[string]string{"command": "git restore --staged src/app.go"}), ""},
		{"Bash", raw(map[string]string{"command": "git reset --soft HEAD~1 && git status src/app.go"}), ""},
		{"edit", raw(map[string]string{"file_path": "/etc/passwd"}), ""},
		{"edit", raw(map[string]string{"file_path": "../outside.go"}), ""},
		{"read", raw(map[string]string{"file_path": "src/app.go"}), ""},
	} {
		if got := strings.Join(channelWritePaths(check.tool, check.input, workspace), ","); got != check.want {
			t.Fatalf("%s %s = %q, want %q", check.tool, check.input, got, check.want)
		}
	}
	long := strings.Repeat("x", 3000)
	messages := []model.ChannelMessage{
		{ID: "m_1", Kind: "request", Author: model.ChannelAuthor{Kind: model.ChannelAuthorAgent, CardID: "c_1", Title: `Bad "<title>"`}, Body: long, To: []string{"c_2"}},
	}
	for i := 0; i < 12; i++ {
		messages = append(messages, model.ChannelMessage{ID: "m_x", Kind: "note", Author: model.ChannelAuthor{Kind: model.ChannelAuthorHuman}, Body: long})
	}
	notice := renderChannelNotice("pricing", messages)
	if len(notice) > channelNoticeBytes+512 || strings.Contains(notice, `"<title>"`) || !strings.Contains(notice, `to="you"`) || !strings.Contains(notice, "truncated") {
		t.Fatalf("notice (%d bytes) = %q", len(notice), notice[:200])
	}
	digest := renderChannelDigest("pricing", messages)
	if len(digest) > channelDigestBytes+256 || !strings.Contains(digest, "more. Read them with: dieter channel inbox") {
		t.Fatalf("digest (%d bytes) = %q", len(digest), digest)
	}
}

func writeTestFile(path string) error {
	if err := mkdirAll(filepath.Dir(path)); err != nil {
		return err
	}
	return writeFile(path, "package app\n")
}

func (s *Service) turnHasChannelFor(cardID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	active := s.active[cardID]
	return active != nil && active.channel != nil && active.channel.steer != nil
}

func mkdirAll(path string) error { return os.MkdirAll(path, 0o755) }

func writeFile(path, content string) error { return os.WriteFile(path, []byte(content), 0o644) }

// The steer frame crosses the real worker boundary: Go writes it to the
// runner.mjs worker's stdin, the worker answers with a steer-result, and the
// accepted message becomes a peer notice in the transcript.
func TestChannelSteerThroughTheHarnessWorkerEndToEnd(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	runner, catalog := testkit.MockHarness(t, data.Root)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Steered", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	service := NewWithOptions(data, Options{Runner: runner, Catalog: catalog})
	if _, err := service.SetChannelSetting("project", project.ID, "on"); err != nil {
		t.Fatal(err)
	}
	chat, err := service.CreateChat(context.Background(), CardInput{
		Project: project.ID, Title: "Listener", Prompt: "mock-channel-steer", Provider: "mock", Model: "mock", DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(chat.ID, "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return service.turnHasChannelFor(chat.ID) })
	posted, err := service.PostChannelMessage(context.Background(), ChannelCaller{}, ChannelPost{ProjectID: project.ID, Body: "Release tag PAPAYA-7"})
	if err != nil {
		t.Fatal(err)
	}
	for update := range updates {
		if update.Err != nil {
			t.Fatal(update.Err)
		}
	}
	conversation, err := data.Conversations.Get(chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	last := conversation.Messages[len(conversation.Messages)-1]
	var notice, reply string
	for _, part := range last.Parts {
		switch part.Type {
		case conversations.PeerNoticePartType:
			notice = part.Text
		case "text":
			reply += part.Text
		}
	}
	if notice != posted.Body || !strings.Contains(reply, "Mock steered: <dieter-channel-message id=\""+posted.ID+"\"") || !strings.Contains(reply, "PAPAYA-7") {
		t.Fatalf("notice=%q reply=%q", notice, reply)
	}
	stored, _ := data.Channels.Message(project.ID, posted.ID)
	if len(stored.Deliveries) != 1 || stored.Deliveries[0].Mode != model.ChannelDeliverySteered {
		t.Fatalf("deliveries = %+v", stored.Deliveries)
	}
}

func TestCommitSweepGuardKeepsOtherCardsFilesOutOfACommit(t *testing.T) {
	t.Parallel()
	service, _, _, _ := channelSetup(t)
	repo := testkit.GitRepo(t)
	for _, name := range []string{"mine.go", "theirs.go"} {
		if err := writeFile(filepath.Join(repo, name), "package x\n"); err != nil {
			t.Fatal(err)
		}
	}
	git := func(args ...string) {
		t.Helper()
		command := exec.Command("git", append([]string{"-C", repo}, args...)...)
		command.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.invalid", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.invalid")
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, output)
		}
	}
	git("add", "mine.go", "theirs.go")
	if _, held := service.claimPaths("c_theirs", "Theirs", "p_1", repo, []string{"theirs.go"}); held {
		t.Fatal("unexpected conflict")
	}
	commit := func(command string) bool {
		input, _ := json.Marshal(map[string]string{"command": command})
		_, _, swept := service.commitSweep("c_mine", repo, "Bash", input)
		return swept
	}
	for _, check := range []struct {
		command string
		swept   bool
	}{
		{"git commit -m 'A: mine'", true},
		{"git add mine.go && git commit -m 'A: mine'", true},
		{"git commit -m 'A: mine' -- mine.go", false},
		{"git commit -m wip mine.go", false},
		{"git status && go test ./...", false},
	} {
		if got := commit(check.command); got != check.swept {
			t.Fatalf("%q swept = %v, want %v", check.command, got, check.swept)
		}
	}
	claim, files, _ := service.commitSweep("c_mine", repo, "Bash", json.RawMessage(`{"command":"git commit -am x"}`))
	if claim.CardID != "c_theirs" || len(files) != 1 || files[0] != "theirs.go" {
		t.Fatalf("sweep = %+v %v", claim, files)
	}
	if _, _, swept := service.commitSweep("c_theirs", repo, "Bash", json.RawMessage(`{"command":"git commit -m own"}`)); swept {
		t.Fatal("a card's own files swept its commit")
	}
}

func TestCheckRegistersTheWaiterAndTellsTheHolder(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	enableChannels(t, service)
	holder := channelCard(t, service, project, board, "Holder")
	checker := channelCard(t, service, project, board, "Checker")
	startChannelTurn(t, service, holder, "hold write:src/app.go")
	waitFor(t, func() bool { return len(service.ChannelClaims(project.ID)) == 1 })
	check, err := service.CheckChannelFiles(ChannelCaller{CardID: checker.ID}, "", []string{"src/app.go"}, "add a cap")
	if err != nil || len(check.Conflicts) != 1 || !strings.Contains(check.Summary, "being changed by agent "+holder.ID) {
		t.Fatalf("check = %+v, %v", check, err)
	}
	waitSteer(t, runner, "Agent "+checker.ID+" ('Checker') wants to change src/app.go")
	if claims := service.ChannelClaims(project.ID); len(claims[0].Waiting) != 1 || claims[0].Waiting[0] != checker.ID {
		t.Fatalf("claims = %+v", claims)
	}
}
