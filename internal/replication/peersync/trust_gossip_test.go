package peersync

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"log/slog"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
)

// trustPeer is the TrustService of a peer daemon, served by its device trust.
type trustPeer struct {
	dieterclient.Client
	trust *link.Trust
}

func (p trustPeer) GetTrustStatus(context.Context, *emptypb.Empty, ...grpc.CallOption) (*dieterv1.TrustStatus, error) {
	return p.trust.Status(), nil
}

func (p trustPeer) GetDeviceRoster(_ context.Context, request *gatewayv1.GetDeviceRosterRequest, _ ...grpc.CallOption) (*gatewayv1.DeviceRoster, error) {
	return p.trust.Entries(request.GetFromSequence()), nil
}

func (p trustPeer) SyncDeviceRoster(ctx context.Context, request *dieterv1.SyncDeviceRosterRequest, _ ...grpc.CallOption) (*dieterv1.TrustStatus, error) {
	return p.trust.Sync(ctx, request.GetEntries())
}

// gossipDaemon is a daemon whose gateway is unreachable, so peers are its only
// source of roster entries.
func gossipDaemon(t *testing.T, id string) (*link.Identity, roster.Signer) {
	t.Helper()
	_, signing := testkit.SigningKey(t)
	identity, err := link.LoadOrCreateEnrollmentIdentity(t.TempDir(), id, "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	if err := identity.SaveCredential(id, id, []byte("enrollment"), signing, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}
	return identity, testkit.DaemonSigner(t, identity.PrivateKey, id, id)
}

func openGossipTrust(t *testing.T, identity *link.Identity) *link.Trust {
	t.Helper()
	deviceTrust, err := link.OpenTrust(identity, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	deviceTrust.Gateway = func(context.Context) (grpc.ClientConnInterface, error) {
		return nil, errors.New("the gateway withholds the roster")
	}
	return deviceTrust
}

func TestPeerSyncGossipsRosterHeadsBothWaysAndDetectsForks(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	a, signerA := gossipDaemon(t, "d_a")
	b, signerB := gossipDaemon(t, "d_b")
	c, signerC := gossipDaemon(t, "d_c")
	// A revoked an app after B last synced: B lags one entry behind.
	_, appKey, _ := ed25519.GenerateKey(rand.Reader)
	app, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "ios", "Phone", "", appKey.Public())
	if err != nil {
		t.Fatal(err)
	}
	state := testkit.PinRoster(t, a.Root, testkit.TestAccount, signerA, signerB.Descriptor(), signerC.Descriptor(), app)
	testkit.WriteRoster(t, b.Root, state)
	revoke, err := state.Revoke(app.GetDeviceId(), signerA)
	if err != nil {
		t.Fatal(err)
	}
	revoked, err := state.Extend([]*roster.Entry{revoke})
	if err != nil {
		t.Fatal(err)
	}
	testkit.WriteRoster(t, a.Root, revoked)
	trustA, trustB := openGossipTrust(t, a), openGossipTrust(t, b)
	// A pushes its newer head to B.
	if err := gossipTrust(ctx, trustA, trustPeer{trust: trustB}); err != nil {
		t.Fatal(err)
	}
	if trustB.Status().GetHeadHash() != trustA.Status().GetHeadHash() {
		t.Fatal("the lagging peer did not adopt the revocation")
	}
	// B, behind again, pulls from A when the gateway withholds the entry.
	_, otherKey, _ := ed25519.GenerateKey(rand.Reader)
	other, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "android", "Tablet", "", otherKey.Public())
	if err != nil {
		t.Fatal(err)
	}
	add, err := revoked.Add(other, signerA)
	if err != nil {
		t.Fatal(err)
	}
	if err := trustA.Offer([]*roster.Entry{add}); err != nil {
		t.Fatal(err)
	}
	if err := gossipTrust(ctx, trustB, trustPeer{trust: trustA}); err != nil {
		t.Fatal(err)
	}
	if trustB.Status().GetHeadHash() != trustA.Status().GetHeadHash() {
		t.Fatalf("pull: head %d, want %d", trustB.Status().GetHeadSequence(), trustA.Status().GetHeadSequence())
	}
	// A third daemon was shown a fork at the same sequence: a conflict.
	_, forkKey, _ := ed25519.GenerateKey(rand.Reader)
	fork, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "ios", "Fork", "", forkKey.Public())
	if err != nil {
		t.Fatal(err)
	}
	forked, err := revoked.Add(fork, signerA)
	if err != nil {
		t.Fatal(err)
	}
	forkedState, err := revoked.Extend([]*roster.Entry{forked})
	if err != nil {
		t.Fatal(err)
	}
	testkit.WriteRoster(t, c.Root, forkedState)
	trustC := openGossipTrust(t, c)
	if err := gossipTrust(ctx, trustC, trustPeer{trust: trustA}); !errors.Is(err, roster.ErrConflict) {
		t.Fatalf("fork: %v", err)
	}
	if trustC.State() != dieterv1.TrustState_TRUST_STATE_CONFLICT {
		t.Fatalf("fork state %v", trustC.State())
	}
}
