package gateway

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"sync"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/security/linkauth"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/security/trust"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

func principalContext(t *testing.T, githubID int64) context.Context {
	return context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: githubID})
}

func testDaemonDevice(t *testing.T, daemonID string) roster.Signer {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	descriptor, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_DAEMON, "linux", "Test machine", daemonID, public)
	if err != nil {
		t.Fatal(err)
	}
	return roster.Ed25519Signer(private, descriptor)
}

func testClientDevice(t *testing.T, name string) roster.Signer {
	t.Helper()
	private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	descriptor, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "jvm", name, "", &private.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return roster.ECDSASigner(private, descriptor)
}

func (f *tunnelFixture) account(githubID int64) string {
	return roster.Account(f.server.Config.IdentityOrigin(), githubID)
}

// startRoster appends a genesis entry for githubID and returns its state.
func (f *tunnelFixture) startRoster(t *testing.T, githubID int64, signer roster.Signer) *roster.State {
	t.Helper()
	genesis, err := roster.Genesis(f.account(githubID), signer)
	if err != nil {
		t.Fatal(err)
	}
	response, err := f.server.Service.AppendDeviceRoster(principalContext(t, githubID), &gatewayv1.AppendDeviceRosterRequest{Entry: genesis})
	if err != nil {
		t.Fatal(err)
	}
	state, err := roster.Verify(response.GetEntries())
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func TestRosterAppendIsCompareAndSwapOnTheVerifiedHead(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	ctx := principalContext(t, tunnelOwner)
	empty, err := f.server.Service.GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{})
	if err != nil || empty.GetLength() != 0 || len(empty.GetEntries()) != 0 {
		t.Fatalf("roster before genesis = %v, %v", empty, err)
	}
	machine := testDaemonDevice(t, "d_machine")
	phone := testClientDevice(t, "Phone")
	tablet := testClientDevice(t, "Tablet")

	// An empty roster accepts only a genesis entry.
	premature, err := roster.Genesis(f.account(tunnelOwner), machine)
	if err != nil {
		t.Fatal(err)
	}
	premature.Operation, premature.Sequence = gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_ADD, 1
	if _, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: premature}); status.Code(err) != codes.Aborted {
		t.Fatalf("entry after a missing head = %v", err)
	}
	premature.Sequence = 0
	if _, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: premature}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("non-genesis first entry = %v", err)
	}

	state := f.startRoster(t, tunnelOwner, machine)
	stale := state
	add, err := state.Add(phone.Descriptor(), machine)
	if err != nil {
		t.Fatal(err)
	}
	response, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: add})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetLength() != 2 || response.GetHeadSequence() != 1 || !bytes.Equal(response.GetHeadHash(), roster.Hash(add)) {
		t.Fatalf("append response = %v", response)
	}
	// A concurrent approver built its entry on the old head.
	conflicting, err := stale.Add(tablet.Descriptor(), machine)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: conflicting}); status.Code(err) != codes.Aborted {
		t.Fatalf("entry on a stale head = %v", err)
	}
	state, err = state.Extend([]*roster.Entry{add})
	if err != nil {
		t.Fatal(err)
	}
	wrongPrevious, err := state.Add(tablet.Descriptor(), machine)
	if err != nil {
		t.Fatal(err)
	}
	wrongPrevious.Previous = roster.Hash(conflicting)
	if _, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: wrongPrevious}); status.Code(err) != codes.Aborted {
		t.Fatalf("entry naming another previous hash = %v", err)
	}

	// Entries that extend the head but that no member signed are refused.
	forged, err := state.Add(tablet.Descriptor(), machine)
	if err != nil {
		t.Fatal(err)
	}
	forged.Signature = bytes.Clone(forged.GetSignature())
	forged.Signature[len(forged.Signature)-1] ^= 1
	outsider := testClientDevice(t, "Outsider")
	unsigned := proto.Clone(forged).(*gatewayv1.DeviceRosterEntry)
	unsigned.Signer = outsider.Descriptor().GetDeviceId()
	if unsigned.Signature, err = outsider.Sign(roster.Canonical(unsigned)); err != nil {
		t.Fatal(err)
	}
	for name, entry := range map[string]*gatewayv1.DeviceRosterEntry{"invalid signature": forged, "non-member signer": unsigned} {
		if _, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: entry}); status.Code(err) != codes.InvalidArgument {
			t.Fatalf("%s = %v", name, err)
		}
	}

	from, err := f.server.Service.GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{FromSequence: 1})
	if err != nil || len(from.GetEntries()) != 1 || !proto.Equal(from.GetEntries()[0], add) || from.GetLength() != 2 {
		t.Fatalf("roster from sequence 1 = %v, %v", from, err)
	}
	// A restarted gateway verifies the stored chain and serves the same head.
	reloaded := NewService(f.server.Store, f.server.Auth, f.server.Keys, f.server.Hub, f.server.Config)
	again, err := reloaded.GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{})
	if err != nil || again.GetLength() != 2 || !bytes.Equal(again.GetHeadHash(), state.HeadHash()) {
		t.Fatalf("reloaded roster = %v, %v", again, err)
	}
}

