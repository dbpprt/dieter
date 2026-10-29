package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/security/localauth"
	boardstore "github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/schedules"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/proto"
)

// The showcase fixture is the workspace behind the website and README
// screenshots: four projects, a board shared by two online machines, an
// offline laptop, finished and unread conversations, schedules, provider
// usage and five agent turns that stay live. It runs only on loopback with
// disposable state and never contacts a model provider.
type showcase struct {
	home        string
	officeStore *boardstore.Store
	homeStore   *boardstore.Store
	projects    map[string]model.Project
	checkouts   map[string]string // machine + "/" + project name → checkout ID
	live        []showcaseLive
}

type showcaseLive struct {
	machine, cardID string
	chat            bool
	spec            showcaseCard
}

func (s *showcase) source(machine, name string) string {
	if machine == showcaseHome {
		return filepath.Join(s.home, "home", "src", name)
	}
	return filepath.Join(s.home, "office", "src", name)
}

// seedShowcaseOffice seeds the office machine before its daemon serves.
func seedShowcaseOffice(ctx context.Context, home string, data *boardstore.Store) (*showcase, model.Project, model.Board, error) {
	s := &showcase{home: home, officeStore: data, projects: map[string]model.Project{}, checkouts: map[string]string{}}
	if err := writeShowcaseShell(home); err != nil {
		return nil, model.Project{}, model.Board{}, err
	}
	for _, repo := range []struct {
		name, dir, summary string
		commits            []repoCommit
		pending            map[string]string
		board              showcaseBoard
	}{
		{"Atlas API", "atlas-api", "Public API: search, webhooks and billing", atlasCommits, atlasPending, atlasBoard},
		{"Storefront", "storefront", "Web shop: catalog, cart and checkout", storefrontCommits, storefrontPending, storefrontBoard},
		{"Pocket", "pocket", "Offline-first notes for Android and iOS", pocketCommits, nil, pocketBoard},
	} {
		dir := s.source(showcaseOffice, repo.dir)
		if err := createShowcaseRepo(ctx, dir, repo.commits, repo.pending); err != nil {
			return nil, model.Project{}, model.Board{}, err
		}
		project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: repo.name, Path: dir, Summary: repo.summary, BaseBranch: "main", InitialBoardName: repo.board.name})
		if err != nil {
			return nil, model.Project{}, model.Board{}, err
		}
		s.projects[repo.name] = project
		s.checkouts[showcaseOffice+"/"+repo.name] = project.Checkouts[0].ID
	}
	// Warm the build cache so the terminal's test run reads like a normal one.
	warm := exec.CommandContext(ctx, "go", "test", "-run", "^$", "./...")
	warm.Dir = s.source(showcaseOffice, "atlas-api")
	if output, err := warm.CombinedOutput(); err != nil {
		return nil, model.Project{}, model.Board{}, fmt.Errorf("warm the showcase build cache: %s: %w", output, err)
	}
	for _, board := range []showcaseBoard{atlasBoard, storefrontBoard, pocketBoard} {
		if err := s.seedBoard(data, showcaseOffice, board, true); err != nil {
			return nil, model.Project{}, model.Board{}, err
		}
	}
	if err := s.seedChats(data, showcaseOffice); err != nil {
		return nil, model.Project{}, model.Board{}, err
	}
	for _, schedule := range showcaseSchedules {
		project := s.projects[schedule.project]
		board, err := s.board(data, project, schedule.board)
		if err != nil {
			return nil, model.Project{}, model.Board{}, err
		}
		if _, err = data.Schedules.Create(schedules.Input{
			Project: project.ID, Board: board.ID, CheckoutID: s.checkouts[showcaseOffice+"/"+schedule.project], Name: schedule.name, Description: schedule.description,
			Cron: schedule.cron, Timezone: "Europe/Berlin", Action: schedule.action, TitleTemplate: schedule.title, PromptTemplate: schedule.prompt,
			Provider: schedule.agent[0], Model: schedule.agent[1], Effort: schedule.agent[2], WorkspaceMode: model.WorkspaceModeWorktree, Enabled: schedule.enabled,
		}); err != nil {
			return nil, model.Project{}, model.Board{}, err
		}
	}
	atlas := s.projects["Atlas API"]
	board, err := s.board(data, atlas, atlasBoard.name)
	if err != nil {
		return nil, model.Project{}, model.Board{}, err
	}
	if err := seedShowcaseMail(data, atlas, board); err != nil {
		return nil, model.Project{}, model.Board{}, err
	}
	return s, atlas, board, nil
}

