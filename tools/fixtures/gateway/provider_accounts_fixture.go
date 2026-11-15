package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/engine/accounts"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/replication/schema"
	boardstore "github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kv"
)

// Seeded provider accounts. Fixed IDs keep a restarted fixture on the same
// records, and clients and flows can name them.
const (
	fixtureWorkAccount     = "pa_fixtureworkaccount22222222"
	fixturePersonalAccount = "pa_fixturepersonalaccount2222"
)

// fixtureProviderAccounts runs the real provider accounts engine on every
// fixture daemon, each over its own in-process accounts.FixtureBackend: a
// pasted FIXTURE-CODE signs Claude in, a ChatGPT device code approves itself
// after two seconds and a callback with code=fixture succeeds. No provider
// tool runs and nothing leaves loopback.
type fixtureProviderAccounts struct {
	logger *slog.Logger
	// hostHome is the fixture's disposable HOME: host logins are looked up
	// there, never in the operator's ~/.claude or ~/.codex.
	hostHome string

	mu       sync.Mutex
	services map[*boardstore.Store]*fixtureAccountsService
}

type fixtureAccountsService struct {
	service *accounts.Service
	started bool
}

func newFixtureProviderAccounts(logger *slog.Logger, hostHome string) *fixtureProviderAccounts {
	return &fixtureProviderAccounts{logger: logger, hostHome: hostHome, services: map[*boardstore.Store]*fixtureAccountsService{}}
}

// forStore returns the accounts engine of a fixture daemon, created once per
// store so a restarted daemon API keeps its sign-ins. trust supplies the
// device roster: login records of daemons outside it are ignored, as in
// `dieter serve`.
func (f *fixtureProviderAccounts) forStore(data *boardstore.Store, trust *link.Trust) *accounts.Service {
	f.mu.Lock()
	defer f.mu.Unlock()
	if existing := f.services[data]; existing != nil {
		return existing.service
	}
	options := accounts.Options{
		Store: data, Backend: accounts.NewFixtureBackend(), Logger: f.logger, HostHome: f.hostHome,
		MachineName: func() string {
			if identity, err := link.LoadIdentity(data.Root); err == nil {
				return identity.Name
			}
			return ""
		},
	}
	if trust != nil {
		options.Roster = trust.ActiveDaemons
	}
	service, err := accounts.New(options)
	if err != nil {
		// Only a missing store or a relative home fails here; run passes neither.
		panic(err)
	}
	f.services[data] = &fixtureAccountsService{service: service}
	return service
}

// start runs the background work (login checks, usage probes, cleanup of
// removed accounts) of every engine not yet running. It follows seeding, so
// a first probe cannot overwrite the seeded usage.
func (f *fixtureProviderAccounts) start(ctx context.Context) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, entry := range f.services {
		if !entry.started {
			entry.started = true
			go entry.service.Run(ctx)
		}
	}
}

// shutdown cancels the sign-ins of every engine.
func (f *fixtureProviderAccounts) shutdown() {
	f.mu.Lock()
	entries := make([]*fixtureAccountsService, 0, len(f.services))
	for _, entry := range f.services {
		entries = append(entries, entry)
	}
	f.mu.Unlock()
	for _, entry := range entries {
		entry.service.Shutdown()
	}
}

// fixtureAccount is one seeded account and how a machine signs it in.
type fixtureAccount struct {
	id, provider, label, method string
	usage                       func(now time.Time) schema.ProviderUsage
}