func TestRosterConcurrentApproversAppendExactlyOnce(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	machine := testDaemonDevice(t, "d_machine")
	state := f.startRoster(t, tunnelOwner, machine)
	var appended, aborted int
	var mu sync.Mutex
	var wait sync.WaitGroup
	for i := range 8 {
		entry, err := state.Add(testClientDevice(t, "Device "+string(rune('A'+i))).Descriptor(), machine)
		if err != nil {
			t.Fatal(err)
		}
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, err := f.server.Service.AppendDeviceRoster(principalContext(t, tunnelOwner), &gatewayv1.AppendDeviceRosterRequest{Entry: entry})
			mu.Lock()
			defer mu.Unlock()
			switch status.Code(err) {
			case codes.OK:
				appended++
			case codes.Aborted:
				aborted++
			default:
				t.Errorf("concurrent append = %v", err)
			}
		}()
	}
	wait.Wait()
	if appended != 1 || aborted != 7 {
		t.Fatalf("appended=%d aborted=%d; want exactly one append", appended, aborted)
	}
}

func TestRosterReplaceAcceptsOnlyAGenesisEntry(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	ctx := principalContext(t, tunnelOwner)
	machine := testDaemonDevice(t, "d_machine")
	state := f.startRoster(t, tunnelOwner, machine)
	add, err := state.Add(testClientDevice(t, "Phone").Descriptor(), machine)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: add, Replace: true}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("replace with an ADD entry = %v", err)
	}
	replacement := testDaemonDevice(t, "d_replacement")
	genesis, err := roster.Genesis(f.account(tunnelOwner), replacement)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: genesis}); status.Code(err) != codes.Aborted {
		t.Fatalf("second genesis without replace = %v", err)
	}
	unsigned := proto.Clone(genesis).(*gatewayv1.DeviceRosterEntry)
	unsigned.Signature = nil
	if _, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: unsigned, Replace: true}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("replace with an unsigned genesis = %v", err)
	}
	response, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: genesis, Replace: true})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetLength() != 1 || !bytes.Equal(response.GetHeadHash(), roster.Hash(genesis)) || bytes.Equal(response.GetHeadHash(), state.Root()) {
		t.Fatalf("replaced roster = %v", response)
	}
}

func TestRosterIsBoundToTheCallersAccount(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	machine := testDaemonDevice(t, "d_machine")
	for name, account := range map[string]string{
		"another account": f.account(tunnelStranger),
		"another gateway": roster.Account("https://other-gateway.test", tunnelOwner),
	} {
		genesis, err := roster.Genesis(account, machine)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.server.Service.AppendDeviceRoster(principalContext(t, tunnelOwner), &gatewayv1.AppendDeviceRosterRequest{Entry: genesis}); status.Code(err) != codes.PermissionDenied {
			t.Fatalf("%s genesis = %v", name, err)
		}
	}
	f.startRoster(t, tunnelOwner, machine)
	stranger, err := f.server.Service.GetDeviceRoster(principalContext(t, tunnelStranger), &gatewayv1.GetDeviceRosterRequest{})
	if err != nil || stranger.GetLength() != 0 {
		t.Fatalf("another account sees the roster: %v, %v", stranger, err)
	}
}

