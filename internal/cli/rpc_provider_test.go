package cli

import (
	"bytes"
	"context"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/config"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

const (
	signedIn  = dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN
	expired   = dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_EXPIRED
	waiting   = dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_WAITING
	succeeded = dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_SUCCEEDED
)

// fakeProviderClient is the daemon API as the provider commands and the
// --account flags see it. Unused services stay nil and panic if called.
type fakeProviderClient struct {
	dieterclient.Client
	mu       sync.Mutex
	calls    []string
	accounts []*dieterv1.ProviderAccount

	created   *dieterv1.CreateProviderAccountRequest
	updated   *dieterv1.UpdateProviderAccountRequest
	started   *dieterv1.StartProviderLoginRequest
	start     *dieterv1.ProviderLogin
	events    chan *dieterv1.ProviderLogin
	submitted []*dieterv1.SubmitProviderLoginInputRequest
	onSubmit  func(*dieterv1.SubmitProviderLoginInputRequest) (*dieterv1.ProviderLogin, error)
	canceled  []string
	checked   *dieterv1.ProviderAccount
	refreshed []string
	reset     *dieterv1.ConsumeProviderUsageResetRequest
	outcome   string
	token     *dieterv1.GetProviderTurnTokenRequest

	state       *dieterv1.State
	card        *dieterv1.CardDetail
	sent        *dieterv1.SendMessageRequest
	createdChat *dieterv1.CreateConversationRequest
	updatedCard *dieterv1.UpdateCardRequest
	schedule    *dieterv1.SaveScheduleRequest
}

func (f *fakeProviderClient) record(call string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, call)
}

func (f *fakeProviderClient) callList() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func (f *fakeProviderClient) ListProviderAccounts(_ context.Context, in *dieterv1.ListProviderAccountsRequest, _ ...grpc.CallOption) (*dieterv1.ListProviderAccountsResponse, error) {
	f.record("list")
	var accounts []*dieterv1.ProviderAccount
	for _, account := range f.accounts {
		if in.GetProvider() == dieterv1.ProviderKind_PROVIDER_KIND_UNSPECIFIED || account.GetProvider() == in.GetProvider() {
			accounts = append(accounts, account)
		}
	}
	return &dieterv1.ListProviderAccountsResponse{Accounts: accounts}, nil
}

func (f *fakeProviderClient) CreateProviderAccount(_ context.Context, in *dieterv1.CreateProviderAccountRequest, _ ...grpc.CallOption) (*dieterv1.ProviderAccount, error) {
	f.record("create")
	f.created = in
	return &dieterv1.ProviderAccount{Id: "pa_new", Provider: in.GetProvider(), Label: in.GetLabel(), Method: in.GetMethod()}, nil
}

func (f *fakeProviderClient) UpdateProviderAccount(_ context.Context, in *dieterv1.UpdateProviderAccountRequest, _ ...grpc.CallOption) (*dieterv1.ProviderAccount, error) {
	f.record("update")
	f.updated = in
	return &dieterv1.ProviderAccount{Id: in.GetAccountId(), Label: in.GetLabel(), OmpAccess: in.GetOmpAccess()}, nil
}

func (f *fakeProviderClient) DeleteProviderAccount(_ context.Context, in *dieterv1.DeleteProviderAccountRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	f.record("delete " + in.GetAccountId())
	return &emptypb.Empty{}, nil
}

func (f *fakeProviderClient) SetDefaultProviderAccount(_ context.Context, in *dieterv1.SetDefaultProviderAccountRequest, _ ...grpc.CallOption) (*dieterv1.ProviderAccount, error) {
	f.record("default " + in.GetAccountId())
	return &dieterv1.ProviderAccount{Id: in.GetAccountId(), IsDefault: true}, nil
}

func (f *fakeProviderClient) StartProviderLogin(_ context.Context, in *dieterv1.StartProviderLoginRequest, _ ...grpc.CallOption) (*dieterv1.ProviderLogin, error) {
	f.record("start")
	f.started = in
	return f.start, nil
}

func (f *fakeProviderClient) WatchProviderLogin(ctx context.Context, in *dieterv1.WatchProviderLoginRequest, _ ...grpc.CallOption) (grpc.ServerStreamingClient[dieterv1.ProviderLogin], error) {
	f.record("watch " + in.GetLoginId())
	return &fakeLoginStream{ctx: ctx, events: f.events}, nil
}

func (f *fakeProviderClient) SubmitProviderLoginInput(_ context.Context, in *dieterv1.SubmitProviderLoginInputRequest, _ ...grpc.CallOption) (*dieterv1.ProviderLogin, error) {
	f.record("submit")
	f.mu.Lock()
	f.submitted = append(f.submitted, in)
	f.mu.Unlock()
	return f.onSubmit(in)
}

func (f *fakeProviderClient) CancelProviderLogin(_ context.Context, in *dieterv1.CancelProviderLoginRequest, _ ...grpc.CallOption) (*dieterv1.ProviderLogin, error) {
	f.record("cancel")
	f.mu.Lock()
	f.canceled = append(f.canceled, in.GetLoginId())
	f.mu.Unlock()
	return &dieterv1.ProviderLogin{LoginId: in.GetLoginId(), Phase: dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_CANCELED}, nil
}

func (f *fakeProviderClient) SignOutProviderAccount(_ context.Context, in *dieterv1.SignOutProviderAccountRequest, _ ...grpc.CallOption) (*dieterv1.ProviderAccount, error) {
	f.record("signout " + in.GetAccountId())
	return &dieterv1.ProviderAccount{Id: in.GetAccountId()}, nil
}

func (f *fakeProviderClient) CheckProviderLogin(_ context.Context, in *dieterv1.CheckProviderLoginRequest, _ ...grpc.CallOption) (*dieterv1.ProviderAccount, error) {
	f.record("check " + in.GetAccountId())
	return f.checked, nil
}

