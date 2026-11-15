package daemon

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/engine/accounts"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/platform/config"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

func accountsDaemonStore(t *testing.T) *store.Store {
	t.Helper()
	data := testkit.PeerStore(t, "dm_services")
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	return data
}

func servicesClient(t *testing.T, services *Services) dieterclient.ConnectClient {
	t.Helper()
	server := testkit.HTTPServer(services.API.Handler())
	t.Cleanup(server.Close)
	return dieterclient.NewConnect(&http.Client{Transport: localTokenTransport{root: services.Store.Root}}, server.URL)
}

// The daemon builds one accounts engine and serves it; turns resolve accounts
// when they really run the provider tools or a fixture supplies them, and
// injected test runners keep the adapters' own credentials.
func TestServicesWireTheProviderAccountsEngine(t *testing.T) {
	t.Parallel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	catalog := harness.StaticCatalog(true)
	for name, test := range map[string]struct {
		options    ServiceOptions
		turnsWired bool
	}{
		"injected runner":    {options: ServiceOptions{Runner: &testkit.FakeRunner{}, Catalog: catalog}},
		"fixture backend":    {options: ServiceOptions{Runner: &testkit.FakeRunner{}, Catalog: catalog, AccountsBackend: accounts.NewFixtureBackend()}, turnsWired: true},
		"provider processes": {options: ServiceOptions{Runner: harness.NewSubprocessRunner(t.TempDir(), harness.Environment{}), Catalog: catalog}, turnsWired: true},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			services := NewServices(accountsDaemonStore(t), logger, test.options)
			if services.Accounts == nil {
				t.Fatal("no accounts engine")
			}
			t.Cleanup(services.Accounts.Shutdown)
			if wired := services.App.Accounts != nil; wired != test.turnsWired {
				t.Fatalf("turns resolve accounts = %v, want %v", wired, test.turnsWired)
			}
			if test.turnsWired && services.App.Accounts != services.Accounts {
				t.Fatal("turns use a different accounts engine than the API")
			}
			client := servicesClient(t, services)
			created, err := client.CreateProviderAccount(t.Context(), &dieterv1.CreateProviderAccountRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "Work"})
			if err != nil {
				t.Fatal(err)
			}
			listed, err := services.Accounts.List(t.Context(), "")
			if err != nil || len(listed) != 1 || listed[0].ID != created.GetId() {
				t.Fatalf("the API and the engine disagree: %+v, %v", listed, err)
			}
		})
	}
}

// The engine gets the daemon's machine name and only the provider subset of
// its environment: an API key there becomes this machine's environment
// account.
func TestServicesHandTheAccountsEngineTheMachineAndItsAPIKeys(t *testing.T) {
	t.Parallel()
	environment := config.Env{"HOME": t.TempDir(), "ANTHROPIC_API_KEY": "sk-ant-fixture", "PATH": "/usr/bin"}
	services := NewServices(accountsDaemonStore(t), slog.New(slog.NewTextHandler(io.Discard, nil)), ServiceOptions{
		Env: config.Daemon{Environment: environment}, Runner: &testkit.FakeRunner{}, Catalog: harness.StaticCatalog(true),
		AccountsBackend: accounts.NewFixtureBackend(), Name: "box",
	})
	t.Cleanup(services.Accounts.Shutdown)
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		services.Accounts.Run(ctx)
	}()
	// Stop the background work before the store's directory goes away.
	t.Cleanup(func() {
		cancel()
		<-stopped
	})

	var adopted accounts.Account
	testkit.Eventually(t, testkit.Budget(20*time.Second), func() bool {
		values, err := services.Accounts.List(ctx, accounts.ProviderClaude)
		if err != nil || len(values) != 1 || len(values[0].Logins) != 1 {
			return false
		}
		adopted = values[0]
		return true
	}, "the API key to become an account signed in here")
	if adopted.Method != accounts.MethodEnvironment || adopted.Label != "Anthropic API key on box" || len(adopted.Logins) != 1 || adopted.Logins[0].State != accounts.StateSignedIn {
		t.Fatalf("adopted account = %+v", adopted)
	}
	auth, err := services.Accounts.ResolveTurn(ctx, "claude-code", "")
	if err != nil || auth.AccountID != adopted.ID || auth.Auth["ANTHROPIC_API_KEY"] != "sk-ant-fixture" {
		t.Fatalf("environment turn = %+v, %v", auth, err)
	}
	if _, err := services.Accounts.ResolveTurn(ctx, "codex", ""); err == nil || !strings.Contains(err.Error(), "ChatGPT") {
		t.Fatalf("a Codex turn without a ChatGPT account: %v", err)
	}
	created, err := services.Accounts.Create(ctx, accounts.CreateInput{Provider: accounts.ProviderChatGPT, Label: "Personal"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := services.Accounts.ResolveTurn(ctx, "codex", created.ID); err == nil || !strings.Contains(err.Error(), "on box") {
		t.Fatalf("a turn on an account not signed in here names the machine: %v", err)
	}
}