func TestRosterRPCsRequireAuthenticationAndWatchDeliversAppends(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	client := gatewayv1.NewGatewayServiceClient(f.connection)
	anonymous := metadata.AppendToOutgoingContext(t.Context(), "x-dieter-client-version", buildinfo.ReleaseVersion)
	if _, err := client.GetDeviceRoster(anonymous, &gatewayv1.GetDeviceRosterRequest{}); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("anonymous roster read = %v", err)
	}
	watchCtx, cancel := context.WithCancel(t.Context())
	defer cancel()
	watchCtx = metadata.AppendToOutgoingContext(watchCtx, "authorization", "Bearer "+f.session(t, tunnelOwner), "x-dieter-client-version", buildinfo.ReleaseVersion)
	watch, err := client.WatchDeviceRoster(watchCtx, &gatewayv1.GetDeviceRosterRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if first, err := watch.Recv(); err != nil || first.GetLength() != 0 {
		t.Fatalf("first watch message = %v, %v", first, err)
	}
	// A daemon starts the roster with its possession proof.
	daemon := f.enroll(t, tunnelOwner)
	descriptor, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_DAEMON, "linux", "Test machine", daemon.id, daemon.private.Public())
	if err != nil {
		t.Fatal(err)
	}
	signer := roster.Ed25519Signer(daemon.private, descriptor)
	genesis, err := roster.Genesis(f.account(tunnelOwner), signer)
	if err != nil {
		t.Fatal(err)
	}
	proof := linkauth.SignPeer(daemon.private, daemon.id, f.server.Config.IdentityOrigin(), daemon.generation, time.Now())
	daemonCtx := metadata.AppendToOutgoingContext(t.Context(), "authorization", "Bearer "+proof, "x-dieter-client-version", buildinfo.ReleaseVersion)
	if _, err := client.AppendDeviceRoster(daemonCtx, &gatewayv1.AppendDeviceRosterRequest{Entry: genesis}); err != nil {
		t.Fatal(err)
	}
	if update, err := watch.Recv(); err != nil || len(update.GetEntries()) != 1 || !proto.Equal(update.GetEntries()[0], genesis) {
		t.Fatalf("watch after genesis = %v, %v", update, err)
	}
	state, err := roster.Verify([]*roster.Entry{genesis})
	if err != nil {
		t.Fatal(err)
	}
	add, err := state.Add(testClientDevice(t, "Phone").Descriptor(), signer)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.AppendDeviceRoster(daemonCtx, &gatewayv1.AppendDeviceRosterRequest{Entry: add}); err != nil {
		t.Fatal(err)
	}
	if update, err := watch.Recv(); err != nil || len(update.GetEntries()) != 1 || !proto.Equal(update.GetEntries()[0], add) || update.GetLength() != 2 {
		t.Fatalf("watch after add = %v, %v", update, err)
	}
	// A replaced roster is sent again from its genesis.
	replacement, err := roster.Genesis(f.account(tunnelOwner), testDaemonDevice(t, "d_other"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.AppendDeviceRoster(daemonCtx, &gatewayv1.AppendDeviceRosterRequest{Entry: replacement, Replace: true}); err != nil {
		t.Fatal(err)
	}
	if update, err := watch.Recv(); err != nil || len(update.GetEntries()) != 1 || !proto.Equal(update.GetEntries()[0], replacement) || update.GetLength() != 1 {
		t.Fatalf("watch after replace = %v, %v", update, err)
	}
}

func TestPairingFlowThroughTheGatewayMailbox(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	approver := testDaemonDevice(t, "d_machine")
	state := f.startRoster(t, tunnelOwner, approver)
	ctx := principalContext(t, tunnelOwner)

	// The new device posts its descriptor with a proof keyed by its code.
	phone := testClientDevice(t, "Phone")
	secret, code, err := roster.NewPairingSecret()
	if err != nil {
		t.Fatal(err)
	}
	posted, err := f.server.Service.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: phone.Descriptor(), Proof: roster.PairingProof(secret, phone.Descriptor())})
	if err != nil {
		t.Fatal(err)
	}
	// The approver finds the request whose proof verifies with the typed code.
	typed, err := roster.ParsePairingCode(code)
	if err != nil {
		t.Fatal(err)
	}
	listed, err := f.server.Service.ListPairingRequests(ctx, &emptypb.Empty{})
	if err != nil || len(listed.GetRequests()) != 1 {
		t.Fatalf("pairing requests = %v, %v", listed, err)
	}
	request := listed.GetRequests()[0]
	if request.GetId() != posted.GetId() || !roster.VerifyPairingProof(typed, request.GetDevice(), request.GetProof()) {
		t.Fatal("the approver cannot identify the request by its code")
	}
	add, err := state.Add(request.GetDevice(), approver)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.server.Service.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: add}); err != nil {
		t.Fatal(err)
	}
	confirmation := roster.PairingConfirmation(typed, state.Root(), roster.Hash(add))
	if _, err := f.server.Service.ConfirmPairingRequest(ctx, &gatewayv1.ConfirmPairingRequestRequest{Id: request.GetId(), Confirmation: confirmation}); err != nil {
		t.Fatal(err)
	}
	// The new device reads the confirmation and verifies it against the roster.
	listed, err = f.server.Service.ListPairingRequests(ctx, &emptypb.Empty{})
	if err != nil || len(listed.GetRequests()) != 1 {
		t.Fatalf("pairing requests after confirmation = %v, %v", listed, err)
	}
	served, err := f.server.Service.GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{})
	if err != nil {
		t.Fatal(err)
	}
	pinned, err := roster.Verify(served.GetEntries())
	if err != nil {
		t.Fatal(err)
	}
	if !roster.VerifyPairingConfirmation(secret, pinned.Root(), roster.Hash(served.GetEntries()[1]), listed.GetRequests()[0].GetConfirmation()) {
		t.Fatal("the new device cannot verify the approver's confirmation")
	}
	if _, err := f.server.Service.DeletePairingRequest(ctx, &gatewayv1.PairingRequestRef{Id: request.GetId()}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.server.Service.DeletePairingRequest(ctx, &gatewayv1.PairingRequestRef{Id: request.GetId()}); status.Code(err) != codes.NotFound {
		t.Fatalf("second delete = %v", err)
	}
}

