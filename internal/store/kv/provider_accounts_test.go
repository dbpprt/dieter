package kv_test

import (
	"errors"
	"testing"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kv"
	"github.com/dbpprt/dieter/internal/store/replica"
)

const providerAccount = "pa_abcdefghijklmnopqrstuvwxyz"

func providerStore(t *testing.T, daemon string) (*store.Store, replica.PeerIdentity) {
	t.Helper()
	s := store.New(t.TempDir())
	identity, err := s.Replica.BindPeerAccount("account", "github:1", daemon, "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	return s, identity
}

func work(daemon string) schema.ProviderAccountRecord {
	return schema.ProviderAccountRecord{Provider: schema.ProviderClaude, Label: "Work", Method: schema.MethodClaudeCode, IncludeInSummary: true, CreatedAt: "2026-11-14T10:00:00Z", CreatedBy: daemon}
}

func TestProviderAccountCompareAndSetBindsIdentityOnce(t *testing.T) {
	t.Parallel()
	s, identity := providerStore(t, "d_one")
	created, err := s.KV.PutProviderAccount(providerAccount, func(current *schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
		if current != nil {
			t.Fatal("account exists before creation")
		}
		next := work(identity.DaemonID)
		return &next, nil
	})
	if err != nil || created.Label != "Work" {
		t.Fatalf("create = %+v, %v", created, err)
	}
	bind := func(email string) (schema.ProviderAccountRecord, error) {
		return s.KV.PutProviderAccount(providerAccount, func(current *schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
			if current.Identity != nil {
				if current.Identity.Email != email {
					return nil, fault.New(fault.FailedPrecondition, "identity_mismatch")
				}
				return nil, nil
			}
			next := *current
			next.Identity = &schema.ProviderIdentity{Email: email}
			return &next, nil
		})
	}
	if bound, err := bind("alice@example.com"); err != nil || bound.Identity.Email != "alice@example.com" {
		t.Fatalf("bind = %+v, %v", bound, err)
	}
	if _, err := bind("bob@example.com"); err == nil {
		t.Fatal("second identity bound")
	}
	if kept, err := bind("alice@example.com"); err != nil || kept.Identity.Email != "alice@example.com" {
		t.Fatalf("rebind = %+v, %v", kept, err)
	}
	var seen []kv.ProviderAccountEntry
	if err := s.KV.EachProviderAccount(func(entry kv.ProviderAccountEntry) error {
		seen = append(seen, entry)
		return nil
	}); err != nil || len(seen) != 1 || seen[0].Record.Identity.Email != "alice@example.com" || seen[0].Revision == "" {
		t.Fatalf("each = %+v, %v", seen, err)
	}
}

func TestProviderAccountConcurrentWritersRetryOnTheirRevision(t *testing.T) {
	t.Parallel()
	s, identity := providerStore(t, "d_one")
	if _, err := s.KV.PutProviderAccount(providerAccount, func(*schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
		next := work(identity.DaemonID)
		return &next, nil
	}); err != nil {
		t.Fatal(err)
	}
	calls := 0
	renamed, err := s.KV.PutProviderAccount(providerAccount, func(current *schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
		calls++
		if calls == 1 {
			// A concurrent writer changes the record between read and write.
			if _, err := s.KV.PutProviderAccount(providerAccount, func(current *schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
				next := *current
				next.IncludeInSummary = false
				return &next, nil
			}); err != nil {
				t.Fatal(err)
			}
		}
		next := *current
		next.Label = "Renamed"
		return &next, nil
	})
	if err != nil || calls != 2 || renamed.Label != "Renamed" || renamed.IncludeInSummary {
		t.Fatalf("rename = %+v after %d calls, %v", renamed, calls, err)
	}
}

func TestProviderAccountTombstonesRefuseLaterWrites(t *testing.T) {
	t.Parallel()
	s, identity := providerStore(t, "d_one")
	create := func(*schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
		next := work(identity.DaemonID)
		return &next, nil
	}
	if _, err := s.KV.PutProviderAccount(providerAccount, create); err != nil {
		t.Fatal(err)
	}
	if err := s.KV.PutProviderDefault(schema.ProviderClaude, providerAccount); err != nil {
		t.Fatal(err)
	}
	if err := s.KV.DeleteProviderAccount(providerAccount); err != nil {
		t.Fatal(err)
	}
	if err := s.KV.DeleteProviderAccount(providerAccount); err != nil {
		t.Fatalf("second delete: %v", err)
	}
	if _, err := s.KV.PutProviderAccount(providerAccount, create); !errors.Is(err, kv.ErrProviderAccountRemoved) {
		t.Fatalf("write after delete = %v", err)
	}
	var entries []kv.ProviderAccountEntry
	_ = s.KV.EachProviderAccount(func(entry kv.ProviderAccountEntry) error {
		entries = append(entries, entry)
		return nil
	})
	if len(entries) != 1 || !entries[0].Deleted {
		t.Fatalf("entries = %+v", entries)
	}
	defaults := map[string]string{}
	_ = s.KV.EachProviderDefault(func(provider string, value schema.ProviderDefaultRecord) error {
		defaults[provider] = value.AccountID
		return nil
	})
	if defaults[schema.ProviderClaude] != providerAccount {
		t.Fatalf("defaults = %v", defaults)
	}
	if err := s.KV.DeleteProviderDefault(schema.ProviderClaude); err != nil {
		t.Fatal(err)
	}
	defaults = map[string]string{}
	_ = s.KV.EachProviderDefault(func(provider string, value schema.ProviderDefaultRecord) error {
		defaults[provider] = value.AccountID
		return nil
	})
	if len(defaults) != 0 {
		t.Fatalf("default survived deletion: %v", defaults)
	}
}

func TestProviderLoginsHaveOneWriterAndSkipUnchangedValues(t *testing.T) {
	t.Parallel()
	s, identity := providerStore(t, "d_one")
	login := schema.ProviderLoginRecord{State: schema.LoginSignedIn, Method: schema.MethodClaudeCode, VerifiedAt: "2026-11-14T10:00:00Z",
		Usage: &schema.ProviderUsage{ObservedAt: "2026-11-14T10:00:00Z", Windows: []schema.ProviderUsageWindow{{Kind: "five_hour", UsedPercent: 12.5}}}}
	if err := s.KV.PutProviderLogin(providerAccount, identity.DaemonID, login); err != nil {
		t.Fatal(err)
	}
	before := loginRecord(t, s, identity)
	if err := s.KV.PutProviderLogin(providerAccount, identity.DaemonID, login); err != nil {
		t.Fatal(err)
	}
	if after := loginRecord(t, s, identity); after.Revision() != before.Revision() {
		t.Fatal("unchanged login was rewritten")
	}
	if err := s.KV.PutProviderLogin(providerAccount, "d_other", login); err == nil {
		t.Fatal("wrote another machine's login record")
	}
	var logins []kv.ProviderLoginEntry
	_ = s.KV.EachProviderLogin(providerAccount+".", false, func(entry kv.ProviderLoginEntry) error {
		logins = append(logins, entry)
		return nil
	})
	if len(logins) != 1 || logins[0].DaemonID != identity.DaemonID || logins[0].Record.Usage.Windows[0].UsedPercent != 12.5 {
		t.Fatalf("logins = %+v", logins)
	}
	if err := s.KV.DeleteProviderLogin(providerAccount, identity.DaemonID); err != nil {
		t.Fatal(err)
	}
	logins = nil
	_ = s.KV.EachProviderLogin("", false, func(entry kv.ProviderLoginEntry) error {
		logins = append(logins, entry)
		return nil
	})
	if len(logins) != 0 {
		t.Fatalf("deleted login listed: %+v", logins)
	}
	_ = s.KV.EachProviderLogin("", true, func(entry kv.ProviderLoginEntry) error {
		logins = append(logins, entry)
		return nil
	})
	if len(logins) != 1 || !logins[0].Deleted {
		t.Fatalf("tombstone not visited: %+v", logins)
	}
}

func TestProviderWritersNeedAReplicaIdentity(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	err := s.KV.PutProviderDefault(schema.ProviderClaude, providerAccount)
	if kind, _ := fault.KindOf(err); kind != fault.FailedPrecondition {
		t.Fatalf("write without identity = %v", err)
	}
	// Reading never creates one.
	if err := s.KV.EachProviderAccount(func(kv.ProviderAccountEntry) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Replica.PeerIdentity(); err == nil {
		t.Fatal("a read created the replica identity")
	}
}

func loginRecord(t *testing.T, s *store.Store, identity replica.PeerIdentity) crdt.Record {
	t.Helper()
	data, err := s.Replica.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	return data.Records[crdt.Key(schema.KVKindPrefix+schema.ProviderLoginsNamespace, schema.ProviderLoginKey(providerAccount, identity.DaemonID))]
}
