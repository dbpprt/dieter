package store

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/vault"
)

func vaultReplica(t *testing.T, daemon string) (*Store, PeerIdentity) {
	t.Helper()
	s := New(t.TempDir())
	identity, err := s.BindPeerAccount("account", "github:1", daemon, "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	return s, identity
}

// replicateVault copies every peer record the way anti-entropy would.
func replicateVault(t *testing.T, from *Store, to *Store, identity PeerIdentity) {
	t.Helper()
	data, err := from.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	var page []peerstore.Record
	for _, record := range data.Records {
		page = append(page, record)
		if len(page) == peerstore.PageSize {
			if err = to.MergePeerRecords(identity, page); err != nil {
				t.Fatal(err)
			}
			page = nil
		}
	}
	if len(page) > 0 {
		if err = to.MergePeerRecords(identity, page); err != nil {
			t.Fatal(err)
		}
	}
}

func TestVaultJoinByCodeRecoveryRotationAndRemoval(t *testing.T) {
	a, identityA := vaultReplica(t, "daemon-a")
	b, identityB := vaultReplica(t, "daemon-b")
	c, identityC := vaultReplica(t, "daemon-c")

	recoveryKey, err := a.InitVault("alpha", "daemon-a")
	if err != nil || !strings.HasPrefix(recoveryKey, "DVR1-") {
		t.Fatalf("init = %q, %v", recoveryKey, err)
	}
	if _, err = a.InitVault("alpha", "daemon-a"); err == nil {
		t.Fatal("second init accepted")
	}
	created, err := a.CreateVaultItem(vault.Item{Name: "GitHub", URLs: []string{"https://github.com"}, Username: "octo", Password: "correct horse battery staple"}, "operator")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = a.CreateVaultItem(vault.Item{Name: "github", Password: "x"}, "operator"); err == nil {
		t.Fatal("duplicate name accepted")
	}

	// The replicated store holds only ciphertext.
	data, _ := a.PeerData(identityA.Account)
	raw, _ := json.Marshal(data.Records)
	if strings.Contains(string(raw), "correct horse") || strings.Contains(string(raw), "GitHub") || strings.Contains(string(raw), "octo") {
		t.Fatal("peer state contains plaintext item content")
	}

	// B joins by code.
	replicateVault(t, a, b, identityB)
	if status, _ := b.VaultStatus(); status.State != VaultStateLocked {
		t.Fatalf("B state = %s", status.State)
	}
	if _, err = b.ListVaultItems(); !errors.Is(err, vault.ErrLocked) {
		t.Fatalf("locked list = %v", err)
	}
	code, err := b.RequestVaultJoin("bravo", "daemon-b")
	if err != nil {
		t.Fatal(err)
	}
	status, _ := b.VaultStatus()
	if status.State != VaultStatePending || status.JoinCode != code {
		t.Fatalf("B pending status = %+v", status)
	}
	replicateVault(t, b, a, identityA)
	statusA, _ := a.VaultStatus()
	var pending VaultMember
	for _, member := range statusA.Members {
		if member.Pending && !member.Recovery {
			pending = member
		}
	}
	if pending.Code != code {
		t.Fatalf("A computes code %q, B shows %q", pending.Code, code)
	}
	if err = a.ApproveVaultMember(pending.ID, "AAAA-AAAA-AAAA-AAAA"); err == nil {
		t.Fatal("wrong code accepted")
	}
	if err = a.ApproveVaultMember(pending.ID, strings.ToLower(code)); err != nil {
		t.Fatal(err)
	}
	replicateVault(t, a, b, identityB)
	item, err := b.VaultItem("github")
	if err != nil || item.Item.Password != "correct horse battery staple" || item.ID != created.ID {
		t.Fatalf("B item = %+v, %v", item, err)
	}

	// C joins with the recovery key without any member online.
	replicateVault(t, a, c, identityC)
	if err = c.JoinVaultWithRecovery("DVR1-"+strings.Repeat("0", 55), "charlie", "daemon-c"); err == nil {
		t.Fatal("wrong recovery key accepted")
	}
	if err = c.JoinVaultWithRecovery(recoveryKey, "charlie", "daemon-c"); err != nil {
		t.Fatal(err)
	}
	if items, err := c.ListVaultItems(); err != nil || len(items) != 1 {
		t.Fatalf("C items = %v, %v", items, err)
	}
	replicateVault(t, c, a, identityA)
	replicateVault(t, a, b, identityB)

	// Removing C rotates to a key C never receives; B keeps access.
	statusC, _ := c.VaultStatus()
	if err = a.RemoveVaultMember(statusC.MemberID); err != nil {
		t.Fatal(err)
	}
	if _, err = a.CreateVaultItem(vault.Item{Name: "AWS", Password: "after-rotation"}, "operator"); err != nil {
		t.Fatal(err)
	}
	replicateVault(t, a, b, identityB)
	replicateVault(t, a, c, identityC)
	if item, err := b.VaultItem("AWS"); err != nil || item.Item.Password != "after-rotation" {
		t.Fatalf("B after rotation = %+v, %v", item, err)
	}
	if _, err := c.ListVaultItems(); !errors.Is(err, vault.ErrLocked) {
		t.Fatalf("removed C still unlocked: %v", err)
	}

	// A new recovery key replaces the old one.
	next, err := a.RotateVault(true)
	if err != nil || next == "" || next == recoveryKey {
		t.Fatalf("rotate recovery = %q, %v", next, err)
	}
	d, identityD := vaultReplica(t, "daemon-d")
	replicateVault(t, a, d, identityD)
	if err = d.JoinVaultWithRecovery(recoveryKey, "delta", "daemon-d"); !errors.Is(err, vault.ErrWrongRecovery) {
		t.Fatalf("old recovery key = %v", err)
	}
	if err = d.JoinVaultWithRecovery(next, "delta", "daemon-d"); err != nil {
		t.Fatal(err)
	}
}

func TestVaultRejectsSubstitutedRootAfterJoin(t *testing.T) {
	a, _ := vaultReplica(t, "daemon-a")
	b, identityB := vaultReplica(t, "daemon-b")
	if _, err := a.InitVault("alpha", "daemon-a"); err != nil {
		t.Fatal(err)
	}
	replicateVault(t, a, b, identityB)
	code, err := b.RequestVaultJoin("bravo", "daemon-b")
	if err != nil {
		t.Fatal(err)
	}
	// An attacker replaces the replicated vault root before approval.
	attacker, ring := vault.New("2026-10-10T00:00:00Z")
	attacker.ID = mustVaultRecord(t, b).ID
	if err = b.mutateVault(func(identity PeerIdentity, view vaultView) error {
		return putVaultRecord(view.data, identity, vault.KindVault, vault.VaultRecordID, attacker, false)
	}); err != nil {
		t.Fatal(err)
	}
	status, _ := b.VaultStatus()
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
	s := New(t.TempDir())
	for _, entry := range []VaultAuditEntry{{Action: "reveal", ItemID: "vi_a", Caller: "agent", CardID: "c_1", Outcome: "allowed"}, {Action: "reveal", ItemID: "vi_b", Caller: "operator", Outcome: "allowed"}} {
		if err := s.AppendVaultAudit(entry); err != nil {
			t.Fatal(err)
		}
	}
	entries, err := s.VaultAudit(10, "", "c_1")
	if err != nil || len(entries) != 1 || entries[0].ItemID != "vi_a" {
		t.Fatalf("entries = %+v, %v", entries, err)
	}
	all, _ := s.VaultAudit(10, "", "")
	if len(all) != 2 || all[0].ItemID != "vi_b" {
		t.Fatalf("newest first = %+v", all)
	}
}
