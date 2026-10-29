package roster

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

var update = flag.Bool("update", false, "rewrite tests/fixtures/roster/vectors.json")

const testAccount = "https://gateway.test|github:42"

type device struct {
	signer Signer
	public any
}

func daemonDevice(t *testing.T, name, daemonID string) device {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	descriptor, err := Describe(gatewayv1.DeviceKind_DEVICE_KIND_DAEMON, "linux", name, daemonID, public)
	if err != nil {
		t.Fatal(err)
	}
	return device{Ed25519Signer(private, descriptor), public}
}

func clientDevice(t *testing.T, name string) device {
	t.Helper()
	private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	descriptor, err := Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "android", name, "", &private.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return device{ECDSASigner(private, descriptor), &private.PublicKey}
}

func genesis(t *testing.T, first device) *State {
	t.Helper()
	entry, err := Genesis(testAccount, first.signer)
	if err != nil {
		t.Fatal(err)
	}
	state, err := Verify([]*Entry{entry})
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func extend(t *testing.T, state *State, entry *Entry, err error) *State {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	next, err := state.Extend([]*Entry{entry})
	if err != nil {
		t.Fatal(err)
	}
	return next
}

func TestRosterAddsAndRevokesMembersSignedByMembers(t *testing.T) {
	t.Parallel()
	machine, phone, laptop := daemonDevice(t, "Build box", "d_one"), clientDevice(t, "Phone"), daemonDevice(t, "Laptop", "d_two")
	state := genesis(t, machine)
	entry, err := state.Add(phone.signer.Descriptor(), machine.signer)
	state = extend(t, state, entry, err)
	entry, err = state.Add(laptop.signer.Descriptor(), phone.signer)
	state = extend(t, state, entry, err)
	if !state.Member(phone.signer.Descriptor().GetDeviceId()).Connects() || state.Daemon("d_two") == nil || state.Length() != 3 {
		t.Fatalf("members after additions: %+v", state.Members())
	}
	if added := state.Member(laptop.signer.Descriptor().GetDeviceId()); added.AddedBy != phone.signer.Descriptor().GetDeviceId() || added.AddedAt != 2 {
		t.Fatalf("laptop provenance = %+v", added)
	}
	entry, err = state.Revoke(phone.signer.Descriptor().GetDeviceId(), laptop.signer)
	state = extend(t, state, entry, err)
	if state.Member(phone.signer.Descriptor().GetDeviceId()).Active() {
		t.Fatal("revoked phone is still active")
	}
	// A revoked device can no longer sign, even with its own key.
	if _, err := state.Add(clientDevice(t, "Tablet").signer.Descriptor(), phone.signer); err == nil {
		t.Fatal("a revoked device signed an addition")
	}
	// The whole chain verifies from scratch and pins the same head.
	again, err := Verify(state.Entries(0))
	if err != nil || !bytes.Equal(again.HeadHash(), state.HeadHash()) || !bytes.Equal(again.Root(), state.Root()) {
		t.Fatalf("re-verification = %v", err)
	}
}

func TestRosterRejectsEntriesTheGatewayCouldForge(t *testing.T) {
	t.Parallel()
	machine, phone := daemonDevice(t, "Build box", "d_one"), clientDevice(t, "Phone")
	state := genesis(t, machine)
	stranger := clientDevice(t, "Gateway")
	add := func(mutate func(*Entry), signer Signer) error {
		entry := &Entry{
			Account: testAccount, Sequence: state.Length(), Previous: state.HeadHash(), Operation: gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_ADD,
			Device: proto.Clone(phone.signer.Descriptor()).(*Descriptor), Signer: signer.Descriptor().GetDeviceId(), CreatedAt: "2026-10-12T00:00:00Z",
		}
		mutate(entry)
		signature, err := signer.Sign(Canonical(entry))
		if err != nil {
			t.Fatal(err)
		}
		entry.Signature = signature
		_, err = state.Extend([]*Entry{entry})
		return err
	}
	for name, attempt := range map[string]func() error{
		"non-member signer": func() error { return add(func(*Entry) {}, stranger.signer) },
		"claims member signer": func() error {
			return add(func(e *Entry) { e.Signer = machine.signer.Descriptor().GetDeviceId() }, stranger.signer)
		},
		"other account": func() error {
			return add(func(e *Entry) { e.Account = "https://gateway.test|github:43" }, machine.signer)
		},
		"wrong previous":   func() error { return add(func(e *Entry) { e.Previous = make([]byte, 32) }, machine.signer) },
		"skipped sequence": func() error { return add(func(e *Entry) { e.Sequence++ }, machine.signer) },
		"rebound device ID": func() error {
			return add(func(e *Entry) { e.Device.DeviceId = stranger.signer.Descriptor().GetDeviceId() }, machine.signer)
		},
		"daemon without ID": func() error {
			return add(func(e *Entry) { e.Device.Kind = gatewayv1.DeviceKind_DEVICE_KIND_DAEMON }, machine.signer)
		},
		"control characters": func() error { return add(func(e *Entry) { e.Device.Name = "Phone\nApproved" }, machine.signer) },
		"unknown operation":  func() error { return add(func(e *Entry) { e.Operation = 9 }, machine.signer) },
		"second genesis": func() error {
			return add(func(e *Entry) { e.Operation = gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_GENESIS }, machine.signer)
		},
	} {
		if err := attempt(); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: err = %v, want ErrInvalid", name, err)
		}
	}
	// A valid signature over altered content does not verify.
	entry, err := state.Add(phone.signer.Descriptor(), machine.signer)
	if err != nil {
		t.Fatal(err)
	}
	entry.Device.Name = "Renamed by relay"
	if _, err := state.Extend([]*Entry{entry}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("altered entry: %v", err)
	}
}