func (f *fakeProviderClient) RefreshProviderUsage(_ context.Context, in *dieterv1.RefreshProviderUsageRequest, _ ...grpc.CallOption) (*dieterv1.ProviderAccount, error) {
	f.record("refresh " + in.GetAccountId())
	f.refreshed = append(f.refreshed, in.GetAccountId())
	for _, account := range f.accounts {
		if account.GetId() == in.GetAccountId() {
			return &dieterv1.ProviderAccount{Id: account.GetId(), Label: account.GetLabel(), Provider: account.GetProvider(),
				Usage: &dieterv1.ProviderUsage{Plan: "max", ObservedAt: "2026-11-14T12:00:00Z", Source: "probe", Windows: []*dieterv1.ProviderUsageWindow{{Kind: "weekly", UsedPercent: 10}}}}, nil
		}
	}
	return nil, status.Error(codes.NotFound, "unknown account")
}

func (f *fakeProviderClient) ConsumeProviderUsageReset(_ context.Context, in *dieterv1.ConsumeProviderUsageResetRequest, _ ...grpc.CallOption) (*dieterv1.ConsumeProviderUsageResetResponse, error) {
	f.record("reset")
	f.reset = in
	return &dieterv1.ConsumeProviderUsageResetResponse{Outcome: f.outcome}, nil
}

func (f *fakeProviderClient) GetProviderTurnToken(_ context.Context, in *dieterv1.GetProviderTurnTokenRequest, _ ...grpc.CallOption) (*dieterv1.ProviderTurnToken, error) {
	f.record("token")
	f.token = in
	switch in.GetProvider() {
	case dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE:
		return &dieterv1.ProviderTurnToken{Token: "sk-ant-oat01-turn"}, nil
	case dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT:
		return &dieterv1.ProviderTurnToken{Token: "chatgpt-access-token"}, nil
	}
	return &dieterv1.ProviderTurnToken{Token: "siwc-access-token", ExpiresAt: "2026-11-14T13:00:00Z"}, nil
}

func (f *fakeProviderClient) GetState(context.Context, *dieterv1.GetStateRequest, ...grpc.CallOption) (*dieterv1.State, error) {
	return f.state, nil
}

func (f *fakeProviderClient) GetCard(context.Context, *dieterv1.GetCardRequest, ...grpc.CallOption) (*dieterv1.CardDetail, error) {
	return f.card, nil
}

func (f *fakeProviderClient) SendMessage(_ context.Context, in *dieterv1.SendMessageRequest, _ ...grpc.CallOption) (*dieterv1.SendMessageResponse, error) {
	f.record("send")
	f.sent = in
	return &dieterv1.SendMessageResponse{}, nil
}

func (f *fakeProviderClient) CreateChat(_ context.Context, in *dieterv1.CreateConversationRequest, _ ...grpc.CallOption) (*dieterv1.Card, error) {
	f.createdChat = in
	return &dieterv1.Card{Id: "c_chat"}, nil
}

func (f *fakeProviderClient) UpdateCard(_ context.Context, in *dieterv1.UpdateCardRequest, _ ...grpc.CallOption) (*dieterv1.Card, error) {
	f.updatedCard = in
	return &dieterv1.Card{Id: in.GetCardId()}, nil
}

func (f *fakeProviderClient) CreateSchedule(_ context.Context, in *dieterv1.SaveScheduleRequest, _ ...grpc.CallOption) (*dieterv1.Schedule, error) {
	f.schedule = in
	return &dieterv1.Schedule{Id: "s_one"}, nil
}

type fakeLoginStream struct {
	grpc.ClientStream
	ctx    context.Context
	events <-chan *dieterv1.ProviderLogin
}

func (s *fakeLoginStream) Recv() (*dieterv1.ProviderLogin, error) {
	select {
	case event, ok := <-s.events:
		if !ok {
			return nil, io.EOF
		}
		return event, nil
	case <-s.ctx.Done():
		return nil, status.FromContextError(s.ctx.Err()).Err()
	}
}

func providerAccounts() []*dieterv1.ProviderAccount {
	return []*dieterv1.ProviderAccount{
		{
			Id: "pa_work", Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "Work", Method: dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CLAUDE_CODE,
			Identity: &dieterv1.ProviderIdentity{Email: "me@example.com", Organization: "Acme"}, IsDefault: true, IncludeInSummary: true, OmpAccess: true,
			Logins: []*dieterv1.ProviderMachineLogin{
				{DaemonId: "d_here", State: signedIn, Identity: &dieterv1.ProviderIdentity{Email: "me@example.com"}, VerifiedAt: "2026-11-14T10:00:00Z"},
				{DaemonId: "d_two", State: signedIn},
				{DaemonId: "d_three", State: expired, ErrorMessage: "token expired"},
			},
			Usage: &dieterv1.ProviderUsage{Plan: "max", ObservedAt: "2026-11-14T11:00:00Z", Source: "turn", Windows: []*dieterv1.ProviderUsageWindow{
				{Kind: "five_hour", UsedPercent: 12, ResetsAt: "2026-11-14T15:00:00Z"},
				{Kind: "weekly", Label: "Weekly", UsedPercent: 37.6, ResetsAt: "2026-11-20T09:00:00Z"},
			}},
			DieterTokens: &dieterv1.ProviderTokenUsage{FiveHour: &dieterv1.ProviderTokenTotals{InputTokens: 100, OutputTokens: 20, TotalTokens: 120}},
		},
		{Id: "pa_home", Provider: dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT, Label: "Home", Method: dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CODEX,
			Usage: &dieterv1.ProviderUsage{Unavailable: "signed_out"}},
		{Id: "pa_twin1", Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "Twin"},
		{Id: "pa_twin2", Provider: dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT, Label: "twin"},
	}
}