func (s *showcase) board(data *boardstore.Store, project model.Project, name string) (model.Board, error) {
	boards, err := data.Kanban.ListBoards(project.ID)
	if err != nil {
		return model.Board{}, err
	}
	for _, board := range boards {
		if board.Name == name {
			return board, nil
		}
	}
	return model.Board{}, fmt.Errorf("board %s/%s not found", project.Name, name)
}

// seedBoard creates the board's labels (once, on its first machine) and the
// cards that run on machine.
func (s *showcase) seedBoard(data *boardstore.Store, machine string, spec showcaseBoard, createLabels bool) error {
	project := s.projects[spec.project]
	board, err := s.board(data, project, spec.name)
	if err != nil {
		return err
	}
	if createLabels {
		for _, label := range spec.labels {
			if board, err = data.Kanban.CreateBoardLabel(board.ID, label.name, label.color); err != nil {
				return err
			}
		}
	}
	labels := map[string]string{}
	for _, label := range board.Labels {
		labels[label.Name] = label.ID
	}
	// Boards list newest first: seed bottom-up so the first card is on top.
	for index := len(spec.cards) - 1; index >= 0; index-- {
		card := spec.cards[index]
		if card.machine != machine {
			continue
		}
		var ids []string
		for _, name := range card.labels {
			ids = append(ids, labels[name])
		}
		if err := s.seedCard(data, machine, project, &board, ids, card); err != nil {
			return fmt.Errorf("seed %q: %w", card.title, err)
		}
	}
	return nil
}

func (s *showcase) seedChats(data *boardstore.Store, machine string) error {
	for index := len(showcaseChats) - 1; index >= 0; index-- {
		chat := showcaseChats[index]
		if chat.card.machine != machine {
			continue
		}
		if err := s.seedCard(data, machine, s.projects[chat.project], nil, nil, chat.card); err != nil {
			return fmt.Errorf("seed %q: %w", chat.card.title, err)
		}
	}
	return nil
}

func (s *showcase) seedCard(data *boardstore.Store, machine string, project model.Project, board *model.Board, labels []string, spec showcaseCard) error {
	prompt := ""
	if spec.live != "" && board != nil {
		prompt = showcaseLiveTurns[spec.live].Prompt
	} else if len(spec.exchanges) > 0 {
		prompt = spec.exchanges[0].prompt
	}
	input := kanban.CreateCardInput{
		Project: project.ID, CheckoutID: s.checkouts[machine+"/"+project.Name], Title: spec.title, Prompt: prompt,
		Provider: spec.provider, Model: spec.model, Effort: spec.effort, WorkspaceMode: model.WorkspaceModeProject,
	}
	if spec.live == "go-upgrade" {
		// A second live task on the same checkout gets its own worktree.
		input.WorkspaceMode = model.WorkspaceModeWorktree
	}
	var card model.Card
	var err error
	if board != nil {
		input.Board, input.Lane, input.LabelIDs = board.ID, "todo", labels
		card, err = data.Kanban.CreateCard(input)
	} else {
		card, err = data.Kanban.CreateChat(input)
	}
	if err != nil {
		return err
	}
	if spec.pinned {
		if card, err = data.Kanban.PinChat(card.ID, true); err != nil {
			return err
		}
	}
	if spec.live != "" {
		s.live = append(s.live, showcaseLive{machine: machine, cardID: card.ID, chat: board == nil, spec: spec})
		return nil
	}
	started := time.Now().Add(-spec.ago)
	if len(spec.exchanges) > 0 && spec.exchanges[0].answer != "" {
		if _, err = data.Kanban.MarkPromptSent(card.ID); err != nil {
			return err
		}
		for index, exchange := range spec.exchanges {
			if err = recordShowcaseExchange(data, card.ID, index, started.Add(time.Duration(index)*20*time.Minute), exchange); err != nil {
				return err
			}
		}
		if _, err = data.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{Runtime: model.RuntimeIdle, Summary: spec.summary}); err != nil {
			return err
		}
		if card, err = data.Kanban.ResolveCard(card.ID); err != nil {
			return err
		}
		if !spec.unread {
			if card, err = data.Conversations.MarkRead(card.ID, card.ResponseSeq); err != nil {
				return err
			}
		}
	}
	// Starting a turn moves a card to Running; place it once its history exists.
	if board != nil && spec.lane != "todo" {
		if _, err = data.Kanban.MoveCard(card.ID, spec.lane, nil); err != nil {
			return err
		}
	}
	return backdateShowcaseCard(data, card.ID, started)
}