func TestRosterDetectsConflictsWithThePinnedHistory(t *testing.T) {
	t.Parallel()
	machine, phone, tablet := daemonDevice(t, "Build box", "d_one"), clientDevice(t, "Phone"), clientDevice(t, "Tablet")
	state := genesis(t, machine)
	left, err := state.Add(phone.signer.Descriptor(), machine.signer)
	if err != nil {
		t.Fatal(err)
	}
	right, err := state.Add(tablet.signer.Descriptor(), machine.signer)
	if err != nil {
		t.Fatal(err)
	}
	pinned := extend(t, state, left, nil)
	// Re-offering pinned entries is fine; a different entry at a pinned
	// sequence is equivocation.
	if _, err := pinned.Extend(pinned.Entries(0)); err != nil {
		t.Fatalf("identical history: %v", err)
	}
	if _, err := pinned.Extend([]*Entry{right}); !errors.Is(err, ErrConflict) {
		t.Fatalf("fork: %v", err)
	}
	other := genesis(t, daemonDevice(t, "Elsewhere", "d_x"))
	if _, err := pinned.Extend(other.Entries(0)); !errors.Is(err, ErrConflict) {
		t.Fatalf("another genesis: %v", err)
	}
	// An unsigned or garbled entry at a pinned sequence is invalid data, not
	// evidence of a fork.
	garbled := proto.Clone(right).(*Entry)
	garbled.Signature = []byte("not a signature")
	if _, err := pinned.Extend([]*Entry{garbled}); !errors.Is(err, ErrInvalid) || errors.Is(err, ErrConflict) {
		t.Fatalf("garbled fork: %v", err)
	}
	stranger := clientDevice(t, "Gateway")
	forged := proto.Clone(right).(*Entry)
	forged.Signer = stranger.signer.Descriptor().GetDeviceId()
	if forged.Signature, err = stranger.signer.Sign(Canonical(forged)); err != nil {
		t.Fatal(err)
	}
	if _, err := pinned.Extend([]*Entry{forged}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("fork signed by a non-member: %v", err)
	}
}

func TestRosterKeepsOneConnectingDeviceAndOneDevicePerMachine(t *testing.T) {
	t.Parallel()
	machine := daemonDevice(t, "Build box", "d_one")
	state := genesis(t, machine)
	if _, err := state.Revoke(machine.signer.Descriptor().GetDeviceId(), machine.signer); !errors.Is(err, ErrInvalid) {
		t.Fatalf("revoked the only device: %v", err)
	}
	_, recovery, err := NewRecoveryKey(state.Root())
	if err != nil {
		t.Fatal(err)
	}
	entry, err := state.Add(recovery.Descriptor(), machine.signer)
	state = extend(t, state, entry, err)
	if state.Member(recovery.Descriptor().GetDeviceId()).Connects() {
		t.Fatal("a recovery key may connect")
	}
	if _, err := state.Revoke(machine.signer.Descriptor().GetDeviceId(), recovery); !errors.Is(err, ErrInvalid) {
		t.Fatalf("recovery key revoked the last connecting device: %v", err)
	}
	if _, err := state.Add(daemonDevice(t, "Clone", "d_one").signer.Descriptor(), machine.signer); !errors.Is(err, ErrInvalid) {
		t.Fatalf("second device for one machine: %v", err)
	}
	// The recovery key can add a replacement machine.
	replacement := daemonDevice(t, "Replacement", "d_two")
	entry, err = state.Add(replacement.signer.Descriptor(), recovery)
	extend(t, state, entry, err)
}

