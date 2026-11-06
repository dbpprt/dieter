package link

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"fmt"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/testkit"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

// fakeGateway stores an account's roster and pairing requests like the
// gateway: it checks only the compare-and-swap, never a signature. Tests
// tamper with it to play a malicious gateway.
type fakeGateway struct {
	gatewayv1.UnimplementedGatewayServiceServer
	mu       sync.Mutex
	entries  []*roster.Entry
	requests []*gatewayv1.PairingRequest
	watchers []chan struct{}
	// serve rewrites the roster the gateway serves, when set.
	serve func([]*roster.Entry) []*roster.Entry
	// beforeAppend runs before an append is applied; returning an error fails it.
	beforeAppend func(*gatewayv1.AppendDeviceRosterRequest) error
	conn         *grpc.ClientConn
}

func newFakeGateway(t *testing.T) *fakeGateway {
	t.Helper()
	gateway := &fakeGateway{}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	gatewayv1.RegisterGatewayServiceServer(server, gateway)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	gateway.conn, err = grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = gateway.conn.Close() })
	return gateway
}

func (g *fakeGateway) served() []*roster.Entry {
	entries := append([]*roster.Entry(nil), g.entries...)
	if g.serve != nil {
		entries = g.serve(entries)
	}
	return entries
}

func rosterMessage(entries []*roster.Entry, from uint64) *gatewayv1.DeviceRoster {
	result := &gatewayv1.DeviceRoster{Length: uint64(len(entries))}
	if len(entries) > 0 {
		result.HeadSequence, result.HeadHash = uint64(len(entries)-1), roster.Hash(entries[len(entries)-1])
	}
	if from < uint64(len(entries)) {
		result.Entries = entries[from:]
	}
	return result
}

func (g *fakeGateway) GetAccount(context.Context, *emptypb.Empty) (*gatewayv1.Account, error) {
	return &gatewayv1.Account{GithubId: 42, Login: "owner"}, nil
}

func (g *fakeGateway) GetDeviceRoster(_ context.Context, request *gatewayv1.GetDeviceRosterRequest) (*gatewayv1.DeviceRoster, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return rosterMessage(g.served(), request.GetFromSequence()), nil
}

func (g *fakeGateway) WatchDeviceRoster(request *gatewayv1.GetDeviceRosterRequest, stream grpc.ServerStreamingServer[gatewayv1.DeviceRoster]) error {
	from := request.GetFromSequence()
	changed := make(chan struct{}, 1)
	g.mu.Lock()
	g.watchers = append(g.watchers, changed)
	g.mu.Unlock()
	first := true
	for {
		g.mu.Lock()
		served := g.served()
		g.mu.Unlock()
		if first || uint64(len(served)) > from {
			if err := stream.Send(rosterMessage(served, from)); err != nil {
				return err
			}
			first = false
			if uint64(len(served)) > from {
				from = uint64(len(served))
			}
		}
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case <-changed:
		}
	}
}

func (g *fakeGateway) notify() {
	for _, watcher := range g.watchers {
		select {
		case watcher <- struct{}{}:
		default:
		}
	}
}