// providerCLI connects a CLI to fake as if it were the local daemon d_here,
// outside any agent turn.
func providerCLI(t *testing.T, fake *fakeProviderClient) (*CLI, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	if fake.accounts == nil {
		fake.accounts = providerAccounts()
	}
	c := New(t.TempDir())
	c.env = config.Client{}
	var out, errOut bytes.Buffer
	c.Out, c.Err, c.In = &out, &errOut, strings.NewReader("")
	c.transport = &dieterTransport{client: fake, route: "local", daemonID: "d_here"}
	return c, &out, &errOut
}

func TestProviderListShowsTightestWindowAndMachines(t *testing.T) {
	t.Parallel()
	fake := &fakeProviderClient{}
	c, out, _ := providerCLI(t, fake)
	if err := c.Run([]string{"provider", "list"}); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 5 || strings.Join(strings.Fields(lines[0]), " ") != "ID PROVIDER LABEL METHOD DEFAULT OMP IDENTITY USAGE MACHINES" {
		t.Fatalf("table:\n%s", out.String())
	}
	work := strings.Join(strings.Fields(lines[1]), " ")
	if work != "pa_work claude Work claude-code yes on me@example.com (Acme) 62% left 2/3 signed in" {
		t.Fatalf("work row = %q", work)
	}
	home := strings.Join(strings.Fields(lines[2]), " ")
	if home != "pa_home chatgpt Home codex - - signed out not signed in" {
		t.Fatalf("home row = %q", home)
	}
	if twin := strings.Join(strings.Fields(lines[3]), " "); !strings.HasPrefix(twin, "pa_twin1 claude Twin - off ") {
		t.Fatalf("twin row = %q", twin)
	}

	out.Reset()
	if err := c.Run([]string{"provider", "list", "--provider", "chatgpt", "--format", "ids"}); err != nil {
		t.Fatal(err)
	}
	if out.String() != "pa_home\npa_twin2\n" {
		t.Fatalf("chatgpt ids = %q", out.String())
	}
	if err := c.Run([]string{"provider", "list", "--provider", "openai"}); err == nil || !strings.Contains(err.Error(), "claude or chatgpt") {
		t.Fatalf("unknown provider: %v", err)
	}
	out.Reset()
	if err := c.Run([]string{"providers", "list", "--format", "jsonl"}); err != nil {
		t.Fatal(err)
	}
	if lines := strings.Split(strings.TrimSpace(out.String()), "\n"); len(lines) != 4 || !strings.Contains(lines[0], `"id":"pa_work"`) {
		t.Fatalf("jsonl = %q", out.String())
	}
}

func TestProviderAccountResolvesIDsAndUniqueLabels(t *testing.T) {
	t.Parallel()
	accounts := providerAccounts()
	for reference, want := range map[string]string{"pa_home": "pa_home", "work": "pa_work", " Work ": "pa_work"} {
		account, err := matchProviderAccount(accounts, reference)
		if err != nil || account.GetId() != want {
			t.Fatalf("%q = %v, %v; want %s", reference, account.GetId(), err, want)
		}
	}
	if _, err := matchProviderAccount(accounts, "TWIN"); err == nil || !strings.Contains(err.Error(), "ambiguous (pa_twin1, pa_twin2)") {
		t.Fatalf("ambiguous label: %v", err)
	}
	if _, err := matchProviderAccount(accounts, "Spare"); err == nil || !strings.Contains(err.Error(), `"Spare" was not found`) {
		t.Fatalf("unknown label: %v", err)
	}
	if _, err := matchProviderAccount(accounts, ""); err == nil {
		t.Fatal("empty reference resolved")
	}
}

func TestProviderAccountEditsResolveLabels(t *testing.T) {
	t.Parallel()
	fake := &fakeProviderClient{}
	c, out, _ := providerCLI(t, fake)
	if err := c.Run([]string{"provider", "add", "chatgpt", "--label", "Spare", "--method", "siwc"}); err != nil {
		t.Fatal(err)
	}
	if fake.created.GetProvider() != dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT || fake.created.GetLabel() != "Spare" || fake.created.GetMethod() != dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_SIWC {
		t.Fatalf("create request = %v", fake.created)
	}
	if !strings.Contains(out.String(), "provider login pa_new") {
		t.Fatalf("add output = %q", out.String())
	}
	if err := c.Run([]string{"provider", "add", "claude", "--label", "X", "--method", "host"}); err == nil {
		t.Fatal("adoption-only method accepted")
	}
	if err := c.Run([]string{"provider", "rename", "work", "Office"}); err != nil {
		t.Fatal(err)
	}
	if fake.updated.GetAccountId() != "pa_work" || fake.updated.GetLabel() != "Office" || fake.updated.IncludeInSummary != nil {
		t.Fatalf("rename request = %v", fake.updated)
	}
	if err := c.Run([]string{"provider", "exclude", "Home"}); err != nil {
		t.Fatal(err)
	}
	if fake.updated.GetAccountId() != "pa_home" || fake.updated.IncludeInSummary == nil || fake.updated.GetIncludeInSummary() || fake.updated.Label != nil {
		t.Fatalf("exclude request = %v", fake.updated)
	}
	if err := c.Run([]string{"provider", "default", "Home"}); err != nil {
		t.Fatal(err)
	}
	if err := c.Run([]string{"provider", "remove", "Home"}); err == nil || !strings.Contains(err.Error(), "--confirm REMOVE") {
		t.Fatalf("remove without confirmation: %v", err)
	}
	if err := c.Run([]string{"provider", "remove", "Home", "--confirm", "REMOVE"}); err != nil {
		t.Fatal(err)
	}
	if err := c.Run([]string{"provider", "logout", "Work"}); err != nil {
		t.Fatal(err)
	}
	calls := strings.Join(fake.callList(), ",")
	for _, want := range []string{"default pa_home", "delete pa_home", "signout pa_work"} {
		if !strings.Contains(calls, want) {
			t.Errorf("calls %s lack %q", calls, want)
		}
	}
	if strings.Count(calls, "delete") != 1 {
		t.Fatalf("an unconfirmed remove reached the daemon: %s", calls)
	}
}

