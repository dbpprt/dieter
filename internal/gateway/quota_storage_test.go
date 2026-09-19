package gateway

import (
	"bytes"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

func TestProviderCorrelationKeyIsStableAndOwnerScoped(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	first, err := store.ProviderCorrelationKey(41)
	if err != nil {
		t.Fatal(err)
	}
	again, err := store.ProviderCorrelationKey(41)
	if err != nil {
		t.Fatal(err)
	}
	other, err := store.ProviderCorrelationKey(42)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 32 || !bytes.Equal(first, again) {
		t.Fatal("correlation key was not a stable 32-byte value")
	}
	if bytes.Equal(first, other) {
		t.Fatal("different gateway owners shared a correlation key")
	}
}

func TestReplaceProviderAccountPresenceSeparatesMultipleAccounts(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const owner int64 = 71
	const daemonID = "daemon-quota-test"
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	if _, err := store.DB.Exec(`INSERT INTO daemons(id, name, github_id, login, public_key, certificate, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?)`, daemonID, "quota test", owner, "owner", []byte("key"), []byte("cert"), now.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	accounts := []*gatewayv1.ProviderAccountPresence{
		{Provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa", AccountKind: gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION, Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, RefreshSupported: true},
		{Provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, AccountKey: "account_key_bbbbbbbbbbbbbbbbbbbb", AccountKind: gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION, Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, RefreshSupported: true},
	}
	if err := store.ReplaceProviderAccountPresence(owner, daemonID, accounts, now); err != nil {
		t.Fatal(err)
	}
	records, err := store.ListProviderQuotaRecords(owner, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := len(records), 2; got != want {
		t.Fatalf("records = %d, want %d", got, want)
	}
	if records[0].Account.GetAccountKey() == records[1].Account.GetAccountKey() {
		t.Fatal("distinct provider accounts were collapsed")
	}
	for _, record := range records {
		if !record.SummaryIncluded {
			t.Fatalf("new account %s was excluded by default", record.Account.GetAccountKey())
		}
		if got, want := len(record.Sources), 1; got != want {
			t.Fatalf("sources for %s = %d, want %d", record.Account.GetAccountKey(), got, want)
		}
	}
	if err := store.SetProviderQuotaSummaryIncluded(owner, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, accounts[1].GetAccountKey(), false); err != nil {
		t.Fatal(err)
	}
	records, err = store.ListProviderQuotaRecords(owner, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX)
	if err != nil {
		t.Fatal(err)
	}
	if records[1].SummaryIncluded {
		t.Fatal("summary exclusion was not persisted")
	}
	if err := store.ReplaceProviderAccountPresence(owner, daemonID, accounts[:1], now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := store.ReplaceProviderAccountPresence(owner, daemonID, accounts, now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	records, err = store.ListProviderQuotaRecords(owner, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX)
	if err != nil {
		t.Fatal(err)
	}
	if records[1].SummaryIncluded {
		t.Fatal("summary exclusion was lost when the account source temporarily disappeared")
	}
	firstKey := accounts[0].GetAccountKey()
	if err := store.SaveProviderQuotaSnapshot(owner, daemonID, &gatewayv1.ProviderQuotaSnapshot{
		Provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, AccountKey: firstKey,
		AccountKind:  gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION,
		Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
		Windows:      []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", RemainingPercent: proto.Uint32(55)}},
	}, now); err != nil {
		t.Fatal(err)
	}
	unavailable := proto.Clone(accounts[0]).(*gatewayv1.ProviderAccountPresence)
	unavailable.Availability = gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE
	if err := store.ReplaceProviderAccountPresence(owner, daemonID, []*gatewayv1.ProviderAccountPresence{unavailable}, now.Add(30*time.Second)); err != nil {
		t.Fatal(err)
	}
	// Simulate a refresh that started before the newer unavailable presence
	// frame and completed afterward. Its numeric data is still useful, but it
	// must not make the account appear available again.
	if err := store.SaveProviderQuotaSnapshot(owner, daemonID, &gatewayv1.ProviderQuotaSnapshot{
		Provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, AccountKey: firstKey,
		AccountKind:  gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION,
		Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
		Windows:      []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", RemainingPercent: proto.Uint32(54)}},
	}, now.Add(45*time.Second)); err != nil {
		t.Fatal(err)
	}
	manager := NewQuotaManager(store, NewHub(store, Config{}), nil)
	groups, err := manager.Catalog(owner, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 || len(groups[0].GetAccounts()) != 1 ||
		groups[0].GetAccounts()[0].GetAvailability() != gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE {
		t.Fatalf("latest presence did not override stored snapshot state: %#v", groups)
	}
	machines := groups[0].GetAccounts()[0].GetMachines()
	if len(machines) != 1 || machines[0].GetDaemonId() != daemonID || machines[0].GetName() != "quota test" || machines[0].GetOnline() {
		t.Fatalf("account machine presence = %#v", machines)
	}
	if err := store.ReplaceProviderAccountPresence(owner, daemonID, nil, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	records, err = store.ListProviderQuotaRecords(owner, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 0 {
		t.Fatalf("signed-out presence retained %d unreachable accounts", len(records))
	}
}

func TestReplaceProviderAccountPresenceKeepsAccountAvailableFromAnySource(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const owner int64 = 72
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	for _, daemonID := range []string{"daemon-available", "daemon-unavailable"} {
		if _, err := store.DB.Exec(`INSERT INTO daemons(id, name, github_id, login, public_key, certificate, created_at)
			VALUES(?, ?, ?, ?, ?, ?, ?)`, daemonID, daemonID, owner, "owner", []byte("key"), []byte("cert"), now.Format(time.RFC3339Nano)); err != nil {
			t.Fatal(err)
		}
	}
	available := &gatewayv1.ProviderAccountPresence{
		Provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa",
		AccountKind:  gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION,
		Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, RefreshSupported: true,
	}
	unavailable := proto.Clone(available).(*gatewayv1.ProviderAccountPresence)
	unavailable.Availability = gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE
	if err := store.ReplaceProviderAccountPresence(owner, "daemon-available", []*gatewayv1.ProviderAccountPresence{available}, now); err != nil {
		t.Fatal(err)
	}
	if err := store.ReplaceProviderAccountPresence(owner, "daemon-unavailable", []*gatewayv1.ProviderAccountPresence{unavailable}, now); err != nil {
		t.Fatal(err)
	}
	records, err := store.ListProviderQuotaRecords(owner, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].Account.GetAvailability() != gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE {
		t.Fatalf("available source was overridden: %#v", records)
	}
	if err := store.ReplaceProviderAccountPresence(owner, "daemon-available", nil, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	records, err = store.ListProviderQuotaRecords(owner, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].Account.GetAvailability() != gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE {
		t.Fatalf("remaining unavailable source was not reflected: %#v", records)
	}
}