// recordShowcaseExchange writes one finished turn through the conversation
// journal, exactly as a harness worker's stream would be recorded.
func recordShowcaseExchange(data *boardstore.Store, cardID string, index int, at time.Time, exchange showcaseExchange) error {
	turnID := fmt.Sprintf("turn_showcase_%d", index)
	userID, replyID := fmt.Sprintf("msg_user_%d", index), fmt.Sprintf("msg_reply_%d", index)
	metadata, err := json.Marshal(map[string]string{"createdAt": at.UTC().Format(time.RFC3339Nano)})
	if err != nil {
		return err
	}
	user := model.UIMessage{ID: userID, Role: "user", Metadata: metadata, Parts: []model.UIMessagePart{{Type: "text", Text: exchange.prompt}}}
	if _, _, err = data.Conversations.Append(cardID, "user-message", turnID, userID, user); err != nil {
		return err
	}
	replyAt := at.Add(90 * time.Second).UTC().Format(time.RFC3339Nano)
	chunks := []map[string]any{{"type": "start", "messageId": replyID, "messageMetadata": map[string]any{"createdAt": replyAt}}, {"type": "start-step"}}
	if exchange.reasoning != "" {
		chunks = append(chunks, map[string]any{"type": "reasoning-start", "id": "r"}, map[string]any{"type": "reasoning-delta", "id": "r", "delta": exchange.reasoning}, map[string]any{"type": "reasoning-end", "id": "r"})
	}
	for toolIndex, tool := range exchange.tools {
		id := fmt.Sprintf("call_%d_%d", index, toolIndex)
		output := map[string]any{"output": tool.output}
		if tool.commandOutput {
			output["exitCode"] = 0
		}
		chunks = append(chunks,
			map[string]any{"type": "tool-input-available", "toolCallId": id, "toolName": tool.name, "input": tool.input},
			map[string]any{"type": "tool-output-available", "toolCallId": id, "output": output})
	}
	usage := map[string]any{"inputTokens": exchange.tokens - exchange.tokens/12, "outputTokens": exchange.tokens / 12, "totalTokens": exchange.tokens}
	finish := map[string]any{"createdAt": replyAt, "usage": usage, "contextWindowTokens": 400000}
	chunks = append(chunks,
		map[string]any{"type": "text-start", "id": "t"}, map[string]any{"type": "text-delta", "id": "t", "delta": exchange.answer}, map[string]any{"type": "text-end", "id": "t"},
		map[string]any{"type": "finish-step", "usage": usage},
		map[string]any{"type": "message-metadata", "messageMetadata": finish},
		map[string]any{"type": "finish", "finishReason": "stop", "messageMetadata": finish})
	raw := make([]json.RawMessage, len(chunks))
	for chunkIndex, chunk := range chunks {
		if raw[chunkIndex], err = json.Marshal(chunk); err != nil {
			return err
		}
	}
	_, _, err = data.Conversations.AppendUIChunks(cardID, turnID, raw)
	return err
}