func TestPairingRequestsAreIdempotentPerDeviceAndConfirmedOnce(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	ctx := principalContext(t, tunnelOwner)
	device := testClientDevice(t, "Phone").Descriptor()
	proof := bytes.Repeat([]byte{1}, 32)
	first, err := f.server.Service.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: device, Proof: proof})
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * time.Millisecond)
	again, err := f.server.Service.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: device, Proof: proof})
	if err != nil || again.GetId() != first.GetId() || again.GetRequestedAt() != first.GetRequestedAt() || again.GetExpiresAt() <= first.GetExpiresAt() {
		t.Fatalf("re-posted request = %v, %v; want the same request with a later expiry than %v", again, err, first)
	}
	confirmation := bytes.Repeat([]byte{2}, 32)
	if _, err := f.server.Service.ConfirmPairingRequest(ctx, &gatewayv1.ConfirmPairingRequestRequest{Id: first.GetId(), Confirmation: confirmation}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.server.Service.ConfirmPairingRequest(ctx, &gatewayv1.ConfirmPairingRequestRequest{Id: first.GetId(), Confirmation: confirmation}); err != nil {
		t.Fatalf("repeated confirmation = %v", err)
	}
	if _, err := f.server.Service.ConfirmPairingRequest(ctx, &gatewayv1.ConfirmPairingRequestRequest{Id: first.GetId(), Confirmation: bytes.Repeat([]byte{3}, 32)}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("different second confirmation = %v", err)
	}
	// Re-posting the same proof keeps the confirmation; a new proof is a new
	// code and drops it.
	kept, err := f.server.Service.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: device, Proof: proof})
	if err != nil || !bytes.Equal(kept.GetConfirmation(), confirmation) {
		t.Fatalf("re-post dropped the confirmation: %v, %v", kept, err)
	}
	renewed, err := f.server.Service.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: device, Proof: bytes.Repeat([]byte{4}, 32)})
	if err != nil || renewed.GetId() != first.GetId() || len(renewed.GetConfirmation()) != 0 {
		t.Fatalf("new proof kept a stale confirmation: %v, %v", renewed, err)
	}
}