func TestProviderMutationsRefuseAgentTurns(t *testing.T) {
	t.Parallel()
	for _, args := range [][]string{
		{"add", "claude", "--label", "X"}, {"rename", "Work", "Y"}, {"include", "Work"}, {"exclude", "Work"},
		{"default", "Work"}, {"omp-access", "Work", "on"}, {"remove", "Work", "--confirm", "REMOVE"}, {"login", "Work", "--code", "C"},
		{"logout", "Work"}, {"reset", "Home", "--confirm", "RESET"},
	} {
		fake := &fakeProviderClient{}
		c, _, _ := providerCLI(t, fake)
		c.env.TurnToken = "turn"
		c.Machine = "other"
		err := c.Run(append([]string{"provider"}, args...))
		if err == nil || !strings.Contains(err.Error(), "agents cannot manage provider accounts") {
			t.Fatalf("provider %s inside a turn: %v", args[0], err)
		}
		if calls := fake.callList(); len(calls) != 0 {
			t.Fatalf("provider %s reached the daemon inside a turn: %v", args[0], calls)
		}
	}
	fake := &fakeProviderClient{}
	c, out, _ := providerCLI(t, fake)
	c.env.TurnToken = "turn"
	for _, args := range [][]string{{"provider", "list"}, {"provider", "usage", "Work"}, {"provider", "login", "--help"}} {
		if err := c.Run(args); err != nil {
			t.Fatalf("%v inside a turn: %v", args, err)
		}
	}
	if !strings.Contains(out.String(), "Usage: dieter provider login") {
		t.Fatalf("login help inside a turn = %q", out.String())
	}
}

func TestProviderTokenNeedsTheTurnAndItsOwnMachine(t *testing.T) {
	t.Parallel()
	fake := &fakeProviderClient{}
	c, out, _ := providerCLI(t, fake)
	if err := c.Run([]string{"provider", "token", "--turn"}); err == nil || !strings.Contains(err.Error(), "DIETER_TURN_TOKEN") {
		t.Fatalf("token outside a turn: %v", err)
	}
	c.env.TurnToken = "turn"
	if err := c.Run([]string{"provider", "token"}); err == nil || !strings.Contains(err.Error(), "Usage: dieter provider token --turn") {
		t.Fatalf("token without --turn: %v", err)
	}
	c.Machine = "other"
	if err := c.Run([]string{"provider", "token", "--turn"}); err == nil || !strings.Contains(err.Error(), "omit --machine") {
		t.Fatalf("token with --machine: %v", err)
	}
	c.Machine = ""
	if err := c.Run([]string{"provider", "token", "--turn"}); err != nil {
		t.Fatal(err)
	}
	if out.String() != "siwc-access-token\n" {
		t.Fatalf("token output = %q", out.String())
	}
	if calls := fake.callList(); len(calls) != 1 || calls[0] != "token" || fake.token.GetProvider() != dieterv1.ProviderKind_PROVIDER_KIND_UNSPECIFIED {
		t.Fatalf("calls = %v, request %v", calls, fake.token)
	}

	// Oh My Pi asks per provider; the token is the whole output.
	for provider, want := range map[string]struct {
		kind  dieterv1.ProviderKind
		token string
	}{
		"claude":  {dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, "sk-ant-oat01-turn"},
		"chatgpt": {dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT, "chatgpt-access-token"},
	} {
		out.Reset()
		if err := c.Run([]string{"provider", "token", "--turn", "--provider", provider}); err != nil {
			t.Fatal(err)
		}
		if out.String() != want.token+"\n" || fake.token.GetProvider() != want.kind {
			t.Fatalf("--provider %s printed %q for request %v", provider, out.String(), fake.token)
		}
	}
	before := len(fake.callList())
	if err := c.Run([]string{"provider", "token", "--turn", "--provider", "openai-codex"}); err == nil || !strings.Contains(err.Error(), "claude or chatgpt") {
		t.Fatalf("an OMP provider name: %v", err)
	}
	c.Machine = "other"
	if err := c.Run([]string{"provider", "token", "--turn", "--provider", "claude"}); err == nil || !strings.Contains(err.Error(), "omit --machine") {
		t.Fatalf("--provider with --machine: %v", err)
	}
	c.Machine, c.env.TurnToken = "", ""
	if err := c.Run([]string{"provider", "token", "--turn", "--provider", "claude"}); err == nil || !strings.Contains(err.Error(), "DIETER_TURN_TOKEN") {
		t.Fatalf("--provider outside a turn: %v", err)
	}
	if calls := fake.callList(); len(calls) != before {
		t.Fatalf("refused token calls reached the daemon: %v", calls[before:])
	}
}

