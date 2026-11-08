package replica_test

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/replica"
	"github.com/dbpprt/dieter/internal/testkit"
)

// enrolledPeerStore is a store whose daemon is enrolled and pinned a roster of
// only itself, so it verifies owner provenance.
func enrolledPeerStore(t *testing.T) (*store.Store, replica.PeerIdentity, roster.Signer) {
	t.Helper()
	_, signing := testkit.SigningKey(t)
	identity, err := link.LoadOrCreateEnrollmentIdentity(testkit.Home(t), "receiver", "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	if err = identity.SaveCredential("d_receiver", "receiver", []byte("enrollment"), signing, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}
	self := testkit.DaemonSigner(t, identity.PrivateKey, identity.ID, "receiver")
	testkit.PinRoster(t, identity.Root, testkit.TestAccount, self)
	s := store.New(identity.Root)
	if err = s.Ensure(); err != nil {
		t.Fatal(err)
	}
	peer, err := s.Replica.BindPeerAccount("account", "github:42", identity.ID, identity.Issuer())
	if err != nil {
		t.Fatal(err)
	}
	return s, peer, self
}

func TestUnverifiableOwnerRecordIsHeldWithoutBlockingItsPage(t *testing.T) {
	t.Parallel()
	s, peer, self := enrolledPeerStore(t)
	_, ownerKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	checkout := testkit.SignedCheckout(t, peer.Account, "co_unknown", "d_owner", ownerKey)
	setting, err := crdt.Put(crdt.Record{}, "project-settings", "ok", "actor_other", "", []byte(`{}`), false)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Replica.MergePeerRecords(peer, []crdt.Record{checkout, setting}); err != nil {
		t.Fatalf("one unverifiable record failed its page: %v", err)
	}
	data, err := s.Replica.PeerData(peer.Account)
	if err != nil || len(data.Records) != 1 || len(data.Record(crdt.Key("project-settings", "ok")).Versions) != 1 {
		t.Fatalf("page did not merge without the held record: %+v %v", data.Records, err)
	}
	held, err := s.Replica.HeldPeerRecords(peer.Account)
	if err != nil || len(held) != 1 || held[0].Record.ID != "co_unknown.registration" || held[0].Code != "invalid_provenance" || held[0].Field != "registration" {
		t.Fatalf("held: %+v %v", held, err)
	}
	// Receiving it again holds it once.
	if err = s.Replica.MergePeerRecords(peer, []crdt.Record{checkout}); err != nil {
		t.Fatal(err)
	}
	if held, err = s.Replica.HeldPeerRecords(peer.Account); err != nil || len(held) != 1 {
		t.Fatalf("held twice: %+v %v", held, err)
	}

	// Without the owner's key in the roster a retry keeps it held.
	if err = s.Replica.RetryHeldPeerRecords(peer); err != nil {
		t.Fatal(err)
	}
	if data, err = s.Replica.PeerData(peer.Account); err != nil || len(data.Records) != 1 {
		t.Fatalf("unverified record merged: %+v %v", data.Records, err)
	}
	if held, err = s.Replica.HeldPeerRecords(peer.Account); err != nil || len(held) != 1 {
		t.Fatalf("held record dropped: %+v %v", held, err)
	}

	// Once the roster binds the owner's key, the next retry merges it.
	owner := testkit.DaemonSigner(t, ownerKey, "d_owner", "owner")
	testkit.PinRoster(t, s.Root, testkit.TestAccount, self, owner.Descriptor())
	if err = s.Replica.RetryHeldPeerRecords(peer); err != nil {
		t.Fatal(err)
	}
	data, err = s.Replica.PeerData(peer.Account)
	if err != nil || len(data.Record(crdt.Key("checkout", "co_unknown.registration")).Versions) != 1 {
		t.Fatalf("verified record did not merge: %+v %v", data.Records, err)
	}
	if held, err = s.Replica.HeldPeerRecords(peer.Account); err != nil || len(held) != 0 {
		t.Fatalf("merged record still held: %+v %v", held, err)
	}
}

func TestHeldPeerRecordsAreBounded(t *testing.T) {
	t.Parallel()
	s, peer, _ := enrolledPeerStore(t)
	_, ownerKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var records []crdt.Record
	for i := range replica.MaxHeldRecords + 1 {
		records = append(records, testkit.SignedCheckout(t, peer.Account, fmt.Sprintf("co_%03d", i), "d_owner", ownerKey))
	}
	for len(records) > 1 {
		n := min(len(records)-1, crdt.PageSize)
		if err = s.Replica.MergePeerRecords(peer, records[:n]); err != nil {
			t.Fatal(err)
		}
		records = records[n:]
	}
	setting, err := crdt.Put(crdt.Record{}, "project-settings", "ok", "actor_other", "", []byte(`{}`), false)
	if err != nil {
		t.Fatal(err)
	}
	err = s.Replica.MergePeerRecords(peer, []crdt.Record{setting, records[0]})
	var rejected *replica.PeerRecordError
	if !errors.As(err, &rejected) || rejected.ID != records[0].ID || rejected.Code != "invalid_provenance" {
		t.Fatalf("a full held set accepted another record: %v", err)
	}
	data, err := s.Replica.PeerData(peer.Account)
	if err != nil || len(data.Records) != 0 {
		t.Fatalf("rejected page partially merged: %+v %v", data.Records, err)
	}
	held, err := s.Replica.HeldPeerRecords(peer.Account)
	if err != nil || len(held) != replica.MaxHeldRecords {
		t.Fatalf("held: %d %v", len(held), err)
	}
}