func TestRecoveryKeyRoundTripAndCommitsToTheRoot(t *testing.T) {
	t.Parallel()
	root := bytes.Repeat([]byte{7}, 32)
	printed, signer, err := NewRecoveryKey(root)
	if err != nil {
		t.Fatal(err)
	}
	parsed, prefix, err := ParseRecoveryKey(strings.ToLower(strings.ReplaceAll(printed, "-", " ")))
	if err != nil || parsed.Descriptor().GetDeviceId() != signer.Descriptor().GetDeviceId() {
		t.Fatalf("parse %q = %v", printed, err)
	}
	if !RecoveryCommits(prefix, root) || RecoveryCommits(prefix, bytes.Repeat([]byte{8}, 32)) {
		t.Fatal("recovery key does not commit to exactly its root")
	}
	// Change one character of the seed; the final character carries padding.
	typo := []byte(printed)
	if typo[6] == '0' {
		typo[6] = '1'
	} else {
		typo[6] = '0'
	}
	if _, _, err := ParseRecoveryKey(string(typo)); err == nil {
		t.Fatal("a mistyped recovery key was accepted")
	}
}

func TestPairingBindsTheDeviceAndTheApproversRoster(t *testing.T) {
	t.Parallel()
	secret, code, err := NewPairingSecret()
	if err != nil {
		t.Fatal(err)
	}
	if len(code) != 19 {
		t.Fatalf("code = %q", code)
	}
	typed, err := ParsePairingCode(strings.ToLower(strings.ReplaceAll(code, "-", "")))
	if err != nil || !bytes.Equal(typed, secret) {
		t.Fatalf("typed code = %x, %v", typed, err)
	}
	if _, err := ParsePairingCode("ABCD-EFGH"); err == nil {
		t.Fatal("a short code was accepted")
	}
	phone, impostor := clientDevice(t, "Phone"), clientDevice(t, "Phone")
	proof := PairingProof(secret, phone.signer.Descriptor())
	if !VerifyPairingProof(secret, phone.signer.Descriptor(), proof) {
		t.Fatal("proof does not verify")
	}
	renamed := proto.Clone(phone.signer.Descriptor()).(*Descriptor)
	renamed.Name = "Laptop"
	other, _, _ := NewPairingSecret()
	if VerifyPairingProof(secret, impostor.signer.Descriptor(), proof) || VerifyPairingProof(secret, renamed, proof) || VerifyPairingProof(other, phone.signer.Descriptor(), proof) {
		t.Fatal("proof accepted another key, name or secret")
	}
	root, entry := bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 32)
	confirmation := PairingConfirmation(secret, root, entry)
	if !VerifyPairingConfirmation(secret, root, entry, confirmation) ||
		VerifyPairingConfirmation(secret, bytes.Repeat([]byte{3}, 32), entry, confirmation) ||
		VerifyPairingConfirmation(other, root, entry, confirmation) {
		t.Fatal("confirmation does not bind the root and secret")
	}
}

// vectors are shared with the Kotlin core (tests/fixtures/roster/vectors.json).
type vectors struct {
	Account string `json:"account"`
	// Entries are protobuf-JSON-free: every bytes field is hex.
	Entries  []vectorEntry  `json:"entries"`
	Devices  []vectorDevice `json:"devices"`
	RootHash string         `json:"rootHash"`
	HeadHash string         `json:"headHash"`
	Pairing  vectorPairing  `json:"pairing"`
}

type vectorDevice struct {
	PublicKey string `json:"publicKey"`
	DeviceID  string `json:"deviceId"`
	// DescriptorBytes of the device's entry in the roster.
	Descriptor string `json:"descriptor"`
}