func TestProviderOMPAccessTogglesClaudeAccountsOnly(t *testing.T) {
	t.Parallel()
	fake := &fakeProviderClient{}
	c, out, _ := providerCLI(t, fake)
	if err := c.Run([]string{"provider", "omp-access", "work", "on"}); err != nil {
		t.Fatal(err)
	}
	if fake.updated.GetAccountId() != "pa_work" || fake.updated.OmpAccess == nil || !fake.updated.GetOmpAccess() || fake.updated.Label != nil || fake.updated.IncludeInSummary != nil {
		t.Fatalf("on request = %v", fake.updated)
	}
	if text := out.String(); !strings.Contains(text, `Oh My Pi turns may now use "Work"`) || !strings.Contains(text, "Anthropic does not permit") {
		t.Fatalf("on output = %q", text)
	}
	out.Reset()
	if err := c.Run([]string{"provider", "omp-access", "Work", "OFF", "--format", "json"}); err != nil {
		t.Fatal(err)
	}
	if fake.updated.OmpAccess == nil || fake.updated.GetOmpAccess() || !strings.Contains(out.String(), `"pa_work"`) || strings.Contains(out.String(), "ompAccess") {
		t.Fatalf("off request = %v, output %q", fake.updated, out.String())
	}
	updates := strings.Count(strings.Join(fake.callList(), ","), "update")
	if err := c.Run([]string{"provider", "omp-access", "Home", "on"}); err == nil || !strings.Contains(err.Error(), "only Claude accounts") {
		t.Fatalf("a ChatGPT account: %v", err)
	}
	if err := c.Run([]string{"provider", "omp-access", "Work", "maybe"}); err == nil || !strings.Contains(err.Error(), "use on or off") {
		t.Fatalf("an unknown state: %v", err)
	}
	if err := c.Run([]string{"provider", "omp-access", "Work"}); err == nil || !strings.Contains(err.Error(), "Usage: dieter provider omp-access") {
		t.Fatalf("a missing state: %v", err)
	}
	if got := strings.Count(strings.Join(fake.callList(), ","), "update"); got != updates {
		t.Fatalf("refused toggles reached the daemon: %v", fake.callList())
	}
	out.Reset()
	if err := c.Run([]string{"provider", "omp-access", "--help"}); err != nil || !strings.Contains(out.String(), "Anthropic may block or suspend the account") || !strings.Contains(out.String(), "never sees a refresh") {
		t.Fatalf("help = %q, %v", out.String(), err)
	}
}

func TestProviderResetNeedsConfirmationAndPrintsItsKey(t *testing.T) {
	t.Parallel()
	fake := &fakeProviderClient{outcome: "reset"}
	c, out, _ := providerCLI(t, fake)
	if err := c.Run([]string{"provider", "reset", "Home"}); err == nil || !strings.Contains(err.Error(), "--confirm RESET") {
		t.Fatalf("reset without confirmation: %v", err)
	}
	if calls := fake.callList(); len(calls) != 0 {
		t.Fatalf("unconfirmed reset reached the daemon: %v", calls)
	}
	if err := c.Run([]string{"provider", "reset", "Home", "--confirm", "RESET"}); err != nil {
		t.Fatal(err)
	}
	key := fake.reset.GetIdempotencyKey()
	if fake.reset.GetAccountId() != "pa_home" || !uuidPattern.MatchString(key) || key[14] != '4' || !strings.ContainsRune("89ab", rune(key[19])) {
		t.Fatalf("reset request = %v", fake.reset)
	}
	if !strings.Contains(out.String(), "Idempotency key: "+key+"\n") || !strings.Contains(out.String(), `rate limits of "Home" start over`) {
		t.Fatalf("reset output = %q", out.String())
	}
	if err := c.Run([]string{"provider", "reset", "Home", "--confirm", "RESET"}); err != nil {
		t.Fatal(err)
	}
	if fake.reset.GetIdempotencyKey() == key {
		t.Fatal("a second reset reused the first key")
	}
	fake.outcome = "alreadyRedeemed"
	if err := c.Run([]string{"provider", "reset", "Home", "--confirm", "RESET", "--key", strings.ToUpper(key)}); err != nil {
		t.Fatal(err)
	}
	if fake.reset.GetIdempotencyKey() != key || !strings.Contains(out.String(), "already redeemed") {
		t.Fatalf("retry key = %q, output %q", fake.reset.GetIdempotencyKey(), out.String())
	}
	if err := c.Run([]string{"provider", "reset", "Home", "--confirm", "RESET", "--key", "not-a-uuid"}); err == nil {
		t.Fatal("invalid --key accepted")
	}
	fake.outcome = "noCredit"
	if err := c.Run([]string{"provider", "reset", "Home", "--confirm", "RESET"}); err == nil || !strings.Contains(err.Error(), "no reset credit") {
		t.Fatalf("no credit: %v", err)
	}
}

func TestProviderUsageShowsWindowsTokensAndRefreshesSignedInAccounts(t *testing.T) {
	t.Parallel()
	fake := &fakeProviderClient{}
	c, out, _ := providerCLI(t, fake)
	if err := c.Run([]string{"provider", "usage"}); err != nil {
		t.Fatal(err)
	}
	rows := map[string]bool{}
	for _, line := range strings.Split(out.String(), "\n") {
		rows[strings.Join(strings.Fields(line), " ")] = true
	}
	for _, want := range []string{
		"ACCOUNT PROVIDER PLAN WINDOW LEFT RESETS UPDATED",
		"Work claude max 5-hour 88% 2026-11-14T15:00:00Z 2026-11-14T11:00:00Z (turn)",
		"Work claude max Weekly 62% 2026-11-20T09:00:00Z 2026-11-14T11:00:00Z (turn)",
		"Home chatgpt - - signed out - -",
		"ACCOUNT DIETER 5H DIETER 7D EXTRAS",
		"Work 120 (in 100, out 20) - -",
	} {
		if !rows[want] {
			t.Errorf("usage lacks %q:\n%s", want, out.String())
		}
	}
	out.Reset()
	if err := c.Run([]string{"provider", "usage", "--refresh", "--format", "json"}); err != nil {
		t.Fatal(err)
	}
	if strings.Join(fake.refreshed, ",") != "pa_work" || !strings.Contains(out.String(), `"probe"`) {
		t.Fatalf("refreshed %v, output %s", fake.refreshed, out.String())
	}
	fake.refreshed = nil
	if err := c.Run([]string{"provider", "usage", "Home", "--refresh"}); err != nil {
		t.Fatal(err)
	}
	if strings.Join(fake.refreshed, ",") != "pa_home" {
		t.Fatalf("named refresh = %v", fake.refreshed)
	}
}

