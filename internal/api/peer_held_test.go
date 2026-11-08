package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/testkit"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestPeerStoreStatusListsHeldRecords(t *testing.T) {
	t.Parallel()
	s := testkit.Store(t)
	defer s.Close()
	_, signing := testkit.SigningKey(t)
	identity, err := link.LoadOrCreateEnrollmentIdentity(s.Root, "receiver", "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	if err = identity.SaveCredential("d_receiver", "receiver", []byte("enrollment"), signing, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}
	testkit.PinRoster(t, s.Root, testkit.TestAccount, testkit.DaemonSigner(t, identity.PrivateKey, identity.ID, "receiver"))
	peer, err := s.Replica.BindPeerAccount("account", "github:42", identity.ID, identity.Issuer())
	if err != nil {
		t.Fatal(err)
	}
	_, ownerKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Replica.MergePeerRecords(peer, []crdt.Record{testkit.SignedCheckout(t, peer.Account, "co_unknown", "d_owner", ownerKey)}); err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, s, newFakeRunner())
	status, err := client.GetPeerStoreStatus(t.Context(), &emptypb.Empty{})
	if err != nil {
		t.Fatal(err)
	}
	if len(status.GetHeld()) != 1 {
		t.Fatalf("held: %+v", status.GetHeld())
	}
	held := status.GetHeld()[0]
	if held.GetKind() != "checkout" || held.GetId() != "co_unknown.registration" || held.GetField() != "registration" || held.GetFailureCode() != "invalid_provenance" || held.GetHeldAt() == "" {
		t.Fatalf("held: %+v", held)
	}
}