// vectorPairing covers the app's pairing: its secret and code, the proof of
// its descriptor, and the confirmation of the entry that added it.
type vectorPairing struct {
	Secret       string `json:"secret"`
	Code         string `json:"code"`
	DeviceID     string `json:"deviceId"`
	Proof        string `json:"proof"`
	AddHash      string `json:"addHash"`
	Confirmation string `json:"confirmation"`
}

type vectorEntry struct {
	Account   string `json:"account"`
	Sequence  uint64 `json:"sequence"`
	Previous  string `json:"previous"`
	Operation int32  `json:"operation"`
	DeviceID  string `json:"deviceId"`
	Kind      int32  `json:"kind"`
	Platform  string `json:"platform"`
	Name      string `json:"name"`
	Algorithm int32  `json:"algorithm"`
	PublicKey string `json:"publicKey"`
	DaemonID  string `json:"daemonId"`
	Signer    string `json:"signer"`
	CreatedAt string `json:"createdAt"`
	Signature string `json:"signature"`
	// Canonical and Hash are what both implementations must compute.
	Canonical string `json:"canonical"`
	Hash      string `json:"hash"`
}

func (v vectorEntry) entry(t *testing.T) *Entry {
	t.Helper()
	decode := func(value string) []byte {
		raw, err := hex.DecodeString(value)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	return &Entry{
		Account: v.Account, Sequence: v.Sequence, Previous: decode(v.Previous), Operation: gatewayv1.DeviceRosterOperation(v.Operation),
		Device: &Descriptor{DeviceId: v.DeviceID, Kind: gatewayv1.DeviceKind(v.Kind), Platform: v.Platform, Name: v.Name, Algorithm: gatewayv1.DeviceKeyAlgorithm(v.Algorithm), PublicKey: decode(v.PublicKey), DaemonId: v.DaemonID},
		Signer: v.Signer, CreatedAt: v.CreatedAt, Signature: decode(v.Signature),
	}
}

func vectorPath() string {
	return filepath.Join("..", "..", "..", "tests", "fixtures", "roster", "vectors.json")
}

func TestGoldenVectors(t *testing.T) {
	if *update {
		writeVectors(t)
	}
	raw, err := os.ReadFile(vectorPath())
	if err != nil {
		t.Fatal(err)
	}
	var fixture vectors
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	entries := make([]*Entry, 0, len(fixture.Entries))
	for _, vector := range fixture.Entries {
		entry := vector.entry(t)
		if got := hex.EncodeToString(Canonical(entry)); got != vector.Canonical {
			t.Fatalf("entry %d canonical bytes differ", vector.Sequence)
		}
		if got := hex.EncodeToString(Hash(entry)); got != vector.Hash {
			t.Fatalf("entry %d hash = %s, want %s", vector.Sequence, got, vector.Hash)
		}
		entries = append(entries, entry)
	}
	state, err := Verify(entries)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(state.Root()) != fixture.RootHash || hex.EncodeToString(state.HeadHash()) != fixture.HeadHash {
		t.Fatal("root or head hash differs")
	}
	for _, vector := range fixture.Devices {
		key, _ := hex.DecodeString(vector.PublicKey)
		member := state.Member(vector.DeviceID)
		if DeviceID(key) != vector.DeviceID || member == nil || hex.EncodeToString(DescriptorBytes(member.Descriptor)) != vector.Descriptor {
			t.Fatalf("device %s: ID or descriptor bytes differ", vector.DeviceID)
		}
	}
	pairing := fixture.Pairing
	secret, _ := hex.DecodeString(pairing.Secret)
	addHash, _ := hex.DecodeString(pairing.AddHash)
	if PairingCode(secret) != pairing.Code || hex.EncodeToString(PairingProof(secret, state.Member(pairing.DeviceID).Descriptor)) != pairing.Proof ||
		hex.EncodeToString(PairingConfirmation(secret, state.Root(), addHash)) != pairing.Confirmation {
		t.Fatal("pairing code, proof or confirmation differs")
	}
}

// writeVectors builds a deterministic roster: Ed25519 keys from fixed seeds
// and a P-256 app key from a fixed scalar. ECDSA signatures are randomized,
// so a regenerated file changes only their bytes and the hashes stay fixed.
func writeVectors(t *testing.T) {
	t.Helper()
	seed := func(label string) []byte { sum := sha256.Sum256([]byte(label)); return sum[:] }
	machineKey := ed25519.NewKeyFromSeed(seed("vector machine"))
	machine, _ := Describe(gatewayv1.DeviceKind_DEVICE_KIND_DAEMON, "macos", "Studio Mac", "d_vectormachine", machineKey.Public())
	appKey, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), seed("vector app"))
	if err != nil {
		t.Fatal(err)
	}
	app, _ := Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "ios", "Dennis’ iPhone", "", &appKey.PublicKey)
	recoveryKey := ed25519.NewKeyFromSeed(seed("vector recovery"))
	recovery, _ := Describe(gatewayv1.DeviceKind_DEVICE_KIND_RECOVERY, "recovery", "Recovery key", "", recoveryKey.Public())
	secondKey := ed25519.NewKeyFromSeed(seed("vector second machine"))
	second, _ := Describe(gatewayv1.DeviceKind_DEVICE_KIND_DAEMON, "linux", "Build box", "d_vectorsecond", secondKey.Public())
	machineSigner, appSigner := Ed25519Signer(machineKey, machine), ECDSASigner(appKey, app)
	recoverySigner := Ed25519Signer(recoveryKey, recovery)
	stamp := "2026-10-12T09:00:00Z"
	sign := func(entry *Entry, signer Signer) *Entry {
		entry.CreatedAt = stamp
		signature, err := signer.Sign(Canonical(entry))
		if err != nil {
			t.Fatal(err)
		}
		entry.Signature = signature
		return entry
	}
	state, err := Verify([]*Entry{sign(&Entry{Account: testAccount, Operation: gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_GENESIS, Device: machine, Signer: machine.DeviceId}, machineSigner)})
	if err != nil {
		t.Fatal(err)
	}
	next := func(operation gatewayv1.DeviceRosterOperation, device *Descriptor, signer Signer) {
		entry := sign(&Entry{Account: testAccount, Sequence: state.Length(), Previous: state.HeadHash(), Operation: operation, Device: device, Signer: signer.Descriptor().GetDeviceId()}, signer)
		if state, err = state.Extend([]*Entry{entry}); err != nil {
			t.Fatal(err)
		}
	}
	next(gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_ADD, recovery, machineSigner)
	next(gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_ADD, app, machineSigner)
	next(gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_ADD, second, appSigner)
	next(gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_REVOKE, &Descriptor{DeviceId: second.DeviceId}, recoverySigner)
	fixture := vectors{Account: testAccount, RootHash: hex.EncodeToString(state.Root()), HeadHash: hex.EncodeToString(state.HeadHash())}
	for _, entry := range state.Entries(0) {
		device := entry.GetDevice()
		fixture.Entries = append(fixture.Entries, vectorEntry{
			Account: entry.GetAccount(), Sequence: entry.GetSequence(), Previous: hex.EncodeToString(entry.GetPrevious()), Operation: int32(entry.GetOperation()),
			DeviceID: device.GetDeviceId(), Kind: int32(device.GetKind()), Platform: device.GetPlatform(), Name: device.GetName(), Algorithm: int32(device.GetAlgorithm()),
			PublicKey: hex.EncodeToString(device.GetPublicKey()), DaemonID: device.GetDaemonId(), Signer: entry.GetSigner(), CreatedAt: entry.GetCreatedAt(),
			Signature: hex.EncodeToString(entry.GetSignature()), Canonical: hex.EncodeToString(Canonical(entry)), Hash: hex.EncodeToString(Hash(entry)),
		})
	}
	for _, descriptor := range []*Descriptor{machine, app, recovery, second} {
		fixture.Devices = append(fixture.Devices, vectorDevice{hex.EncodeToString(descriptor.GetPublicKey()), descriptor.GetDeviceId(), hex.EncodeToString(DescriptorBytes(descriptor))})
	}
	secret := seed("vector pairing")[:pairingSecretBytes]
	addHash := state.HashAt(2)
	fixture.Pairing = vectorPairing{
		Secret: hex.EncodeToString(secret), Code: PairingCode(secret), DeviceID: app.DeviceId,
		Proof: hex.EncodeToString(PairingProof(secret, app)), AddHash: hex.EncodeToString(addHash),
		Confirmation: hex.EncodeToString(PairingConfirmation(secret, state.Root(), addHash)),
	}
	raw, err := json.MarshalIndent(fixture, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(vectorPath()), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(vectorPath(), append(raw, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}