func TestProviderCheckReportsTheTargetMachine(t *testing.T) {
	t.Parallel()
	fake := &fakeProviderClient{}
	c, out, _ := providerCLI(t, fake)
	fake.checked = fake.accounts[0]
	if err := c.Run([]string{"provider", "check", "Work"}); err != nil {
		t.Fatal(err)
	}
	if out.String() != "\"Work\" is signed in on this machine as me@example.com (verified 2026-11-14T10:00:00Z).\n" {
		t.Fatalf("check output = %q", out.String())
	}
	c.transport.daemonID = "d_three"
	c.Machine = "studio"
	if err := c.Run([]string{"provider", "check", "Work"}); err == nil || err.Error() != `"Work" is expired on studio: token expired` {
		t.Fatalf("expired check: %v", err)
	}
	c.transport.daemonID = "d_new"
	if err := c.Run([]string{"provider", "check", "Work"}); err == nil || !strings.Contains(err.Error(), "not signed in on studio") {
		t.Fatalf("missing login check: %v", err)
	}
}

// loginFixture scripts a sign-in: Start returns a starting session, the watch
// then asks for input, and accepted input succeeds.
func loginFixture(expects dieterv1.ProviderLoginInput) *fakeProviderClient {
	fake := &fakeProviderClient{
		start:  &dieterv1.ProviderLogin{LoginId: "pl_one", AccountId: "pa_work", Phase: dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_STARTING},
		events: make(chan *dieterv1.ProviderLogin, 8),
	}
	fake.events <- &dieterv1.ProviderLogin{LoginId: "pl_one", Phase: waiting, Challenge: &dieterv1.ProviderLoginChallenge{
		OpenUrl: "https://claude.example/oauth?state=s", LocalUrl: "https://claude.example/oauth?redirect=localhost", CallbackPort: 54545, Expects: expects,
	}}
	fake.onSubmit = func(*dieterv1.SubmitProviderLoginInputRequest) (*dieterv1.ProviderLogin, error) {
		fake.events <- &dieterv1.ProviderLogin{LoginId: "pl_one", Phase: succeeded, Identity: &dieterv1.ProviderIdentity{Email: "me@example.com"}}
		return &dieterv1.ProviderLogin{LoginId: "pl_one", Phase: dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_COMPLETING}, nil
	}
	return fake
}

func TestProviderLoginReadsAPastedCodeWithoutEcho(t *testing.T) {
	t.Parallel()
	fake := loginFixture(dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE)
	c, out, _ := providerCLI(t, fake)
	var labels []string
	c.promptHidden = func(_ context.Context, label string) (string, error) {
		labels = append(labels, label)
		return "FIXTURE-CODE#state\n", nil
	}
	if err := c.Run([]string{"provider", "login", "Work"}); err != nil {
		t.Fatal(err)
	}
	if fake.started.GetAccountId() != "pa_work" || fake.started.GetFlow() != dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_UNSPECIFIED {
		t.Fatalf("start request = %v", fake.started)
	}
	if len(labels) != 1 || len(fake.submitted) != 1 || fake.submitted[0].GetCode() != "FIXTURE-CODE#state" || fake.submitted[0].GetLoginId() != "pl_one" {
		t.Fatalf("prompts %v, submitted %v", labels, fake.submitted)
	}
	text := out.String()
	for _, want := range []string{"in to Claude Code on this machine", "https://claude.example/oauth?state=s", "finishes without a code", "paste the code", `Signed in: "Work" on this machine as me@example.com.`} {
		if !strings.Contains(text, want) {
			t.Errorf("login output lacks %q:\n%s", want, text)
		}
	}
	if len(fake.canceled) != 0 {
		t.Fatalf("a successful sign-in was canceled: %v", fake.canceled)
	}
}

func TestProviderLoginSendsAPastedLoopbackAddressAsCallback(t *testing.T) {
	t.Parallel()
	fake := loginFixture(dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE)
	c, _, errOut := providerCLI(t, fake)
	answers := []string{"https://example.com/not-loopback?code=x", "http://localhost:54545/callback?code=abc&state=s"}
	c.promptHidden = func(context.Context, string) (string, error) {
		answer := answers[0]
		answers = answers[1:]
		return answer, nil
	}
	if err := c.Run([]string{"provider", "login", "Work"}); err != nil {
		t.Fatal(err)
	}
	if len(fake.submitted) != 1 || fake.submitted[0].GetCallbackUrl() != "http://localhost:54545/callback?code=abc&state=s" {
		t.Fatalf("submitted = %v", fake.submitted)
	}
	if !strings.Contains(errOut.String(), "http://127.0.0.1") {
		t.Fatalf("a non-loopback address was not explained: %q", errOut.String())
	}
}

func TestProviderLoginAsksAgainAfterARejectedCode(t *testing.T) {
	t.Parallel()
	fake := loginFixture(dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE)
	accept := fake.onSubmit
	fake.onSubmit = func(in *dieterv1.SubmitProviderLoginInputRequest) (*dieterv1.ProviderLogin, error) {
		if in.GetCode() != "good" {
			return nil, status.Error(codes.InvalidArgument, "the code is malformed")
		}
		return accept(in)
	}
	c, _, errOut := providerCLI(t, fake)
	answers := []string{"bad", "good"}
	c.promptHidden = func(context.Context, string) (string, error) {
		answer := answers[0]
		answers = answers[1:]
		return answer, nil
	}
	if err := c.Run([]string{"provider", "login", "Work"}); err != nil {
		t.Fatal(err)
	}
	if len(fake.submitted) != 2 || !strings.Contains(errOut.String(), "the code is malformed") {
		t.Fatalf("submitted %v, stderr %q", fake.submitted, errOut.String())
	}
}