func (g *fakeGateway) AppendDeviceRoster(_ context.Context, request *gatewayv1.AppendDeviceRosterRequest) (*gatewayv1.DeviceRoster, error) {
	if g.beforeAppend != nil {
		if err := g.beforeAppend(request); err != nil {
			return nil, err
		}
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	entry := request.GetEntry()
	switch {
	case request.GetReplace():
		if entry.GetOperation() != gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_GENESIS {
			return nil, status.Error(codes.InvalidArgument, "replace needs a genesis entry")
		}
		g.entries = []*roster.Entry{entry}
	case entry.GetSequence() != uint64(len(g.entries)):
		return nil, status.Error(codes.Aborted, "roster head moved")
	case len(g.entries) > 0 && !bytes.Equal(entry.GetPrevious(), roster.Hash(g.entries[len(g.entries)-1])):
		return nil, status.Error(codes.Aborted, "roster head moved")
	default:
		g.entries = append(g.entries, entry)
	}
	g.notify()
	return rosterMessage(g.entries, 0), nil
}

func (g *fakeGateway) PostPairingRequest(_ context.Context, request *gatewayv1.PostPairingRequestRequest) (*gatewayv1.PairingRequest, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := time.Now().UTC()
	for _, existing := range g.requests {
		if existing.GetDevice().GetDeviceId() == request.GetDevice().GetDeviceId() {
			existing.Device, existing.Proof, existing.ExpiresAt = request.GetDevice(), request.GetProof(), now.Add(15*time.Minute).Format(time.RFC3339)
			return proto.Clone(existing).(*gatewayv1.PairingRequest), nil
		}
	}
	value := &gatewayv1.PairingRequest{
		Id: fmt.Sprintf("pr_%d", len(g.requests)+1), Device: request.GetDevice(), Proof: request.GetProof(),
		RequestedAt: now.Format(time.RFC3339), ExpiresAt: now.Add(15 * time.Minute).Format(time.RFC3339),
	}
	g.requests = append(g.requests, value)
	return proto.Clone(value).(*gatewayv1.PairingRequest), nil
}

func (g *fakeGateway) ListPairingRequests(context.Context, *emptypb.Empty) (*gatewayv1.ListPairingRequestsResponse, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	result := &gatewayv1.ListPairingRequestsResponse{}
	for _, request := range g.requests {
		result.Requests = append(result.Requests, proto.Clone(request).(*gatewayv1.PairingRequest))
	}
	return result, nil
}

func (g *fakeGateway) ConfirmPairingRequest(_ context.Context, request *gatewayv1.ConfirmPairingRequestRequest) (*gatewayv1.PairingRequest, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, existing := range g.requests {
		if existing.GetId() == request.GetId() {
			existing.Confirmation = request.GetConfirmation()
			return proto.Clone(existing).(*gatewayv1.PairingRequest), nil
		}
	}
	return nil, status.Error(codes.NotFound, "pairing request not found")
}

func (g *fakeGateway) DeletePairingRequest(_ context.Context, request *gatewayv1.PairingRequestRef) (*emptypb.Empty, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	for index, existing := range g.requests {
		if existing.GetId() == request.GetId() {
			g.requests = append(g.requests[:index], g.requests[index+1:]...)
			break
		}
	}
	return &emptypb.Empty{}, nil
}

func (g *fakeGateway) setConfirmation(id string, confirmation []byte) {
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, existing := range g.requests {
		if existing.GetId() == id {
			existing.Confirmation = confirmation
		}
	}
}

// testIdentity is an enrolled daemon identity whose tokens signingKey signs.
func testIdentity(t *testing.T, id, name string) (*Identity, ed25519.PrivateKey) {
	t.Helper()
	signingKey, signing := testkit.SigningKey(t)
	identity, err := LoadOrCreateEnrollmentIdentity(t.TempDir(), name, "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	if err := identity.SaveCredential(id, name, []byte("enrollment"), signing, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}
	return identity, signingKey
}

// testTrust opens the device trust of a fresh daemon that reaches gateway.
func testTrust(t *testing.T, gateway *fakeGateway, id, name string) (*Trust, *Identity) {
	t.Helper()
	identity, _ := testIdentity(t, id, name)
	deviceTrust, err := OpenTrust(identity, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	deviceTrust.Gateway = func(context.Context) (grpc.ClientConnInterface, error) { return gateway.conn, nil }
	deviceTrust.PairingPoll = 20 * time.Millisecond
	return deviceTrust, identity
}

func waitTrust(t *testing.T, deviceTrust *Trust, condition func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(testkit.Budget(10 * time.Second))
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s; status %v", what, deviceTrust.Status())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func testLogger() *slog.Logger { return slog.New(slog.DiscardHandler) }
