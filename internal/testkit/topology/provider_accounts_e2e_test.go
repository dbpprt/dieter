//go:build e2e

package topology_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/engine"
	"github.com/dbpprt/dieter/internal/engine/accounts"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/kv"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

type accountMachine struct {
	name     string
	daemon   *topology.Daemon
	app      *engine.Service
	runner   *testkit.FakeRunner
	accounts *accounts.Service
}

// startAccountMachine runs an account daemon wired like `dieter serve`: its
// API and its turns share one accounts engine, here over the in-process
// fixture backend, whose background work (cleanup of removed accounts) runs.
func startAccountMachine(t *testing.T, g *topology.Gateway, name string, direct bool) accountMachine {
	t.Helper()
	identity := topology.Machine(t, g, name, topology.Account)
	data := store.New(identity.Root)
	fixture := accounts.NewFixtureBackend()
	fixture.DeviceApproval = 50 * time.Millisecond
	var trust atomic.Pointer[link.Trust]
	service, err := accounts.New(accounts.Options{
		Store: data, Backend: fixture, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		// Host logins are looked up in a fresh home, never the operator's.
		HostHome: t.TempDir(), MachineName: func() string { return name },
		Roster: func() map[string]bool {
			if current := trust.Load(); current != nil {
				return current.ActiveDaemons()
			}
			return nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Shutdown)
	runner := &testkit.FakeRunner{}
	noReserve := uint64(0)
	app := engine.NewWithOptions(data, engine.Options{Runner: runner, Catalog: testkit.MockCatalog(), MinimumFreeBytes: &noReserve, Accounts: service})
	daemon := topology.StartDaemon(t, g, topology.DaemonOptions{
		Name: name, Identity: identity, Store: data, Direct: direct,
		API: api.Options{App: app, Runner: runner, Catalog: testkit.MockCatalog(), MinimumFreeBytes: &noReserve, Accounts: service},
	})
	trust.Store(daemon.Trust)
	scope := crdt.Revision([]string{identity.Issuer(), "github:42"})
	if _, err := data.Replica.BindPeerAccount(scope, "github:42", identity.ID, identity.Issuer()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go service.Run(ctx)
	return accountMachine{name: name, daemon: daemon, app: app, runner: runner, accounts: service}
}

// localClient reaches a daemon over its loopback route with the local token.
func localClient(t *testing.T, daemon *topology.Daemon) dieterclient.Client {
	t.Helper()
	connection, err := grpc.NewClient(daemon.Address, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithPerRPCCredentials(localauth.Credentials{Token: daemon.Token}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return dieterclient.New(connection)
}

// signInOver runs a whole sign-in through client: start, hand over the
// code when the challenge asks for one, and watch until it ends.
func signInOver(t *testing.T, ctx context.Context, client dieterclient.Client, accountID, code string) *dieterv1.ProviderLogin {
	t.Helper()
	login, err := client.StartProviderLogin(ctx, &dieterv1.StartProviderLoginRequest{AccountId: accountID})
	if err != nil {
		t.Fatal(err)
	}
	if login.GetPhase() != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_WAITING {
		t.Fatalf("sign-in = %v", login)
	}
	if code != "" {
		if _, err := client.SubmitProviderLoginInput(ctx, &dieterv1.SubmitProviderLoginInputRequest{LoginId: login.GetLoginId(), Input: &dieterv1.SubmitProviderLoginInputRequest_Code{Code: code}}); err != nil {
			t.Fatal(err)
		}
	}
	stream, err := client.WatchProviderLogin(ctx, &dieterv1.WatchProviderLoginRequest{LoginId: login.GetLoginId(), HeartbeatSeconds: 1})
	if err != nil {
		t.Fatal(err)
	}
	last := login
	for {
		next, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("watch sign-in: %v (last %v)", err, last)
		}
		last = next
	}
	if last.GetPhase() != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_SUCCEEDED {
		t.Fatalf("sign-in ended %v", last)
	}
	return last
}

func providerAccount(t *testing.T, ctx context.Context, client dieterclient.Client, id string) *dieterv1.ProviderAccount {
	t.Helper()
	listed, err := client.ListProviderAccounts(ctx, &dieterv1.ListProviderAccountsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	for _, account := range listed.GetAccounts() {
		if account.GetId() == id {
			return account
		}
	}
	return nil
}

func loginState(account *dieterv1.ProviderAccount, daemonID string) dieterv1.ProviderLoginState {
	for _, login := range account.GetLogins() {
		if login.GetDaemonId() == daemonID {
			return login.GetState()
		}
	}
	return dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_UNSPECIFIED
}

// An account added on A replicates; B signs in to it over direct TLS and the
// relay; peer sync shows B's logins on A; a turn on B runs on B's own login;
// removing the account on A makes B sign out and delete its files. The
// gateway relays the sign-in but never sees the pasted code.
func TestProviderAccountsSpanMachinesAndTurnsUseTheMachinesLogin(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(3*time.Minute))
	defer cancel()
	traffic := &recorder{}
	g := topology.StartGateway(t, topology.GatewayOptions{Listen: traffic.wrap})
	a, b := startAccountMachine(t, g, "Provider desk A", false), startAccountMachine(t, g, "Provider desk B", true)
	sync := func() {
		t.Helper()
		syncer := &peersync.PeerSync{Identity: a.daemon.Identity, Trust: a.daemon.Trust, Store: a.daemon.Store}
		if err := syncer.Round(ctx); err != nil {
			t.Fatal(err)
		}
	}
	local := localClient(t, a.daemon)
	phone := topology.StartClient(t, g, a.daemon, "Provider phone")
	routes := map[string]dieterclient.Client{
		"direct": dieterclient.New(topology.DialDaemon(t, phone, b.daemon, topology.Direct)),
		"relay":  dieterclient.New(topology.DialDaemon(t, phone, b.daemon, topology.Tunnel)),
	}

	// Accounts are added on A over the local route and replicate.
	work, err := local.CreateProviderAccount(ctx, &dieterv1.CreateProviderAccountRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "Work"})
	if err != nil {
		t.Fatal(err)
	}
	personal, err := local.CreateProviderAccount(ctx, &dieterv1.CreateProviderAccountRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT, Label: "Personal"})
	if err != nil {
		t.Fatal(err)
	}
	sync()
	for route, client := range routes {
		if account := providerAccount(t, ctx, client, work.GetId()); account == nil || account.GetLabel() != "Work" || !account.GetIsDefault() || account.GetCreatedBy() != a.daemon.Identity.ID {
			t.Fatalf("B over %s lists Work as %v", route, account)
		}
	}

	// B signs in to Work over the relay (a pasted code) and to Personal over
	// direct TLS (a device code that approves itself).
	if login := signInOver(t, ctx, routes["relay"], work.GetId(), accounts.FixtureCode); login.GetDaemonId() != b.daemon.Identity.ID {
		t.Fatalf("the relay sign-in ran on %s", login.GetDaemonId())
	}
	if login := signInOver(t, ctx, routes["direct"], personal.GetId(), ""); login.GetDaemonId() != b.daemon.Identity.ID {
		t.Fatalf("the direct sign-in ran on %s", login.GetDaemonId())
	}
	if account := providerAccount(t, ctx, routes["direct"], work.GetId()); loginState(account, b.daemon.Identity.ID) != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN || account.GetIdentity().GetEmail() == "" {
		t.Fatalf("B's Work after signing in = %v", account)
	}

	// Peer sync shows B's logins on A; A itself is signed in to neither.
	sync()
	for _, id := range []string{work.GetId(), personal.GetId()} {
		account := providerAccount(t, ctx, local, id)
		if loginState(account, b.daemon.Identity.ID) != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN || loginState(account, a.daemon.Identity.ID) != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_UNSPECIFIED {
			t.Fatalf("A lists %s as %v", id, account)
		}
	}

	// A turn on B runs on B's login of Work; on A the same account is not
	// signed in.
	cardOn := func(machine accountMachine) model.Card {
		t.Helper()
		project, err := machine.daemon.Store.Kanban.CreateProject(kanban.CreateProjectInput{Path: testkit.CheckoutDir(t), Name: "Accounts on " + machine.name})
		if err != nil {
			t.Fatal(err)
		}
		board, err := machine.daemon.Store.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Work", Workflow: "review"})
		if err != nil {
			t.Fatal(err)
		}
		card, err := machine.app.CreateCard(ctx, engine.CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Claude on " + machine.name, Prompt: "Work", Provider: "claude-code", Model: "sonnet", WorkspaceMode: model.WorkspaceModeProject})
		if err != nil {
			t.Fatal(err)
		}
		return card
	}
	onB := cardOn(b)
	if err := b.app.SendCard(ctx, onB.ID, "Go", "", "", ""); err != nil {
		t.Fatal(err)
	}
	request := b.runner.Request(0)
	wantDir := filepath.Join(b.daemon.Store.ProviderAccountDir(work.GetId()), "claude")
	if request.ProviderAccountID != work.GetId() || request.Auth == nil || len(request.Auth) != 0 || request.Environment["CLAUDE_CONFIG_DIR"] != wantDir {
		t.Fatalf("B's turn: account=%q auth=%#v CLAUDE_CONFIG_DIR=%q (want %q)", request.ProviderAccountID, request.Auth, request.Environment["CLAUDE_CONFIG_DIR"], wantDir)
	}
	if stored, err := b.daemon.Store.Kanban.ResolveCard(onB.ID); err != nil || stored.ProviderAccountID != work.GetId() {
		t.Fatalf("B's card account = %q, %v", stored.ProviderAccountID, err)
	}
	settle(t, b.daemon.Store)
	onA := cardOn(a)
	_, err = a.app.StartCard(onA.ID, "Go", "", "", "")
	if kind, _ := fault.KindOf(err); kind != fault.FailedPrecondition || !strings.Contains(err.Error(), "Provider desk A") {
		t.Fatalf("a turn on A without a login: %v", err)
	}
	if a.runner.Count() != 0 {
		t.Fatal("A ran a turn without a login")
	}

	// Removing Work on A signs B out and deletes B's files for it.
	if _, err := local.DeleteProviderAccount(ctx, &dieterv1.DeleteProviderAccountRequest{AccountId: work.GetId()}); err != nil {
		t.Fatal(err)
	}
	sync()
	if account := providerAccount(t, ctx, routes["relay"], work.GetId()); account != nil {
		t.Fatalf("B still lists the removed account: %v", account)
	}
	accountDir := b.daemon.Store.ProviderAccountDir(work.GetId())
	testkit.Eventually(t, testkit.Budget(60*time.Second), func() bool {
		_, statErr := os.Lstat(accountDir)
		return errors.Is(statErr, os.ErrNotExist) && loginTombstoned(t, b.daemon.Store, work.GetId(), b.daemon.Identity.ID)
	}, "B to sign the removed account out and delete its files")
	sync()
	if !loginTombstoned(t, a.daemon.Store, work.GetId(), b.daemon.Identity.ID) {
		t.Fatal("A did not receive B's removed login record")
	}
	// Personal is untouched.
	if account := providerAccount(t, ctx, local, personal.GetId()); loginState(account, b.daemon.Identity.ID) != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN {
		t.Fatalf("Personal after removing Work = %v", account)
	}

	if traffic.contains(accounts.FixtureCode) {
		t.Fatal("the gateway saw the pasted sign-in code")
	}
	if !traffic.contains("Provider desk B") {
		t.Fatal("the recorder captured no gateway traffic")
	}
}

// loginTombstoned reports whether daemonID's login record of accountID is a
// tombstone in data.
func loginTombstoned(t *testing.T, data *store.Store, accountID, daemonID string) bool {
	t.Helper()
	deleted := false
	if err := data.KV.EachProviderLogin(accountID+".", true, func(entry kv.ProviderLoginEntry) error {
		if entry.DaemonID == daemonID {
			deleted = entry.Deleted
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return deleted
}