func TestProviderLoginFlagsHandOverInputWithoutPrompting(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		args     []string
		expects  dieterv1.ProviderLoginInput
		code     string
		callback string
		flow     dieterv1.ProviderLoginFlow
	}{
		{[]string{"--code", "FIXTURE-CODE"}, dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE, "FIXTURE-CODE", "", dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_UNSPECIFIED},
		{[]string{"--browser", "--callback", "http://127.0.0.1:1455/auth/callback?code=c&state=s"}, dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CALLBACK, "", "http://127.0.0.1:1455/auth/callback?code=c&state=s", dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_BROWSER},
	} {
		fake := loginFixture(test.expects)
		c, _, _ := providerCLI(t, fake)
		c.promptHidden = func(context.Context, string) (string, error) {
			t.Error("prompted although the input was given")
			return "", io.EOF
		}
		if err := c.Run(append([]string{"provider", "login", "pa_work"}, test.args...)); err != nil {
			t.Fatal(err)
		}
		if fake.started.GetFlow() != test.flow || len(fake.submitted) != 1 || fake.submitted[0].GetCode() != test.code || fake.submitted[0].GetCallbackUrl() != test.callback {
			t.Fatalf("%v: start %v, submitted %v", test.args, fake.started, fake.submitted)
		}
	}
	fake := loginFixture(dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE)
	c, _, _ := providerCLI(t, fake)
	for _, args := range [][]string{
		{"--callback", "https://example.com/callback?code=x"}, {"--code", "a", "--callback", "http://localhost:1/c?x=1"}, {"--browser", "--device-code"},
	} {
		if err := c.Run(append([]string{"provider", "login", "Work"}, args...)); err == nil {
			t.Fatalf("login %v was accepted", args)
		}
	}
	if calls := fake.callList(); len(calls) != 0 {
		t.Fatalf("invalid logins reached the daemon: %v", calls)
	}
}

func TestProviderLoginShowsADeviceCodeAndWaits(t *testing.T) {
	t.Parallel()
	fake := &fakeProviderClient{
		start: &dieterv1.ProviderLogin{LoginId: "pl_dev", Phase: waiting, Challenge: &dieterv1.ProviderLoginChallenge{
			OpenUrl: "https://auth.example/codex/device", UserCode: "ABCD-1234", ExpiresAt: "2026-11-14T12:15:00Z", Expects: dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_NONE,
		}},
		events: make(chan *dieterv1.ProviderLogin, 4),
	}
	// The current state comes first, then a refreshed code, then success.
	fake.events <- fake.start
	fake.events <- &dieterv1.ProviderLogin{LoginId: "pl_dev", Phase: waiting, Challenge: &dieterv1.ProviderLoginChallenge{
		OpenUrl: "https://auth.example/codex/device", UserCode: "WXYZ-9876", Expects: dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_NONE,
	}}
	fake.events <- &dieterv1.ProviderLogin{LoginId: "pl_dev", Phase: succeeded}
	c, out, _ := providerCLI(t, fake)
	c.promptHidden = func(context.Context, string) (string, error) {
		t.Error("prompted for a device-code sign-in")
		return "", io.EOF
	}
	if err := c.Run([]string{"provider", "login", "Home", "--device-code"}); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	if fake.started.GetFlow() != dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_DEVICE_CODE || strings.Count(text, "ABCD-1234") != 1 || !strings.Contains(text, "WXYZ-9876") ||
		!strings.Contains(text, "in to Codex on this machine") || !strings.Contains(text, `Signed in: "Home" on this machine.`) {
		t.Fatalf("device-code output:\n%s", text)
	}
	if len(fake.submitted) != 0 {
		t.Fatalf("submitted %v", fake.submitted)
	}
}

func TestProviderLoginFailureExitsNonZero(t *testing.T) {
	t.Parallel()
	fake := loginFixture(dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE)
	fake.onSubmit = func(*dieterv1.SubmitProviderLoginInputRequest) (*dieterv1.ProviderLogin, error) {
		return &dieterv1.ProviderLogin{LoginId: "pl_one", Phase: dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_FAILED,
			ErrorCode: "identity_mismatch", ErrorMessage: "signed in as other@example.com, not me@example.com"}, nil
	}
	c, _, _ := providerCLI(t, fake)
	err := c.Run([]string{"provider", "login", "Work", "--code", "FIXTURE-CODE"})
	if err == nil || err.Error() != "sign-in failed: signed in as other@example.com, not me@example.com (identity_mismatch)" {
		t.Fatalf("failure: %v", err)
	}
}

func TestProviderLoginCancelStopsTheDaemonSession(t *testing.T) {
	t.Parallel()
	fake := loginFixture(dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE)
	c, _, _ := providerCLI(t, fake)
	prompted := make(chan struct{})
	promptEnded := make(chan struct{})
	c.promptHidden = func(ctx context.Context, _ string) (string, error) {
		close(prompted)
		<-ctx.Done()
		close(promptEnded)
		return "", ctx.Err()
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		<-prompted
		cancel() // Ctrl-C
	}()
	session := &providerLoginSession{c: c}
	err := session.run(ctx, "Work", dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_UNSPECIFIED)
	if err == nil || err.Error() != "sign-in canceled" {
		t.Fatalf("canceled sign-in: %v", err)
	}
	select {
	case <-promptEnded:
	case <-time.After(time.Second):
		t.Fatal("the prompt outlived the sign-in")
	}
	if len(fake.canceled) != 1 || fake.canceled[0] != "pl_one" || len(fake.submitted) != 0 {
		t.Fatalf("canceled %v, submitted %v", fake.canceled, fake.submitted)
	}
}