// backdateShowcaseCard gives seeded history its place in time, so feeds and
// boards read like a week of work instead of one second of seeding.
func backdateShowcaseCard(data *boardstore.Store, cardID string, started time.Time) error {
	release, err := data.BeginWrite()
	if err != nil {
		return err
	}
	defer release()
	card, err := data.Kanban.ResolveCard(cardID)
	if err != nil {
		return err
	}
	created := started.Add(-3 * time.Minute).UTC().Format(time.RFC3339Nano)
	finished := started.Add(4 * time.Minute).UTC().Format(time.RFC3339Nano)
	card.CreatedAt, card.UpdatedAt, card.PhaseChangedAt = created, finished, finished
	card.LastActivityAt, card.RuntimeUpdatedAt = finished, finished
	if card.InitialPromptSentAt != "" {
		card.InitialPromptSentAt = started.UTC().Format(time.RFC3339Nano)
	}
	_, err = data.Kanban.SaveCard(card)
	return err
}

// writeShowcaseShell gives the fixture's host terminals a short, neutral prompt.
func writeShowcaseShell(home string) error {
	return os.WriteFile(filepath.Join(home, ".zshrc"), []byte("PROMPT='%F{green}office%f %F{cyan}%1~%f %# '\nexport CLICOLOR=1\nunsetopt BEEP\n"), 0o644)
}

type showcaseEnvironment struct {
	logger                     *slog.Logger
	gateway                    *topology.Gateway
	enroll                     func(role, root, name string) (*link.Identity, error)
	newServer                  func(*boardstore.Store) *api.Server
	account, subject           string
	office                     *link.Identity
	officeAddress, officeToken string
	primaryTrust               *link.Trust // The office machine; it started the device roster.
	trusts                     map[*boardstore.Store]*link.Trust
}

// connect brings the home machine online and into the device roster, enrolls
// the offline laptop, replicates the shared board between both machines and
// starts the live turns.
func (s *showcase) connect(ctx context.Context, env showcaseEnvironment) error {
	root := filepath.Join(s.home, "home-dieter")
	s.homeStore = boardstore.New(root)
	if err := s.homeStore.Ensure(); err != nil {
		return err
	}
	identity, err := env.enroll("home", root, showcaseHome)
	if err != nil {
		return err
	}
	homeTrust, err := fixtureTrust(ctx, identity, env.logger)
	if err != nil {
		return err
	}
	env.trusts[s.homeStore] = homeTrust
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	server := &http.Server{Handler: env.newServer(s.homeStore).Handler(), Protocols: api.LoopbackProtocols()}
	go func() { _ = server.Serve(listener) }()
	go func() {
		<-ctx.Done()
		_ = server.Close()
	}()
	if _, err = s.homeStore.Replica.BindPeerAccount(env.account, env.subject, identity.ID, identity.GatewayURL); err != nil {
		return err
	}
	token, err := localauth.Ensure(s.homeStore.Root)
	if err != nil {
		return err
	}
	endpoint, err := fixtureEndpoint(identity, homeTrust, listener.Addr().String(), token)
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		endpoint.Server.Stop()
	}()
	tunnel := &link.GatewayClient{Identity: identity, TunnelTarget: endpoint.Listener.Addr().String(), Version: buildinfo.ReleaseVersion, Log: env.logger}
	go func() { _ = tunnel.Run(ctx) }()
	for _, id := range []string{env.office.ID, identity.ID} {
		if err = env.gateway.WaitRelay(ctx, id); err != nil {
			return err
		}
	}
	if err = topology.Pair(ctx, env.primaryTrust, homeTrust); err != nil {
		return fmt.Errorf("pair the home machine: %w", err)
	}

	laptop, err := env.enroll("laptop", filepath.Join(s.home, "laptop-dieter"), showcaseLaptop)
	if err != nil {
		return err
	}
	if err = env.gateway.Store.MarkDaemonSeen(laptop.ID, buildinfo.ReleaseVersion, []byte("[]"), []byte("{}")); err != nil {
		return err
	}
	if _, err = env.gateway.Store.DB.Exec(`UPDATE daemons SET last_seen_at=? WHERE id=?`, time.Now().Add(-3*time.Hour).UTC().Format(time.RFC3339Nano), laptop.ID); err != nil {
		return err
	}

	officeSync := &peersync.PeerSync{Identity: env.office, Trust: env.primaryTrust, Store: s.officeStore, Log: env.logger, Interval: 5 * time.Second}
	if err = officeSync.Round(ctx); err != nil {
		return fmt.Errorf("replicate the office projects: %w", err)
	}
	if err = s.seedHome(ctx); err != nil {
		return err
	}
	if err = officeSync.Round(ctx); err != nil {
		return fmt.Errorf("replicate the home projects: %w", err)
	}
	go officeSync.Run(ctx)
	go (&peersync.PeerSync{Identity: identity, Trust: homeTrust, Store: s.homeStore, Log: env.logger, Interval: 5 * time.Second}).Run(ctx)

	clients := map[string]dieterclient.ConnectClient{
		showcaseOffice: localConnectClient(env.officeAddress, env.officeToken),
		showcaseHome:   localConnectClient(listener.Addr().String(), token),
	}
	for _, live := range s.live {
		client := clients[live.machine]
		if live.chat {
			_, err = client.SendMessage(ctx, &dieterv1.SendMessageRequest{
				CardId: live.cardID, Parts: []*dieterv1.MessagePart{{Type: "text", Text: showcaseLiveTurns[live.spec.live].Prompt}},
				Provider: live.spec.provider, Model: live.spec.model, Effort: live.spec.effort,
				ClientId: "showcase-fixture", CommandId: "send-" + live.cardID, MessageId: "msg_live_" + live.cardID,
			})
		} else {
			_, err = client.StartCard(ctx, &dieterv1.StartCardRequest{CardId: live.cardID, ClientId: "showcase-fixture", CommandId: "start-" + live.cardID})
		}
		if err != nil {
			return fmt.Errorf("start live card %s: %w", live.cardID, err)
		}
		time.Sleep(1500 * time.Millisecond)
	}
	return s.openTerminal(ctx, clients[showcaseOffice])
}