var (
	fixtureWork = fixtureAccount{
		id: fixtureWorkAccount, provider: accounts.ProviderClaude, label: "Work", method: accounts.MethodClaudeCode,
		usage: func(now time.Time) schema.ProviderUsage {
			return schema.ProviderUsage{Plan: "max", Source: "probe", Windows: []schema.ProviderUsageWindow{
				{Kind: "five_hour", Label: "5h", UsedPercent: 38, ResetsAt: fixtureResetAt(now, 2*time.Hour+14*time.Minute), DurationMinutes: 300},
				{Kind: "weekly", Label: "Weekly", UsedPercent: 12, ResetsAt: fixtureResetAt(now, 4*24*time.Hour+2*time.Hour), DurationMinutes: 10080},
			}}
		},
	}
	fixturePersonal = fixtureAccount{
		id: fixturePersonalAccount, provider: accounts.ProviderChatGPT, label: "Personal", method: accounts.MethodCodex,
		usage: func(now time.Time) schema.ProviderUsage {
			return schema.ProviderUsage{Plan: "pro", Source: "probe", ResetCredits: &schema.ProviderResetCredits{Available: 1}, Windows: []schema.ProviderUsageWindow{
				{Kind: "five_hour", Label: "5h", UsedPercent: 24, ResetsAt: fixtureResetAt(now, 3*time.Hour+40*time.Minute), DurationMinutes: 300},
				{Kind: "weekly", Label: "Weekly", UsedPercent: 41, ResetsAt: fixtureResetAt(now, 3*24*time.Hour+5*time.Hour), DurationMinutes: 10080},
			}}
		},
	}
)

func fixtureResetAt(now time.Time, after time.Duration) string {
	return now.Add(after).UTC().Truncate(time.Minute).Format(time.RFC3339)
}

// createFixtureAccounts adds "Work" (Claude) and "Personal" (ChatGPT) through
// the accounts engine and makes each its provider's default unless the
// provider already has one. A restarted fixture finds them and changes
// nothing; an account a test removed stays removed.
func createFixtureAccounts(ctx context.Context, service *accounts.Service) error {
	for _, account := range []fixtureAccount{fixtureWork, fixturePersonal} {
		_, err := service.Create(ctx, accounts.CreateInput{Provider: account.provider, Label: account.label, Method: account.method, AccountID: account.id})
		if kind, _ := fault.KindOf(err); kind == fault.AlreadyExists || kind == fault.NotFound {
			// Renamed (a different record under the seeded ID) or removed.
			continue
		}
		if err != nil {
			return fmt.Errorf("seed provider account %s: %w", account.label, err)
		}
	}
	values, err := service.List(ctx, "")
	if err != nil {
		return err
	}
	hasDefault := map[string]bool{}
	present := map[string]bool{}
	for _, value := range values {
		hasDefault[value.Provider] = hasDefault[value.Provider] || value.IsDefault
		present[value.ID] = true
	}
	for _, account := range []fixtureAccount{fixtureWork, fixturePersonal} {
		if hasDefault[account.provider] || !present[account.id] {
			continue
		}
		if _, err := service.SetDefault(ctx, account.id); err != nil {
			return err
		}
	}
	return nil
}

// signInFixtureAccounts signs this daemon in to each account through the
// fixture backend's own sign-in flows (a pasted FIXTURE-CODE for Claude, a
// code=fixture callback for ChatGPT) and records the account's seeded usage
// on this daemon's login record. A login that is already signed in is kept.
// Accounts this daemon does not hold yet (before peer sync) or that were
// removed are skipped.
func signInFixtureAccounts(ctx context.Context, service *accounts.Service, data *boardstore.Store, seeded ...fixtureAccount) error {
	identity, err := data.Replica.PeerIdentity()
	if err != nil {
		return fmt.Errorf("seed provider logins: %w", err)
	}
	values, err := service.List(ctx, "")
	if err != nil {
		return err
	}
	for _, account := range seeded {
		var current *accounts.Account
		for index := range values {
			if values[index].ID == account.id {
				current = &values[index]
			}
		}
		if current == nil {
			continue
		}
		signedIn := false
		for _, login := range current.Logins {
			signedIn = signedIn || login.DaemonID == identity.DaemonID && login.State == accounts.StateSignedIn
		}
		if !signedIn {
			if err := fixtureSignIn(ctx, service, account); err != nil {
				return fmt.Errorf("sign %s in on the fixture: %w", account.label, err)
			}
		}
		if err := seedFixtureUsage(data, identity.DaemonID, account); err != nil {
			return fmt.Errorf("seed %s usage: %w", account.label, err)
		}
	}
	return nil
}