func TestProviderLoginWithoutTerminalWaitsForTheBrowser(t *testing.T) {
	t.Parallel()
	fake := loginFixture(dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CALLBACK)
	// A browser on the daemon's host completes the redirect by itself.
	fake.events <- &dieterv1.ProviderLogin{LoginId: "pl_one", Phase: succeeded}
	c, _, errOut := providerCLI(t, fake)
	if err := c.Run([]string{"provider", "login", "Work", "--browser"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(errOut.String(), "No terminal") || len(fake.submitted) != 0 {
		t.Fatalf("stderr %q, submitted %v", errOut.String(), fake.submitted)
	}
}

func TestProviderLoginWatchEndingWithoutResultIsAnError(t *testing.T) {
	t.Parallel()
	fake := loginFixture(dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_NONE)
	close(fake.events)
	c, _, _ := providerCLI(t, fake)
	if err := c.Run([]string{"provider", "login", "Work"}); err == nil || !strings.Contains(err.Error(), "ended without a result") {
		t.Fatalf("watch EOF: %v", err)
	}
	if len(fake.canceled) != 1 {
		t.Fatalf("canceled = %v", fake.canceled)
	}
}

func TestAccountFlagsResolveOnTheTargetDaemon(t *testing.T) {
	t.Parallel()
	fake := &fakeProviderClient{
		state: &dieterv1.State{
			Project:  &dieterv1.Project{Id: "p_one"},
			Projects: []*dieterv1.Project{{Id: "p_one", Name: "Atlas", Checkouts: []*dieterv1.Checkout{{Id: "co_one", Path: "/work/atlas"}}}},
			Boards:   []*dieterv1.Board{{Id: "b_one", ProjectId: "p_one", Name: "Delivery"}},
		},
		card: &dieterv1.CardDetail{Card: &dieterv1.Card{Id: "c_one", Provider: "claude-code", Model: "opus", ProviderAccountId: "pa_old"}},
	}
	c, _, _ := providerCLI(t, fake)
	if err := c.Run([]string{"card", "send", "c_one", "--message", "hi", "--account", "work"}); err != nil {
		t.Fatal(err)
	}
	if fake.sent.GetAccountId() != "pa_work" {
		t.Fatalf("send account = %q", fake.sent.GetAccountId())
	}
	if err := c.Run([]string{"chat", "send", "c_one", "--message", "hi"}); err != nil {
		t.Fatal(err)
	}
	if fake.sent.GetAccountId() != "" {
		t.Fatalf("send without --account = %q", fake.sent.GetAccountId())
	}
	if err := c.Run([]string{"chat", "create", "--project", "Atlas", "--title", "T", "--workspace", "project", "--account", "Home"}); err != nil {
		t.Fatal(err)
	}
	if fake.createdChat.GetAccountId() != "pa_home" {
		t.Fatalf("create account = %q", fake.createdChat.GetAccountId())
	}
	if err := c.Run([]string{"card", "update", "c_one", "--model", "sonnet"}); err != nil {
		t.Fatal(err)
	}
	if fake.updatedCard.GetAgentSettings().GetAccountId() != "pa_old" {
		t.Fatalf("update kept account = %q", fake.updatedCard.GetAgentSettings().GetAccountId())
	}
	if err := c.Run([]string{"card", "update", "c_one", "--account", "pa_work"}); err != nil {
		t.Fatal(err)
	}
	if settings := fake.updatedCard.GetAgentSettings(); settings.GetAccountId() != "pa_work" || settings.GetModel() != "opus" {
		t.Fatalf("update settings = %v", settings)
	}
	if err := c.Run([]string{"card", "update", "c_one", "--account", ""}); err != nil {
		t.Fatal(err)
	}
	if settings := fake.updatedCard.GetAgentSettings(); settings == nil || settings.GetAccountId() != "" {
		t.Fatalf("update to the default = %v", settings)
	}
	if err := c.Run([]string{"schedule", "create", "--project", "Atlas", "--board", "Delivery", "--name", "Daily", "--title", "T", "--prompt", "P", "--account", "Work"}); err != nil {
		t.Fatal(err)
	}
	if fake.schedule.GetSchedule().GetAccountId() != "pa_work" {
		t.Fatalf("schedule account = %q", fake.schedule.GetSchedule().GetAccountId())
	}
	fake.sent = nil
	if err := c.Run([]string{"card", "send", "c_one", "--message", "hi", "--account", "Spare"}); err == nil || !strings.Contains(err.Error(), "was not found") {
		t.Fatalf("unknown account: %v", err)
	}
	if fake.sent != nil {
		t.Fatal("a message with an unknown account was sent")
	}
}

func TestLoginInputClassifiesPastedLines(t *testing.T) {
	t.Parallel()
	for value, callback := range map[string]bool{
		"FIXTURE-CODE#state": false, "  abc  ": false,
		"http://localhost:54545/callback?code=a": true, "HTTP://127.0.0.1:1455/auth/callback?code=a": true, "http://[::1]:1455/auth/callback?code=a": true,
	} {
		request, err := providerLoginInput(value)
		if err != nil {
			t.Fatalf("%q: %v", value, err)
		}
		if (request.GetCallbackUrl() != "") != callback {
			t.Fatalf("%q classified as %v", value, request)
		}
	}
	for _, value := range []string{"", "https://claude.example/callback?code=a", "http://localhost:1455/auth/callback"} {
		if _, err := providerLoginInput(value); err == nil {
			t.Fatalf("%q accepted", value)
		}
	}
}