// seedHome clones the shared project, adds the home machine's own project and its cards.
func (s *showcase) seedHome(ctx context.Context) error {
	atlas, err := s.homeStore.Kanban.ResolveProject(s.projects["Atlas API"].ID)
	if err != nil {
		return fmt.Errorf("the shared project did not replicate: %w", err)
	}
	clone := s.source(showcaseHome, "atlas-api")
	if err = showcaseGit(ctx, "", time.Time{}, "clone", "-q", s.source(showcaseOffice, "atlas-api"), clone); err != nil {
		return err
	}
	if err = showcaseGit(ctx, clone, time.Time{}, "checkout", "-q", "--", "."); err != nil {
		return err
	}
	if err = writeRepoFiles(clone, atlasMiniPending); err != nil {
		return err
	}
	checkout, err := s.homeStore.Kanban.AttachCheckout(atlas.ID, clone, "atlas-api")
	if err != nil {
		return err
	}
	s.checkouts[showcaseHome+"/Atlas API"] = checkout.ID

	homelab := s.source(showcaseHome, "homelab")
	if err = createShowcaseRepo(ctx, homelab, homelabCommits, nil); err != nil {
		return err
	}
	project, err := s.homeStore.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Homelab", Path: homelab, Summary: "k3s cluster, backups and home automation", BaseBranch: "main", InitialBoardName: homelabBoard.name})
	if err != nil {
		return err
	}
	s.projects["Homelab"] = project
	s.checkouts[showcaseHome+"/Homelab"] = project.Checkouts[0].ID
	if err = s.seedBoard(s.homeStore, showcaseHome, atlasBoard, false); err != nil {
		return err
	}
	if err = s.seedBoard(s.homeStore, showcaseHome, homelabBoard, true); err != nil {
		return err
	}
	if err = s.seedChats(s.homeStore, showcaseHome); err != nil {
		return err
	}
	board, err := s.board(s.homeStore, project, homelabBoard.name)
	if err != nil {
		return err
	}
	_, err = s.homeStore.Schedules.Create(schedules.Input{
		Project: project.ID, Board: board.ID, CheckoutID: project.Checkouts[0].ID, Name: "Check last night's backup", Description: "Restore the latest snapshot and verify it",
		Cron: "0 7 * * *", Timezone: "Europe/Berlin", Action: model.ScheduleActionRun, TitleTemplate: "Backup check {{date}}",
		PromptTemplate: "Restore the latest restic snapshot to a scratch volume and verify it.", Provider: "claude-code", Model: "sonnet", Effort: "medium",
		WorkspaceMode: model.WorkspaceModeProject, Enabled: true,
	})
	return err
}