func TestPairingRequestsAreValidatedBoundedAndExpire(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	ctx := principalContext(t, tunnelOwner)
	proof := bytes.Repeat([]byte{1}, 32)
	device := testClientDevice(t, "Phone").Descriptor()
	recovery := proto.Clone(device).(*gatewayv1.DeviceDescriptor)
	recovery.Kind = gatewayv1.DeviceKind_DEVICE_KIND_RECOVERY
	mismatched := proto.Clone(device).(*gatewayv1.DeviceDescriptor)
	mismatched.DeviceId = testClientDevice(t, "Other").Descriptor().GetDeviceId()
	unnamed := proto.Clone(device).(*gatewayv1.DeviceDescriptor)
	unnamed.Platform = ""
	for name, request := range map[string]*gatewayv1.PostPairingRequestRequest{
		"missing device":  {Proof: proof},
		"recovery key":    {Device: recovery, Proof: proof},
		"foreign key ID":  {Device: mismatched, Proof: proof},
		"short proof":     {Device: device, Proof: proof[:31]},
		"oversized proof": {Device: device, Proof: append(bytes.Clone(proof), 0)},
		"missing proof":   {Device: device},
		"blank device ID": {Device: &gatewayv1.DeviceDescriptor{Kind: gatewayv1.DeviceKind_DEVICE_KIND_CLIENT}, Proof: proof},
		"no platform":     {Device: unnamed, Proof: proof},
	} {
		if _, err := f.server.Service.PostPairingRequest(ctx, request); status.Code(err) != codes.InvalidArgument {
			t.Fatalf("%s = %v", name, err)
		}
	}
	var ids []string
	for i := range maxPairingRequests {
		request, err := f.server.Service.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: testClientDevice(t, "Device").Descriptor(), Proof: proof})
		if err != nil {
			t.Fatalf("request %d = %v", i, err)
		}
		ids = append(ids, request.GetId())
	}
	if _, err := f.server.Service.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: device, Proof: proof}); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("request above the account limit = %v", err)
	}
	if _, err := f.server.Service.PostPairingRequest(principalContext(t, tunnelStranger), &gatewayv1.PostPairingRequestRequest{Device: device, Proof: proof}); err != nil {
		t.Fatalf("one account's requests blocked another: %v", err)
	}
	if _, err := f.server.Service.ConfirmPairingRequest(ctx, &gatewayv1.ConfirmPairingRequestRequest{Id: ids[0], Confirmation: proof[:16]}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("short confirmation = %v", err)
	}
	// Expired requests are invisible and free their slots.
	if _, err := f.server.Store.DB.Exec(`UPDATE pairing_requests SET expires_at=? WHERE id=?`, time.Now().Add(-time.Second).UnixNano(), ids[0]); err != nil {
		t.Fatal(err)
	}
	listed, err := f.server.Service.ListPairingRequests(ctx, &emptypb.Empty{})
	if err != nil || len(listed.GetRequests()) != maxPairingRequests-1 {
		t.Fatalf("listed %d requests, %v; want the expired one hidden", len(listed.GetRequests()), err)
	}
	for _, request := range listed.GetRequests() {
		if request.GetId() == ids[0] {
			t.Fatal("expired request is listed")
		}
	}
	if _, err := f.server.Service.ConfirmPairingRequest(ctx, &gatewayv1.ConfirmPairingRequestRequest{Id: ids[0], Confirmation: proof}); status.Code(err) != codes.NotFound {
		t.Fatalf("confirming an expired request = %v", err)
	}
	if _, err := f.server.Service.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: device, Proof: proof}); err != nil {
		t.Fatalf("expired request kept its slot: %v", err)
	}
	var stored int
	if err := f.server.Store.DB.QueryRow(`SELECT COUNT(*) FROM pairing_requests WHERE id=?`, ids[0]).Scan(&stored); err != nil || stored != 0 {
		t.Fatalf("expired request was not pruned: %d, %v", stored, err)
	}
}