func fixtureSignIn(ctx context.Context, service *accounts.Service, account fixtureAccount) error {
	flow, code, callback := accounts.FlowPasteCode, accounts.FixtureCode, ""
	if account.method == accounts.MethodCodex {
		flow, code, callback = accounts.FlowBrowser, "", "http://localhost:1455/auth/callback?code=fixture&state=fixture"
	}
	login, err := service.StartLogin(ctx, account.id, flow)
	if err != nil {
		return err
	}
	if login.Phase != accounts.PhaseWaiting {
		return fmt.Errorf("the sign-in is %s (%s)", login.Phase, login.ErrorMessage)
	}
	if _, err := service.SubmitLoginInput(ctx, login.ID, code, callback); err != nil {
		return err
	}
	watch, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var last accounts.Login
	if err := service.WatchLogin(watch, login.ID, func(value accounts.Login) error {
		last = value
		return nil
	}); err != nil {
		return err
	}
	if last.Phase != accounts.PhaseSucceeded {
		return fmt.Errorf("the sign-in ended %s: %s", last.Phase, last.ErrorMessage)
	}
	return nil
}

// seedFixtureUsage writes the account's seeded plan usage on this daemon's
// signed-in login record through the KV writer, as a usage probe would.
func seedFixtureUsage(data *boardstore.Store, daemonID string, account fixtureAccount) error {
	var record schema.ProviderLoginRecord
	found := false
	if err := data.KV.EachProviderLogin(schema.ProviderLoginKey(account.id, daemonID), false, func(entry kv.ProviderLoginEntry) error {
		if entry.AccountID == account.id && entry.DaemonID == daemonID {
			record, found = entry.Record, true
		}
		return nil
	}); err != nil {
		return err
	}
	if !found || record.State != accounts.StateSignedIn {
		return errors.New("the login record is not signed in")
	}
	now := time.Now().UTC()
	usage := account.usage(now)
	usage.ObservedAt = now.Format(time.RFC3339)
	record.Usage = &usage
	return data.KV.PutProviderLogin(account.id, daemonID, record)
}

// seedPrimaryProviderAccounts adds the seeded accounts on the primary machine
// and signs it in to both.
func seedPrimaryProviderAccounts(ctx context.Context, service *accounts.Service, data *boardstore.Store) error {
	if err := createFixtureAccounts(ctx, service); err != nil {
		return err
	}
	return signInFixtureAccounts(ctx, service, data, fixtureWork, fixturePersonal)
}

// fixturePeer is one fixture machine taking part in peer sync.
type fixturePeer struct {
	identity *link.Identity
	trust    *link.Trust
	data     *boardstore.Store
	accounts *accounts.Service
}

func (p fixturePeer) sync(logger *slog.Logger) *peersync.PeerSync {
	return &peersync.PeerSync{Identity: p.identity, Trust: p.trust, Store: p.data, Log: logger, Interval: 5 * time.Second}
}

// replicateFixtureProviderAccounts brings the primary's accounts to the
// second machine through peer sync, signs the second machine in to seeded,
// returns its logins to the primary and keeps both machines syncing.
func replicateFixtureProviderAccounts(ctx context.Context, logger *slog.Logger, primary, second fixturePeer, seeded ...fixtureAccount) error {
	primarySync := primary.sync(logger)
	if err := primarySync.Round(ctx); err != nil {
		return fmt.Errorf("replicate the provider accounts: %w", err)
	}
	if err := signInFixtureAccounts(ctx, second.accounts, second.data, seeded...); err != nil {
		return err
	}
	if err := primarySync.Round(ctx); err != nil {
		return fmt.Errorf("replicate the second machine's provider logins: %w", err)
	}
	go primarySync.Run(ctx)
	go second.sync(logger).Run(ctx)
	return nil
}
