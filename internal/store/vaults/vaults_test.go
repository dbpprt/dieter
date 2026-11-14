package vaults

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/security/vault"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/replica"
)

func vaultReplica(t *testing.T, daemon string) (*Store, replica.PeerIdentity) {
	t.Helper()
	s := New(store.New(t.TempDir()))
	identity, err := s.store.Replica.BindPeerAccount("account", "github:1", daemon, "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	return s, identity
}

// replicateVault copies every peer record the way anti-entropy would.
func replicateVault(t *testing.T, from *Store, to *Store, identity replica.PeerIdentity) {
	t.Helper()
	data, err := from.store.Replica.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	var page []crdt.Record
	for _, record := range data.Records {
		page = append(page, record)
		if len(page) == crdt.PageSize {
			if err = to.store.Replica.MergePeerRecords(identity, page); err != nil {
				t.Fatal(err)
			}
			page = nil
		}
	}
	if len(page) > 0 {
		if err = to.store.Replica.MergePeerRecords(identity, page); err != nil {
			t.Fatal(err)
		}
	}
}

func TestVaultJoinByCodeRecoveryRotationAndRemoval(t *testing.T) {
	t.Parallel()
	a, identityA := vaultReplica(t, "daemon-a")
	b, identityB := vaultReplica(t, "daemon-b")
	c, identityC := vaultReplica(t, "daemon-c")

	recoveryKey, err := a.Init("alpha", "daemon-a")
	if err != nil || !strings.HasPrefix(recoveryKey, "DVR1-") {
		t.Fatalf("init = %q, %v", recoveryKey, err)
	}
	if _, err = a.Init("alpha", "daemon-a"); err == nil {
		t.Fatal("second init accepted")
	}
	created, err := a.CreateItem(vault.Item{Name: "GitHub", URLs: []string{"https://github.com"}, Username: "octo", Password: "correct horse battery staple"}, "operator")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = a.CreateItem(vault.Item{Name: "github", Password: "x"}, "operator"); err == nil {
		t.Fatal("duplicate name accepted")
	}

	// The replicated store holds only ciphertext.
	data, _ := a.store.Replica.PeerData(identityA.Account)
	raw, _ := json.Marshal(data.Records)
	if strings.Contains(string(raw), "correct horse") || strings.Contains(string(raw), "GitHub") || strings.Contains(string(raw), "octo") {
		t.Fatal("peer state contains plaintext item content")
	}

	// B joins by code.
	replicateVault(t, a, b, identityB)
	if status, _ := b.Status(); status.State != VaultStateLocked {
		t.Fatalf("B state = %s", status.State)
	}
	if _, err = b.ListItems(); !errors.Is(err, vault.ErrLocked) {
		t.Fatalf("locked list = %v", err)
	}
	code, err := b.RequestJoin("bravo", "daemon-b")
	if err != nil {
		t.Fatal(err)
	}
	status, _ := b.Status()
	if status.State != VaultStatePending || status.JoinCode != code {
		t.Fatalf("B pending status = %+v", status)
	}
	replicateVault(t, b, a, identityA)
	statusA, _ := a.Status()
	var pending Member
	for _, member := range statusA.Members {
		if member.Pending && !member.Recovery {
			pending = member
		}
	}
	if pending.Code != code {
		t.Fatalf("A computes code %q, B shows %q", pending.Code, code)
	}
	if err = a.ApproveMember(pending.ID, "AAAA-AAAA-AAAA-AAAA"); err == nil {
		t.Fatal("wrong code accepted")
	}
	if err = a.ApproveMember(pending.ID, strings.ToLower(code)); err != nil {
		t.Fatal(err)
	}
	replicateVault(t, a, b, identityB)
	item, err := b.Item("github")
	if err != nil || item.Item.Password != "correct horse battery staple" || item.ID != created.ID {
		t.Fatalf("B item = %+v, %v", item, err)
	}

	// C joins with the recovery key without any member online.
	replicateVault(t, a, c, identityC)
	if err = c.JoinWithRecovery("DVR1-"+strings.Repeat("0", 55), "charlie", "daemon-c"); err == nil {
		t.Fatal("wrong recovery key accepted")
	}
	if err = c.JoinWithRecovery(recoveryKey, "charlie", "daemon-c"); err != nil {
		t.Fatal(err)
	}
	if items, err := c.ListItems(); err != nil || len(items) != 1 {
		t.Fatalf("C items = %v, %v", items, err)
	}
	replicateVault(t, c, a, identityA)
	replicateVault(t, a, b, identityB)

	// Removing C rotates to a key C never receives; B keeps access.
	statusC, _ := c.Status()
	if err = a.RemoveMember(statusC.MemberID); err != nil {
		t.Fatal(err)
	}
	if _, err = a.CreateItem(vault.Item{Name: "AWS", Password: "after-rotation"}, "operator"); err != nil {
		t.Fatal(err)
	}
	replicateVault(t, a, b, identityB)
	replicateVault(t, a, c, identityC)
	if item, err := b.Item("AWS"); err != nil || item.Item.Password != "after-rotation" {
		t.Fatalf("B after rotation = %+v, %v", item, err)
	}
	if _, err := c.ListItems(); !errors.Is(err, vault.ErrLocked) {
		t.Fatalf("removed C still unlocked: %v", err)
	}

	// A new recovery key replaces the old one.
	next, err := a.Rotate(true)
	if err != nil || next == "" || next == recoveryKey {
		t.Fatalf("rotate recovery = %q, %v", next, err)
	}
	d, identityD := vaultReplica(t, "daemon-d")
	replicateVault(t, a, d, identityD)
	if err = d.JoinWithRecovery(recoveryKey, "delta", "daemon-d"); !errors.Is(err, vault.ErrWrongRecovery) {
		t.Fatalf("old recovery key = %v", err)
	}
	if err = d.JoinWithRecovery(next, "delta", "daemon-d"); err != nil {
		t.Fatal(err)
	}
}

func TestVaultRejectsSubstitutedRootAfterJoin(t *testing.T) {
	t.Parallel()
	a, _ := vaultReplica(t, "daemon-a")
	b, identityB := vaultReplica(t, "daemon-b")
	if _, err := a.Init("alpha", "daemon-a"); err != nil {
		t.Fatal(err)
	}
	replicateVault(t, a, b, identityB)
	code, err := b.RequestJoin("bravo", "daemon-b")
	if err != nil {
		t.Fatal(err)
	}
	// An attacker replaces the replicated vault root before approval.
	attacker, ring := vault.New("2026-10-10T00:00:00Z")
	attacker.ID = mustVaultRecord(t, b).ID
	if err = b.mutateVault(func(identity replica.PeerIdentity, view vaultView) error {
		return putVaultRecord(view.data, identity, vault.KindVault, vault.VaultRecordID, attacker, false)
	}); err != nil {
		t.Fatal(err)
	}
	status, _ := b.Status()
	if status.JoinCode != code {
		t.Fatal("pinned code changed after the replicated root changed")
	}
	_ = ring
}

func mustVaultRecord(t *testing.T, s *Store) vault.Record {
	t.Helper()
	var record vault.Record
	if err := s.withVault(func(view vaultView) error { record = view.record; return nil }); err != nil {
		t.Fatal(err)
	}
	return record
}

func TestVaultAuditIsBoundedAndFiltered(t *testing.T) {
	t.Parallel()
	s := New(store.New(t.TempDir()))
	for _, entry := range []AuditEntry{{Action: "reveal", ItemID: "vi_a", Caller: "agent", CardID: "c_1", Outcome: "allowed"}, {Action: "reveal", ItemID: "vi_b", Caller: "operator", Outcome: "allowed"}} {
		if err := s.AppendAudit(entry); err != nil {
			t.Fatal(err)
		}
	}
	entries, err := s.Audit(10, "", "c_1")
	if err != nil || len(entries) != 1 || entries[0].ItemID != "vi_a" {
		t.Fatalf("entries = %+v, %v", entries, err)
	}
	all, _ := s.Audit(10, "", "")
	if len(all) != 2 || all[0].ItemID != "vi_b" {
		t.Fatalf("newest first = %+v", all)
	}
}
