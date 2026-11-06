package link

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"strings"
	"testing"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/security/roster"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func runTrust(t *testing.T, deviceTrust *Trust) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		deviceTrust.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
}

func faultKind(err error) fault.Kind {
	kind, _ := fault.KindOf(err)
	return kind
}

func publicKey(t *testing.T, identity *Identity) []byte {
	t.Helper()
	der, err := identity.PublicKeyDER()
	if err != nil {
		t.Fatal(err)
	}
	return der
}

// pendingCode starts deviceTrust and returns the code it waits with.
func pendingCode(t *testing.T, deviceTrust *Trust) string {
	t.Helper()
	runTrust(t, deviceTrust)
	waitTrust(t, deviceTrust, func() bool {
		_, meta := deviceTrust.snapshot()
		return deviceTrust.State() == dieterv1.TrustState_TRUST_STATE_PENDING && meta.RequestID != ""
	}, "a posted pairing request")
	code := deviceTrust.Status().GetPairingCode()
	if _, err := roster.ParsePairingCode(code); err != nil {
		t.Fatalf("pairing code %q: %v", code, err)
	}
	return code
}

func TestTrustStartsPairsRevokesAndRecovers(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	gateway := newFakeGateway(t)
	first, firstIdentity := testTrust(t, gateway, "d_first", "First")
	if state := first.State(); state != dieterv1.TrustState_TRUST_STATE_UNSPECIFIED {
		t.Fatalf("state before the gateway answered = %v", state)
	}
	if err := first.runOnce(ctx); err != nil || first.State() != dieterv1.TrustState_TRUST_STATE_NO_ROSTER {
		t.Fatalf("empty account: state=%v err=%v", first.State(), err)
	}
	if _, err := first.Connecting(publicKey(t, firstIdentity)); err == nil {
		t.Fatal("a machine without a roster accepted a connection")
	}
	status, recoveryKey, err := first.Initialize(ctx, false)
	if err != nil {
		t.Fatal(err)
	}
	if status.GetState() != dieterv1.TrustState_TRUST_STATE_TRUSTED || status.GetHeadSequence() != 1 || !strings.HasPrefix(recoveryKey, "DRK1-") {
		t.Fatalf("initialized status=%v recovery=%q", status, recoveryKey)
	}
	if _, _, err := first.Initialize(ctx, false); faultKind(err) != fault.FailedPrecondition {
		t.Fatalf("second initialization: %v", err)
	}
	reopened, err := OpenTrust(firstIdentity, nil)
	if err != nil || reopened.State() != dieterv1.TrustState_TRUST_STATE_TRUSTED || reopened.Status().GetRootHash() != status.GetRootHash() {
		t.Fatalf("pinned roster did not persist: %v %v", reopened.Status(), err)
	}
	runTrust(t, first)

	second, secondIdentity := testTrust(t, gateway, "d_second", "Second")
	code := pendingCode(t, second)
	if _, err := first.Approve(ctx, "0000-0000-0000-0000"); faultKind(err) != fault.NotFound || !strings.Contains(err.Error(), "No device is waiting with this code") {
		t.Fatalf("wrong code: %v", err)
	}
	if _, err := first.Approve(ctx, "not a code"); faultKind(err) != fault.Invalid {
		t.Fatalf("malformed code: %v", err)
	}
	if requests, err := first.ListRequests(ctx); err != nil || len(requests) != 1 || requests[0].GetName() != "Second" {
		t.Fatalf("pending requests=%v err=%v", requests, err)
	}
	if _, err := second.ListRequests(ctx); err == nil {
		t.Fatal("a pending machine listed pairing requests")
	}
	if _, err := first.Approve(ctx, strings.ToLower(strings.ReplaceAll(code, "-", " "))); err != nil {
		t.Fatal(err)
	}
	waitTrust(t, second, func() bool { return second.State() == dieterv1.TrustState_TRUST_STATE_TRUSTED }, "the approved machine")
	if second.Status().GetRootHash() != status.GetRootHash() {
		t.Fatal("the approved machine pinned another roster")
	}
	if _, err := first.Connecting(publicKey(t, secondIdentity)); err != nil {
		t.Fatalf("first refuses the approved machine: %v", err)
	}
	if _, err := second.Connecting(publicKey(t, firstIdentity)); err != nil {
		t.Fatalf("second refuses the first machine: %v", err)
	}
	if key, err := second.DaemonKey("d_first"); err != nil || !bytes.Equal(key, publicKey(t, firstIdentity)) {
		t.Fatalf("daemon key of first = %x, %v", key, err)
	}
	if requests, err := first.ListRequests(ctx); err != nil || len(requests) != 0 {
		t.Fatalf("completed pairing request remains: %v %v", requests, err)
	}

	if _, err := first.Revoke(ctx, secondIdentity.DeviceID()); err != nil {
		t.Fatal(err)
	}
	if _, err := first.Connecting(publicKey(t, secondIdentity)); err == nil {
		t.Fatal("a revoked machine may still connect")
	}
	waitTrust(t, second, func() bool { return second.State() == dieterv1.TrustState_TRUST_STATE_REVOKED }, "the revocation to reach the revoked machine")
	if _, err := second.Connecting(publicKey(t, firstIdentity)); err == nil {
		t.Fatal("a revoked machine still accepts connections")
	}

	third, thirdIdentity := testTrust(t, gateway, "d_third", "Third")
	pendingCode(t, third)
	foreignKey, _, err := roster.NewRecoveryKey(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := third.Recover(ctx, foreignKey); faultKind(err) != fault.PermissionDenied {
		t.Fatalf("recovery key of another roster: %v", err)
	}
	if _, err := third.Recover(ctx, recoveryKey); err != nil {
		t.Fatal(err)
	}
	if third.State() != dieterv1.TrustState_TRUST_STATE_TRUSTED {
		t.Fatalf("recovered state %v", third.State())
	}
	waitTrust(t, first, func() bool { _, err := first.Connecting(publicKey(t, thirdIdentity)); return err == nil }, "the recovered machine")
}

func TestPendingMachinePinsOnlyAConfirmedRoster(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	gateway := newFakeGateway(t)
	first, _ := testTrust(t, gateway, "d_first", "First")
	if _, _, err := first.Initialize(ctx, false); err != nil {
		t.Fatal(err)
	}
	pending, pendingIdentity := testTrust(t, gateway, "d_pending", "Pending")
	code := pendingCode(t, pending)
	requests, err := gateway.ListPairingRequests(ctx, nil)
	if err != nil || len(requests.GetRequests()) != 1 {
		t.Fatal(requests, err)
	}
	request := requests.GetRequests()[0]
	secret, err := roster.ParsePairingCode(code)
	if err != nil {
		t.Fatal(err)
	}
	if !roster.VerifyPairingProof(secret, request.GetDevice(), request.GetProof()) || !proto.Equal(request.GetDevice(), pending.self) {
		t.Fatal("the posted request does not prove the pending machine's key")
	}

	// A trusted member adds the machine without confirming the pairing: a
	// roster that merely contains it is never enough.
	if _, _, err := first.appendEntry(ctx, func(state *roster.State) (*roster.Entry, error) { return state.Add(request.GetDevice(), first.signer) }); err != nil {
		t.Fatal(err)
	}
	// The gateway forges confirmations; it does not know the secret.
	gateway.setConfirmation(request.GetId(), bytes.Repeat([]byte{1}, 32))
	if done, err := pending.pairStep(ctx, gatewayv1.NewGatewayServiceClient(gateway.conn)); done || err != nil || pending.State() != dieterv1.TrustState_TRUST_STATE_PENDING {
		t.Fatalf("forged confirmation pinned: done=%v err=%v state=%v", done, err, pending.State())
	}
	if !strings.Contains(pending.Status().GetDetail(), "did not verify") {
		t.Fatalf("forged confirmation left no evidence: %q", pending.Status().GetDetail())
	}

	// A confirmation of the real roster does not pin a roster the gateway
	// made up around the same device.
	real := gateway.served()
	realState, err := roster.Verify(real)
	if err != nil {
		t.Fatal(err)
	}
	member := realState.Member(pendingIdentity.DeviceID())
	_, attackerKey, _ := ed25519.GenerateKey(rand.Reader)
	attacker := roster.Ed25519Signer(attackerKey, mustDescribe(t, attackerKey, "d_attacker"))
	genesis, err := roster.Genesis(realState.Account(), attacker)
	if err != nil {
		t.Fatal(err)
	}
	forged, _ := roster.Verify([]*roster.Entry{genesis})
	add, err := forged.Add(request.GetDevice(), attacker)
	if err != nil {
		t.Fatal(err)
	}
	gateway.mu.Lock()
	gateway.serve = func([]*roster.Entry) []*roster.Entry { return []*roster.Entry{genesis, add} }
	gateway.mu.Unlock()
	gateway.setConfirmation(request.GetId(), roster.PairingConfirmation(secret, realState.Root(), realState.HashAt(member.AddedAt)))
	if done, err := pending.pairStep(ctx, gatewayv1.NewGatewayServiceClient(gateway.conn)); done || err != nil || pending.State() != dieterv1.TrustState_TRUST_STATE_PENDING {
		t.Fatalf("confirmation for another root pinned: done=%v err=%v state=%v", done, err, pending.State())
	}
	gateway.mu.Lock()
	gateway.serve = nil
	gateway.mu.Unlock()
	waitTrust(t, pending, func() bool { return pending.State() == dieterv1.TrustState_TRUST_STATE_TRUSTED }, "the confirmed roster")
	if pending.Status().GetRootHash() != roster.EncodeHash(realState.Root()) {
		t.Fatal("pinned the wrong roster")
	}
}

func TestTrustDetectsAConflictingRoster(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	gateway := newFakeGateway(t)
	first, firstIdentity := testTrust(t, gateway, "d_first", "First")
	if _, _, err := first.Initialize(ctx, false); err != nil {
		t.Fatal(err)
	}
	pinned := first.Entries(0).GetEntries()
	// The gateway serves a fork at sequence 1: another recovery key.
	_, other, err := roster.NewRecoveryKey(roster.Hash(pinned[0]))
	if err != nil {
		t.Fatal(err)
	}
	genesisState, err := roster.Verify(pinned[:1])
	if err != nil {
		t.Fatal(err)
	}
	fork, err := genesisState.Add(other.Descriptor(), first.signer)
	if err != nil {
		t.Fatal(err)
	}
	gateway.mu.Lock()
	gateway.serve = func(entries []*roster.Entry) []*roster.Entry { return []*roster.Entry{entries[0], fork} }
	gateway.mu.Unlock()
	if err := first.Refresh(ctx); !errors.Is(err, roster.ErrConflict) {
		t.Fatalf("fork accepted: %v", err)
	}
	if first.State() != dieterv1.TrustState_TRUST_STATE_CONFLICT || !strings.Contains(first.Status().GetDetail(), "sequence 1") {
		t.Fatalf("conflict state=%v detail=%q", first.State(), first.Status().GetDetail())
	}
	if _, err := first.Connecting(publicKey(t, firstIdentity)); err == nil {
		t.Fatal("a conflicted machine accepts connections")
	}
	if _, err := PinnedRoster(firstIdentity.Root); err == nil {
		t.Fatal("the CLI may use a conflicted roster")
	}
	reopened, err := OpenTrust(firstIdentity, nil)
	if err != nil || reopened.State() != dieterv1.TrustState_TRUST_STATE_CONFLICT {
		t.Fatalf("conflict did not persist: %v %v", reopened.State(), err)
	}
	// Replacing the roster on this machine resolves the conflict.
	gateway.mu.Lock()
	gateway.serve = nil
	gateway.mu.Unlock()
	if _, _, err := first.Initialize(ctx, true); err != nil || first.State() != dieterv1.TrustState_TRUST_STATE_TRUSTED {
		t.Fatalf("replace: %v %v", first.State(), err)
	}
}

func TestOfferedEntriesExtendOrConflict(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	gateway := newFakeGateway(t)
	first, _ := testTrust(t, gateway, "d_first", "First")
	if _, _, err := first.Initialize(ctx, false); err != nil {
		t.Fatal(err)
	}
	// A peer offers an entry the gateway withholds.
	_, clientKey, _ := ed25519.GenerateKey(rand.Reader)
	client := mustDescribe(t, clientKey, "")
	state, err := roster.Verify(first.Entries(0).GetEntries())
	if err != nil {
		t.Fatal(err)
	}
	add, err := state.Add(client, first.signer)
	if err != nil {
		t.Fatal(err)
	}
	if err := first.Offer([]*roster.Entry{add}); err != nil {
		t.Fatal(err)
	}
	if first.Status().GetHeadSequence() != 2 {
		t.Fatal("a valid extension was not adopted")
	}
	if err := first.Offer([]*roster.Entry{{Account: state.Account(), Sequence: 3}}); faultKind(err) != fault.Invalid || first.State() != dieterv1.TrustState_TRUST_STATE_TRUSTED {
		t.Fatalf("invalid entry: %v %v", err, first.State())
	}
	_, unknownKey, _ := ed25519.GenerateKey(rand.Reader)
	other := roster.Ed25519Signer(unknownKey, mustDescribe(t, unknownKey, "d_other"))
	genesis, err := roster.Genesis(state.Account(), other)
	if err != nil {
		t.Fatal(err)
	}
	if err := first.Offer([]*roster.Entry{genesis}); !errors.Is(err, roster.ErrConflict) || first.State() != dieterv1.TrustState_TRUST_STATE_CONFLICT {
		t.Fatalf("conflicting genesis: %v %v", err, first.State())
	}
}

func TestApproveRetriesALostCompareAndSwap(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	gateway := newFakeGateway(t)
	first, _ := testTrust(t, gateway, "d_first", "First")
	if _, _, err := first.Initialize(ctx, false); err != nil {
		t.Fatal(err)
	}
	pending, _ := testTrust(t, gateway, "d_pending", "Pending")
	code := pendingCode(t, pending)
	raced := false
	gateway.beforeAppend = func(request *gatewayv1.AppendDeviceRosterRequest) error {
		if raced {
			return nil
		}
		raced = true
		// Another device appends first.
		gateway.mu.Lock()
		defer gateway.mu.Unlock()
		state, err := roster.Verify(gateway.entries)
		if err != nil {
			return err
		}
		_, key, _ := ed25519.GenerateKey(rand.Reader)
		entry, err := state.Add(mustDescribe(t, key, ""), first.signer)
		if err != nil {
			return err
		}
		gateway.entries = append(gateway.entries, entry)
		return nil
	}
	if _, err := first.Approve(ctx, code); err != nil {
		t.Fatal(err)
	}
	waitTrust(t, pending, func() bool { return pending.State() == dieterv1.TrustState_TRUST_STATE_TRUSTED }, "approval after a retried append")
	if head := first.Status().GetHeadSequence(); head != 3 {
		t.Fatalf("head=%d, want both appends", head)
	}
	// An abort from a gateway that never moves the head ends after bounded retries.
	gateway.beforeAppend = func(*gatewayv1.AppendDeviceRosterRequest) error { return status.Error(codes.Aborted, "head moved") }
	if _, err := first.Revoke(ctx, pending.DeviceID()); faultKind(err) != fault.Conflict {
		t.Fatalf("endless aborts: %v", err)
	}
}

func mustDescribe(t *testing.T, key ed25519.PrivateKey, daemonID string) *roster.Descriptor {
	t.Helper()
	kind := gatewayv1.DeviceKind_DEVICE_KIND_CLIENT
	if daemonID != "" {
		kind = gatewayv1.DeviceKind_DEVICE_KIND_DAEMON
	}
	descriptor, err := roster.Describe(kind, "linux", "Device", daemonID, key.Public())
	if err != nil {
		t.Fatal(err)
	}
	return descriptor
}