func TestPairingRequestsAreAccountScoped(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	owner, stranger := principalContext(t, tunnelOwner), principalContext(t, tunnelStranger)
	request, err := f.server.Service.PostPairingRequest(owner, &gatewayv1.PostPairingRequestRequest{Device: testClientDevice(t, "Phone").Descriptor(), Proof: bytes.Repeat([]byte{1}, 32)})
	if err != nil {
		t.Fatal(err)
	}
	listed, err := f.server.Service.ListPairingRequests(stranger, &emptypb.Empty{})
	if err != nil || len(listed.GetRequests()) != 0 {
		t.Fatalf("another account lists the request: %v, %v", listed, err)
	}
	if _, err := f.server.Service.ConfirmPairingRequest(stranger, &gatewayv1.ConfirmPairingRequestRequest{Id: request.GetId(), Confirmation: bytes.Repeat([]byte{2}, 32)}); status.Code(err) != codes.NotFound {
		t.Fatalf("another account confirmed the request: %v", err)
	}
	if _, err := f.server.Service.DeletePairingRequest(stranger, &gatewayv1.PairingRequestRef{Id: request.GetId()}); status.Code(err) != codes.NotFound {
		t.Fatalf("another account deleted the request: %v", err)
	}
	if listed, err := f.server.Service.ListPairingRequests(owner, &emptypb.Empty{}); err != nil || len(listed.GetRequests()) != 1 || len(listed.GetRequests()[0].GetConfirmation()) != 0 {
		t.Fatalf("owner's request changed: %v, %v", listed, err)
	}
	client := gatewayv1.NewGatewayServiceClient(f.connection)
	anonymous := metadata.AppendToOutgoingContext(t.Context(), "x-dieter-client-version", buildinfo.ReleaseVersion)
	if _, err := client.ListPairingRequests(anonymous, &emptypb.Empty{}); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("anonymous pairing list = %v", err)
	}
}

func TestDaemonTokensAreBoundToARosterDevice(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	ctx := principalContext(t, tunnelOwner)
	device := testClientDevice(t, "Phone").Descriptor().GetDeviceId()
	for _, thumbprint := range []string{"", "sha256:abc", device + "x", "DV_" + device[3:]} {
		if _, err := f.server.Service.ExchangeDaemonToken(ctx, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: daemon.id, ClientKeyThumbprint: thumbprint}); status.Code(err) != codes.InvalidArgument {
			t.Fatalf("token for thumbprint %q = %v", thumbprint, err)
		}
	}
	token, err := f.server.Service.ExchangeDaemonToken(ctx, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: daemon.id, ClientKeyThumbprint: device})
	if err != nil {
		t.Fatal(err)
	}
	claims, err := trust.ParseAndVerifyDaemonToken(f.server.Keys.SigningPublic, token.GetAccessToken(), f.server.Config.IdentityOrigin(), daemon.id, daemon.generation, time.Now())
	if err != nil || claims.ClientThumbprint != device {
		t.Fatalf("token claims = %+v, %v", claims, err)
	}
	if _, err := f.server.Service.ExchangeDaemonToken(principalContext(t, tunnelStranger), &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: daemon.id, ClientKeyThumbprint: device}); status.Code(err) != codes.NotFound {
		t.Fatalf("another account's token = %v", err)
	}
}