// openTerminal leaves a host-owned shell on the office machine with real output.
func (s *showcase) openTerminal(ctx context.Context, client dieterclient.ConnectClient) error {
	atlas := s.projects["Atlas API"]
	terminal, err := client.CreateTerminal(ctx, &dieterv1.CreateTerminalRequest{
		ProjectId: atlas.ID, CheckoutId: s.checkouts[showcaseOffice+"/Atlas API"], Name: "atlas-api", Columns: 132, Rows: 40,
	})
	if err != nil {
		return err
	}
	time.Sleep(time.Second)
	for _, command := range []string{"git log --oneline -5", "git status --short", "go test -count=1 ./..."} {
		if _, err = client.WriteTerminal(ctx, &dieterv1.TerminalInputRequest{TerminalId: terminal.GetId(), Data: []byte(command + "\n")}); err != nil {
			return err
		}
		time.Sleep(2 * time.Second)
	}
	return nil
}

type localTokenTransport struct {
	token string
	base  http.RoundTripper
}

func (t localTokenTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	request = request.Clone(request.Context())
	request.Header.Set(localauth.Header, t.token)
	return t.base.RoundTrip(request)
}

func localConnectClient(address, token string) dieterclient.ConnectClient {
	return dieterclient.NewConnect(&http.Client{Transport: localTokenTransport{token: token, base: http.DefaultTransport}}, "http://"+address)
}

// showcaseUsageQuotas reports one Codex and one Claude subscription.
type showcaseUsageQuotas struct{}

func (showcaseUsageQuotas) Discover(_ context.Context, key []byte) (*gatewayv1.ProviderAccountsPresence, error) {
	var accounts []*gatewayv1.ProviderAccountPresence
	for _, provider := range []gatewayv1.ProviderQuotaProvider{gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE} {
		accounts = append(accounts, &gatewayv1.ProviderAccountPresence{
			Provider: provider, AccountKey: showcaseAccountKey(key, provider), AccountKind: gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION,
			Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, RefreshSupported: true,
		})
	}
	return &gatewayv1.ProviderAccountsPresence{Accounts: accounts}, nil
}

func (showcaseUsageQuotas) Refresh(_ context.Context, key []byte, request *gatewayv1.ProviderQuotaRefreshRequest) (*gatewayv1.ProviderQuotaRefreshResult, error) {
	provider := request.GetProvider()
	if request.GetAccountKey() != showcaseAccountKey(key, provider) {
		return &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "unknown_account"}, nil
	}
	plan, windows := "pro", []*gatewayv1.ProviderQuotaWindow{
		{Id: "five-hour", Label: "5 hours", RemainingPercent: proto.Uint32(81), ResetsAt: time.Now().Add(2*time.Hour + 14*time.Minute).UTC().Format(time.RFC3339)},
		{Id: "weekly", Label: "Weekly", RemainingPercent: proto.Uint32(64), ResetsAt: time.Now().Add(3*24*time.Hour + 5*time.Hour).UTC().Format(time.RFC3339)},
	}
	if provider == gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE {
		plan = "max"
		windows = []*gatewayv1.ProviderQuotaWindow{
			{Id: "five-hour", Label: "5 hours", RemainingPercent: proto.Uint32(57), ResetsAt: time.Now().Add(3*time.Hour + 40*time.Minute).UTC().Format(time.RFC3339)},
			{Id: "weekly", Label: "Weekly", RemainingPercent: proto.Uint32(42), ResetsAt: time.Now().Add(4*24*time.Hour + 2*time.Hour).UTC().Format(time.RFC3339)},
		}
	}
	return &gatewayv1.ProviderQuotaRefreshResult{Snapshot: &gatewayv1.ProviderQuotaSnapshot{
		Provider: provider, AccountKey: request.GetAccountKey(), AccountKind: gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION,
		Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, DisplayEmail: "alex@example.com", Plan: plan, Windows: windows,
	}}, nil
}

func showcaseAccountKey(key []byte, provider gatewayv1.ProviderQuotaProvider) string {
	return usageAccountKey(append(append([]byte(nil), key...), byte(provider)))
}
