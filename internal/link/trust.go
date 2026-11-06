package link

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unicode"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/security/roster"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

// Trust is the daemon's verified view of the account's device roster. It pins
// the roster this machine joined, follows it through the gateway, and decides
// which devices may open a connection. Every entry it adopts extends the
// pinned chain and is signed by a member, so the gateway that stores the
// roster can withhold entries but cannot add a device or fork history
// unnoticed. This package is the only writer of the pinned roster
// (daemon/roster.pb) and its state (daemon/trust.json).
type Trust struct {
	identity *Identity
	log      *slog.Logger
	// Gateway returns a possession-authenticated gateway connection; nil
	// dials the enrolled gateway.
	Gateway func(context.Context) (grpc.ClientConnInterface, error)
	// PairingPoll is how often a pending machine checks for its approval;
	// zero is two seconds. Isolated tests shorten it.
	PairingPoll time.Duration

	// opMu serializes roster changes, including their gateway round trips.
	opMu    sync.Mutex
	mu      sync.Mutex
	pinned  *roster.State
	meta    trustMeta
	changed chan struct{}
	rebased chan struct{}
	conn    *grpc.ClientConn
	self    *roster.Descriptor
	signer  roster.Signer
}

// trustMeta is daemon/trust.json.
type trustMeta struct {
	Conflict bool   `json:"conflict,omitempty"`
	Detail   string `json:"detail,omitempty"`
	// Evidence records the conflicting sequence and hashes for an operator.
	Evidence      string `json:"evidence,omitempty"`
	NoRoster      bool   `json:"noRoster,omitempty"`
	PairingSecret string `json:"pairingSecret,omitempty"`
	RequestID     string `json:"requestId,omitempty"`
	RequestedAt   string `json:"requestedAt,omitempty"`
	SyncedAt      string `json:"syncedAt,omitempty"`
}

const (
	pairingPoll    = 2 * time.Second
	pairingRefresh = 5 * time.Minute
	appendAttempts = 5
)

// ErrNotTrusted reports a machine that is not an active member of a pinned
// roster.
var ErrNotTrusted = errors.New("this machine is not a trusted device; run `dieter device status`")

func rosterPath(root string) string { return filepath.Join(root, "daemon", "roster.pb") }
func trustPath(root string) string  { return filepath.Join(root, "daemon", "trust.json") }

// OpenTrust loads the pinned roster of identity's DIETER_HOME. A nil or
// unenrolled identity yields a store that reports NOT_ENROLLED.
func OpenTrust(identity *Identity, logger *slog.Logger) (*Trust, error) {
	if logger == nil {
		logger = slog.Default()
	}
	t := &Trust{identity: identity, log: logger, changed: make(chan struct{}), rebased: make(chan struct{})}
	if identity == nil || !identity.Enrolled() {
		return t, nil
	}
	descriptor, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_DAEMON, DevicePlatform(), deviceName(identity.Name), identity.ID, identity.PublicKey)
	if err != nil {
		return nil, err
	}
	t.self, t.signer = descriptor, roster.Ed25519Signer(identity.PrivateKey, descriptor)
	raw, err := os.ReadFile(trustPath(identity.Root))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err == nil {
		if err := json.Unmarshal(raw, &t.meta); err != nil {
			return nil, fmt.Errorf("decode device trust state: %w", err)
		}
	}
	state, err := readPinnedRoster(identity.Root)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, fmt.Errorf("the pinned device roster is invalid: %w", err)
	default:
		t.pinned = state
	}
	return t, nil
}

// PinnedRoster reads the roster the daemon of root pinned, for read-only
// callers such as the CLI. It fails when the daemon recorded a conflict.
func PinnedRoster(root string) (*roster.State, error) {
	raw, err := os.ReadFile(trustPath(root))
	if err == nil {
		var meta trustMeta
		if json.Unmarshal(raw, &meta) == nil && meta.Conflict {
			return nil, fmt.Errorf("device trust conflict: %s; run `dieter device status`", meta.Detail)
		}
	}
	return readPinnedRoster(root)
}

func readPinnedRoster(root string) (*roster.State, error) {
	raw, err := os.ReadFile(rosterPath(root))
	if err != nil {
		return nil, err
	}
	var value gatewayv1.DeviceRoster
	if err := proto.Unmarshal(raw, &value); err != nil {
		return nil, err
	}
	return roster.Verify(value.GetEntries())
}

// DevicePlatform is the roster platform of this daemon host.
func DevicePlatform() string {
	if runtime.GOOS == "darwin" {
		return "macos"
	}
	return runtime.GOOS
}

func deviceName(name string) string {
	name = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, strings.TrimSpace(name))
	if name == "" {
		name, _ = os.Hostname()
	}
	if name == "" {
		name = "Dieter machine"
	}
	return name
}

// Close releases the gateway connection.
func (t *Trust) Close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.conn != nil {
		_ = t.conn.Close()
		t.conn = nil
	}
}

func (t *Trust) enrolled() bool { return t.self != nil }

func (t *Trust) poll() time.Duration {
	if t.PairingPoll > 0 {
		return t.PairingPoll
	}
	return pairingPoll
}

// DeviceID is this machine's roster device ID.
func (t *Trust) DeviceID() string {
	if t.self == nil {
		return ""
	}
	return t.self.GetDeviceId()
}

func (t *Trust) gateway(ctx context.Context) (grpc.ClientConnInterface, error) {
	if !t.enrolled() {
		return nil, fault.New(fault.FailedPrecondition, "this machine is not enrolled; run `dieter daemon enroll`")
	}
	if t.Gateway != nil {
		return t.Gateway(ctx)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.conn == nil {
		conn, err := DialGateway(ctx, t.identity, false)
		if err != nil {
			return nil, fault.Wrap(fault.Unavailable, err)
		}
		t.conn = conn
	}
	return PossessionConn(t.conn, t.identity), nil
}

func (t *Trust) client(ctx context.Context) (gatewayv1.GatewayServiceClient, error) {
	conn, err := t.gateway(ctx)
	if err != nil {
		return nil, err
	}
	return gatewayv1.NewGatewayServiceClient(conn), nil
}

// gatewayFailure keeps the meaning of a gateway status as a fault kind.
func gatewayFailure(action string, err error) error {
	if _, ok := fault.KindOf(err); ok {
		return err
	}
	value := status.Convert(err)
	kind := fault.Unavailable
	switch value.Code() {
	case codes.InvalidArgument, codes.OutOfRange:
		kind = fault.Invalid
	case codes.NotFound:
		kind = fault.NotFound
	case codes.AlreadyExists:
		kind = fault.AlreadyExists
	case codes.FailedPrecondition:
		kind = fault.FailedPrecondition
	case codes.PermissionDenied:
		kind = fault.PermissionDenied
	case codes.Unauthenticated:
		kind = fault.Unauthenticated
	case codes.Aborted:
		kind = fault.Conflict
	case codes.ResourceExhausted:
		kind = fault.ResourceExhausted
	case codes.Canceled, codes.DeadlineExceeded:
		return err
	}
	return fault.Errorf(kind, "%s: %s", action, value.Message())
}

// snapshot returns the pinned roster and state under the lock.
func (t *Trust) snapshot() (*roster.State, trustMeta) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.pinned, t.meta
}

func (t *Trust) wake(rebase bool) {
	close(t.changed)
	t.changed = make(chan struct{})
	if rebase {
		close(t.rebased)
		t.rebased = make(chan struct{})
	}
}

func (t *Trust) signals() (<-chan struct{}, <-chan struct{}) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.changed, t.rebased
}

// update persists meta and, when state is not nil, pins it.
func (t *Trust) update(state *roster.State, change func(*trustMeta)) error {
	if !t.enrolled() {
		return fault.New(fault.FailedPrecondition, "this machine is not enrolled")
	}
	t.mu.Lock()
	meta := t.meta
	previous := t.pinned
	t.mu.Unlock()
	if change != nil {
		change(&meta)
	}
	root := t.identity.Root
	err := writeLocked(root, func() error {
		if state != nil {
			raw, err := proto.Marshal(&gatewayv1.DeviceRoster{Entries: state.Entries(0), HeadSequence: state.HeadSequence(), HeadHash: state.HeadHash(), Length: state.Length()})
			if err != nil {
				return err
			}
			if err := fsx.WriteFile(rosterPath(root), raw, 0o600); err != nil {
				return err
			}
		}
		raw, err := json.MarshalIndent(meta, "", "  ")
		if err != nil {
			return err
		}
		return fsx.WriteFile(trustPath(root), append(raw, '\n'), 0o600)
	})
	if err != nil {
		return err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	rebase := false
	if state != nil {
		rebase = previous == nil || !bytes.Equal(previous.Root(), state.Root())
		t.pinned = state
	}
	rebase = rebase || meta.Conflict != t.meta.Conflict
	t.meta = meta
	t.wake(rebase)
	return nil
}

func (t *Trust) recordConflict(err error, evidence string) {
	t.log.Error("device roster conflicts with the pinned roster; refusing remote calls", "error", err)
	if updateErr := t.update(nil, func(meta *trustMeta) {
		meta.Conflict, meta.Detail, meta.Evidence = true, err.Error(), evidence
	}); updateErr != nil {
		t.log.Error("could not persist device trust conflict", "error", updateErr)
		t.mu.Lock()
		t.meta.Conflict, t.meta.Detail = true, err.Error()
		t.wake(true)
		t.mu.Unlock()
	}
}

// stateOf classifies the trust state.
func (t *Trust) stateOf(state *roster.State, meta trustMeta) dieterv1.TrustState {
	switch {
	case !t.enrolled():
		return dieterv1.TrustState_TRUST_STATE_NOT_ENROLLED
	case meta.Conflict:
		return dieterv1.TrustState_TRUST_STATE_CONFLICT
	case state != nil:
		if member := state.Member(t.DeviceID()); member.Active() {
			return dieterv1.TrustState_TRUST_STATE_TRUSTED
		}
		return dieterv1.TrustState_TRUST_STATE_REVOKED
	case meta.PairingSecret != "":
		return dieterv1.TrustState_TRUST_STATE_PENDING
	case meta.NoRoster:
		return dieterv1.TrustState_TRUST_STATE_NO_ROSTER
	}
	return dieterv1.TrustState_TRUST_STATE_UNSPECIFIED
}

// State is the current trust state.
func (t *Trust) State() dieterv1.TrustState {
	state, meta := t.snapshot()
	return t.stateOf(state, meta)
}

// Status describes the pinned roster for the TrustService.
func (t *Trust) Status() *dieterv1.TrustStatus {
	state, meta := t.snapshot()
	result := &dieterv1.TrustStatus{State: t.stateOf(state, meta), DeviceId: t.DeviceID(), Detail: meta.Detail, SyncedAt: meta.SyncedAt}
	if meta.Evidence != "" {
		result.Detail = strings.TrimSpace(result.Detail + " (" + meta.Evidence + ")")
	}
	if result.State == dieterv1.TrustState_TRUST_STATE_PENDING {
		if secret, err := hex.DecodeString(meta.PairingSecret); err == nil {
			result.PairingCode = roster.PairingCode(secret)
		}
	}
	if state == nil {
		return result
	}
	result.RootHash, result.HeadSequence, result.HeadHash = roster.EncodeHash(state.Root()), state.HeadSequence(), roster.EncodeHash(state.HeadHash())
	members := state.Members()
	// Active devices first, this machine first among them, then removed ones.
	ordered := make([]*roster.Member, 0, len(members))
	for _, pass := range []func(*roster.Member) bool{
		func(m *roster.Member) bool { return m.Active() && m.Descriptor.GetDeviceId() == t.DeviceID() },
		func(m *roster.Member) bool { return m.Active() && m.Descriptor.GetDeviceId() != t.DeviceID() },
		func(m *roster.Member) bool { return !m.Active() },
	} {
		for _, member := range members {
			if pass(member) {
				ordered = append(ordered, member)
			}
		}
	}
	for _, member := range ordered {
		device := member.Descriptor
		result.Devices = append(result.Devices, &dieterv1.TrustedDevice{
			DeviceId: device.GetDeviceId(), Kind: device.GetKind(), Platform: device.GetPlatform(), Name: device.GetName(),
			DaemonId: device.GetDaemonId(), AddedBy: member.AddedBy, AddedSequence: member.AddedAt, Revoked: member.Revoked,
			ThisDevice: device.GetDeviceId() == t.DeviceID(),
		})
	}
	return result
}

// Entries returns the pinned roster from sequence from.
func (t *Trust) Entries(from uint64) *gatewayv1.DeviceRoster {
	state, _ := t.snapshot()
	if state == nil {
		return &gatewayv1.DeviceRoster{}
	}
	return state.Proto(from)
}

// trusted returns the pinned roster when this machine is an active member and
// no conflict was recorded.
func (t *Trust) trusted() (*roster.State, error) {
	state, meta := t.snapshot()
	switch t.stateOf(state, meta) {
	case dieterv1.TrustState_TRUST_STATE_TRUSTED:
		return state, nil
	case dieterv1.TrustState_TRUST_STATE_CONFLICT:
		return nil, fault.Errorf(fault.FailedPrecondition, "device trust conflict: %s", meta.Detail)
	case dieterv1.TrustState_TRUST_STATE_NOT_ENROLLED:
		return nil, fault.New(fault.FailedPrecondition, "this machine is not enrolled; run `dieter daemon enroll`")
	}
	return nil, fault.Wrap(fault.FailedPrecondition, ErrNotTrusted)
}

// Connecting returns the roster member whose key is spki, a DER
// SubjectPublicKeyInfo, when it may open a connection to this machine.
func (t *Trust) Connecting(spki []byte) (*roster.Member, error) {
	state, err := t.trusted()
	if err != nil {
		return nil, err
	}
	member := state.Member(roster.DeviceID(spki))
	if !member.Connects() || !bytes.Equal(member.Descriptor.GetPublicKey(), spki) {
		return nil, fault.New(fault.Unauthenticated, "the device is not a member of the account's device roster")
	}
	return member, nil
}

// DaemonKey returns the roster key of daemonID's active daemon device.
func (t *Trust) DaemonKey(daemonID string) ([]byte, error) {
	state, err := t.trusted()
	if err != nil {
		return nil, err
	}
	member := state.Daemon(daemonID)
	if member == nil {
		return nil, fault.Errorf(fault.FailedPrecondition, "machine %s is not a trusted device of this account", daemonID)
	}
	return append([]byte(nil), member.Descriptor.GetPublicKey()...), nil
}

// Signer signs roster entries and device certificates as this machine.
func (t *Trust) Signer() roster.Signer { return t.signer }

// apply adopts a roster served by the gateway. Only signed entries count:
// a served entry that conflicts with a pinned one and is a member-signed
// continuation is a fork; unsigned fields such as the head hash are ignored.
func (t *Trust) apply(served *gatewayv1.DeviceRoster) error {
	state, meta := t.snapshot()
	if state == nil || meta.Conflict {
		return nil
	}
	return t.adopt(state, served.GetEntries(), "gateway")
}

func (t *Trust) adopt(state *roster.State, entries []*roster.Entry, source string) error {
	next, err := state.Extend(entries)
	if errors.Is(err, roster.ErrConflict) {
		evidence := source
		for _, entry := range entries {
			if sequence := entry.GetSequence(); sequence < state.Length() && !bytes.Equal(roster.Hash(entry), state.HashAt(sequence)) {
				evidence = fmt.Sprintf("%s, sequence %d: pinned %s, offered %s", source, sequence, roster.EncodeHash(state.HashAt(sequence)), roster.EncodeHash(roster.Hash(entry)))
				break
			}
		}
		t.recordConflict(err, evidence)
		return err
	}
	if err != nil {
		return fault.Wrap(fault.Invalid, err)
	}
	synced := source == "gateway"
	if next.Length() == state.Length() && !synced {
		return nil
	}
	pin := next
	if next.Length() == state.Length() {
		pin = nil
	}
	return t.update(pin, func(meta *trustMeta) {
		if synced {
			meta.SyncedAt = time.Now().UTC().Format(time.RFC3339)
		}
		if meta.Detail != "" && !meta.Conflict {
			meta.Detail = ""
		}
	})
}

// Offer adopts entries another device presented when they extend the pinned
// roster; a different entry at a pinned sequence is a conflict.
func (t *Trust) Offer(entries []*roster.Entry) error {
	t.opMu.Lock()
	defer t.opMu.Unlock()
	state, meta := t.snapshot()
	if state == nil {
		return fault.Wrap(fault.FailedPrecondition, ErrNotTrusted)
	}
	if meta.Conflict {
		return fault.Errorf(fault.FailedPrecondition, "device trust conflict: %s", meta.Detail)
	}
	return t.adopt(state, entries, "peer")
}

// Refresh fetches the roster from the gateway and adopts what extends the
// pinned one.
func (t *Trust) Refresh(ctx context.Context) error {
	t.opMu.Lock()
	defer t.opMu.Unlock()
	return t.refresh(ctx)
}

func (t *Trust) refresh(ctx context.Context) error {
	state, meta := t.snapshot()
	if state == nil || meta.Conflict {
		return nil
	}
	client, err := t.client(ctx)
	if err != nil {
		return err
	}
	served, err := client.GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{FromSequence: state.Length() - 1})
	if err != nil {
		return gatewayFailure("fetch the device roster", err)
	}
	return t.apply(served)
}

// Sync adopts offered entries and then refreshes from the gateway.
func (t *Trust) Sync(ctx context.Context, entries []*roster.Entry) (*dieterv1.TrustStatus, error) {
	if len(entries) > 0 {
		if err := t.Offer(entries); err != nil && !errors.Is(err, roster.ErrConflict) {
			return nil, err
		}
	}
	if t.State() == dieterv1.TrustState_TRUST_STATE_TRUSTED || t.State() == dieterv1.TrustState_TRUST_STATE_REVOKED {
		if err := t.Refresh(ctx); err != nil && !errors.Is(err, roster.ErrConflict) {
			t.log.Warn("device roster refresh failed", "error", err)
		}
	}
	return t.Status(), nil
}

// appendEntry appends one signed entry built by build against the freshest
// roster, retrying a lost compare-and-swap.
func (t *Trust) appendEntry(ctx context.Context, build func(*roster.State) (*roster.Entry, error)) (*roster.State, *roster.Entry, error) {
	client, err := t.client(ctx)
	if err != nil {
		return nil, nil, err
	}
	for attempt := 0; ; attempt++ {
		if err := t.refresh(ctx); err != nil {
			return nil, nil, err
		}
		state, err := t.trusted()
		if err != nil {
			return nil, nil, err
		}
		entry, err := build(state)
		if err != nil || entry == nil {
			return state, nil, err
		}
		if _, err = client.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: entry}); status.Code(err) == codes.Aborted && attempt+1 < appendAttempts {
			continue
		} else if err != nil {
			return nil, nil, gatewayFailure("append to the device roster", err)
		}
		next, err := state.Extend([]*roster.Entry{entry})
		if err != nil {
			return nil, nil, err
		}
		if err := t.update(next, nil); err != nil {
			return nil, nil, err
		}
		return next, entry, nil
	}
}

// Initialize starts the account's roster with this machine and its recovery
// key. It refuses an account that already has a roster unless replace is set;
// replacing makes every previously paired device reject the new roster.
func (t *Trust) Initialize(ctx context.Context, replace bool) (*dieterv1.TrustStatus, string, error) {
	t.opMu.Lock()
	defer t.opMu.Unlock()
	if !t.enrolled() {
		return nil, "", fault.New(fault.FailedPrecondition, "this machine is not enrolled; run `dieter daemon enroll`")
	}
	if state, _ := t.snapshot(); state != nil && !replace {
		return nil, "", fault.New(fault.FailedPrecondition, "this machine already pinned the account's device roster; --replace starts a new one")
	}
	client, err := t.client(ctx)
	if err != nil {
		return nil, "", err
	}
	account, err := client.GetAccount(ctx, &emptypb.Empty{})
	if err != nil {
		return nil, "", gatewayFailure("read the gateway account", err)
	}
	if account.GetGithubId() <= 0 {
		return nil, "", fault.New(fault.FailedPrecondition, "the gateway returned no account")
	}
	genesis, err := roster.Genesis(roster.Account(t.identity.Issuer(), account.GetGithubId()), t.signer)
	if err != nil {
		return nil, "", err
	}
	state, err := roster.Verify([]*roster.Entry{genesis})
	if err != nil {
		return nil, "", err
	}
	recoveryKey, recovery, err := roster.NewRecoveryKey(state.Root())
	if err != nil {
		return nil, "", err
	}
	add, err := state.Add(recovery.Descriptor(), t.signer)
	if err != nil {
		return nil, "", err
	}
	if _, err := client.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: genesis, Replace: replace}); status.Code(err) == codes.Aborted {
		return nil, "", fault.New(fault.FailedPrecondition, "the account already has a device roster; pair this machine from a trusted device instead (`dieter device status` shows its code), or replace the roster with --replace")
	} else if err != nil {
		return nil, "", gatewayFailure("start the device roster", err)
	}
	if _, err := client.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: add}); err != nil {
		// The genesis is stored; pin it so this machine stays consistent with
		// the gateway, and report that the recovery key is missing.
		_ = t.update(state, func(meta *trustMeta) { *meta = trustMeta{SyncedAt: time.Now().UTC().Format(time.RFC3339)} })
		return nil, "", gatewayFailure("add the recovery key (run `dieter device init --replace` to start over)", err)
	}
	next, err := state.Extend([]*roster.Entry{add})
	if err != nil {
		return nil, "", err
	}
	_, meta := t.snapshot()
	if err := t.update(next, func(value *trustMeta) { *value = trustMeta{SyncedAt: time.Now().UTC().Format(time.RFC3339)} }); err != nil {
		return nil, "", err
	}
	if meta.RequestID != "" {
		_, _ = client.DeletePairingRequest(ctx, &gatewayv1.PairingRequestRef{Id: meta.RequestID})
	}
	return t.Status(), recoveryKey, nil
}

// pairingRequests lists the account's pending pairing requests.
func (t *Trust) pairingRequests(ctx context.Context) ([]*gatewayv1.PairingRequest, error) {
	client, err := t.client(ctx)
	if err != nil {
		return nil, err
	}
	list, err := client.ListPairingRequests(ctx, &emptypb.Empty{})
	if err != nil {
		return nil, gatewayFailure("list pairing requests", err)
	}
	return list.GetRequests(), nil
}

// ListRequests returns the devices waiting to join, by name only.
func (t *Trust) ListRequests(ctx context.Context) ([]*dieterv1.PairingRequestInfo, error) {
	state, err := t.trusted()
	if err != nil {
		return nil, err
	}
	requests, err := t.pairingRequests(ctx)
	if err != nil {
		return nil, err
	}
	var result []*dieterv1.PairingRequestInfo
	for _, request := range requests {
		device := request.GetDevice()
		// A device that already joined deletes its request shortly after.
		if device.GetDeviceId() == t.DeviceID() || state.Member(device.GetDeviceId()) != nil {
			continue
		}
		result = append(result, &dieterv1.PairingRequestInfo{
			Id: request.GetId(), DeviceId: device.GetDeviceId(), Kind: device.GetKind(), Platform: device.GetPlatform(),
			Name: device.GetName(), RequestedAt: request.GetRequestedAt(), ExpiresAt: request.GetExpiresAt(),
		})
	}
	return result, nil
}

// Approve signs the device that shows code into the roster and confirms the
// pairing to it. The request whose proof verifies with the code's secret is
// exactly what that device posted, so the gateway cannot substitute a key.
func (t *Trust) Approve(ctx context.Context, code string) (*dieterv1.TrustStatus, error) {
	secret, err := roster.ParsePairingCode(code)
	if err != nil {
		return nil, fault.Wrap(fault.Invalid, err)
	}
	t.opMu.Lock()
	defer t.opMu.Unlock()
	if _, err := t.trusted(); err != nil {
		return nil, err
	}
	requests, err := t.pairingRequests(ctx)
	if err != nil {
		return nil, err
	}
	// One code may admit several devices (isolated fixtures share one): a
	// waiting device goes first, then one that joined but missed its
	// confirmation.
	pinned, _ := t.snapshot()
	var request *gatewayv1.PairingRequest
	for _, candidate := range requests {
		if !roster.VerifyPairingProof(secret, candidate.GetDevice(), candidate.GetProof()) {
			continue
		}
		if request == nil || pinned.Member(request.GetDevice().GetDeviceId()) != nil && pinned.Member(candidate.GetDevice().GetDeviceId()) == nil {
			request = candidate
		}
	}
	if request == nil {
		return nil, fault.New(fault.NotFound, "No device is waiting with this code")
	}
	device := request.GetDevice()
	if err := roster.ValidateDescriptor(device); err != nil {
		return nil, fault.Wrap(fault.Invalid, err)
	}
	var added []byte
	state, entry, err := t.appendEntry(ctx, func(state *roster.State) (*roster.Entry, error) {
		if member := state.Member(device.GetDeviceId()); member != nil {
			if !member.Active() || !proto.Equal(member.Descriptor, device) {
				return nil, fault.New(fault.FailedPrecondition, "this device was removed from the roster; it must reset and pair again with a new key")
			}
			// A repeated approval confirms the existing entry again.
			added = state.HashAt(member.AddedAt)
			return nil, nil
		}
		entry, err := state.Add(device, t.signer)
		if err != nil {
			return nil, fault.Wrap(fault.Invalid, err)
		}
		return entry, nil
	})
	if err != nil {
		return nil, err
	}
	if entry != nil {
		added = roster.Hash(entry)
	}
	client, err := t.client(ctx)
	if err != nil {
		return nil, err
	}
	if _, err := client.ConfirmPairingRequest(ctx, &gatewayv1.ConfirmPairingRequestRequest{Id: request.GetId(), Confirmation: roster.PairingConfirmation(secret, state.Root(), added)}); err != nil {
		return nil, gatewayFailure("confirm the pairing", err)
	}
	return t.Status(), nil
}

// Revoke removes deviceID from the roster. Revoking this machine is allowed.
func (t *Trust) Revoke(ctx context.Context, deviceID string) (*dieterv1.TrustStatus, error) {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return nil, fault.New(fault.Invalid, "device ID is required")
	}
	t.opMu.Lock()
	defer t.opMu.Unlock()
	_, _, err := t.appendEntry(ctx, func(state *roster.State) (*roster.Entry, error) {
		member := state.Member(deviceID)
		if member == nil {
			return nil, fault.Errorf(fault.NotFound, "device %s is not in the roster", deviceID)
		}
		if !member.Active() {
			return nil, nil
		}
		entry, err := state.Revoke(deviceID, t.signer)
		if err != nil {
			return nil, fault.Wrap(fault.FailedPrecondition, err)
		}
		return entry, nil
	})
	if err != nil {
		return nil, err
	}
	return t.Status(), nil
}

// Recover adds this machine to the roster with the recovery key printed at
// initialization. The key commits to the roster's root, so it only signs
// into the roster it was made for, never one the gateway made up.
func (t *Trust) Recover(ctx context.Context, recoveryKey string) (*dieterv1.TrustStatus, error) {
	recovery, prefix, err := roster.ParseRecoveryKey(recoveryKey)
	if err != nil {
		return nil, fault.Wrap(fault.Invalid, err)
	}
	t.opMu.Lock()
	defer t.opMu.Unlock()
	if !t.enrolled() {
		return nil, fault.New(fault.FailedPrecondition, "this machine is not enrolled; run `dieter daemon enroll`")
	}
	if t.State() == dieterv1.TrustState_TRUST_STATE_TRUSTED {
		return nil, fault.New(fault.FailedPrecondition, "this machine is already a trusted device")
	}
	client, err := t.client(ctx)
	if err != nil {
		return nil, err
	}
	for attempt := 0; ; attempt++ {
		served, err := client.GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{})
		if err != nil {
			return nil, gatewayFailure("fetch the device roster", err)
		}
		if len(served.GetEntries()) == 0 {
			return nil, fault.New(fault.FailedPrecondition, "the account has no device roster; run `dieter device init`")
		}
		state, err := roster.Verify(served.GetEntries())
		if err != nil {
			return nil, fault.Wrap(fault.FailedPrecondition, err)
		}
		if !roster.RecoveryCommits(prefix, state.Root()) {
			return nil, fault.New(fault.PermissionDenied, "this recovery key belongs to another device roster")
		}
		if !state.Member(recovery.Descriptor().GetDeviceId()).Active() {
			return nil, fault.New(fault.PermissionDenied, "this recovery key is not an active member of the device roster")
		}
		if !strings.HasPrefix(state.Account(), strings.TrimRight(t.identity.Issuer(), "/")+"|") {
			return nil, fault.New(fault.FailedPrecondition, "the device roster belongs to another gateway")
		}
		if pinned, _ := t.snapshot(); pinned != nil {
			if _, err := pinned.Extend(state.Entries(0)); err != nil {
				return nil, fault.Wrap(fault.FailedPrecondition, fmt.Errorf("the gateway's roster does not extend the pinned one: %w", err))
			}
		}
		entry, err := state.Add(t.self, recovery)
		if err != nil {
			return nil, fault.Wrap(fault.FailedPrecondition, err)
		}
		if _, err = client.AppendDeviceRoster(ctx, &gatewayv1.AppendDeviceRosterRequest{Entry: entry}); status.Code(err) == codes.Aborted && attempt+1 < appendAttempts {
			continue
		} else if err != nil {
			return nil, gatewayFailure("append to the device roster", err)
		}
		next, err := state.Extend([]*roster.Entry{entry})
		if err != nil {
			return nil, err
		}
		_, meta := t.snapshot()
		if err := t.update(next, func(value *trustMeta) { *value = trustMeta{SyncedAt: time.Now().UTC().Format(time.RFC3339)} }); err != nil {
			return nil, err
		}
		if meta.RequestID != "" {
			_, _ = client.DeletePairingRequest(ctx, &gatewayv1.PairingRequestRef{Id: meta.RequestID})
		}
		return t.Status(), nil
	}
}

// Run follows the roster until ctx ends: a pinned roster is watched and
// extended, an unpinned machine asks to join and waits for its approval.
// Only `dieter serve` runs it.
func (t *Trust) Run(ctx context.Context) {
	if !t.enrolled() {
		return
	}
	backoff := time.Second
	for ctx.Err() == nil {
		changed, _ := t.signals()
		started := time.Now()
		err := t.runOnce(ctx)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			t.log.Warn("device roster sync pending", "error", err, "state", t.State().String())
		} else if time.Since(started) > time.Minute {
			backoff = time.Second
		}
		delay := backoff
		if err == nil {
			delay = 5 * t.poll()
		} else {
			backoff = min(backoff*2, time.Minute)
		}
		state := t.State()
		if state == dieterv1.TrustState_TRUST_STATE_CONFLICT || state == dieterv1.TrustState_TRUST_STATE_REVOKED {
			delay = time.Hour
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-changed:
			timer.Stop()
		case <-timer.C:
		}
	}
}

func (t *Trust) runOnce(ctx context.Context) error {
	switch t.State() {
	case dieterv1.TrustState_TRUST_STATE_CONFLICT, dieterv1.TrustState_TRUST_STATE_REVOKED:
		return nil
	case dieterv1.TrustState_TRUST_STATE_TRUSTED:
		return t.watch(ctx)
	}
	return t.pair(ctx)
}

// watch streams roster changes until the stream fails or the pinned root
// changes.
func (t *Trust) watch(ctx context.Context) error {
	_, rebased := t.signals()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		select {
		case <-rebased:
			cancel()
		case <-ctx.Done():
		}
	}()
	state, _ := t.snapshot()
	client, err := t.client(ctx)
	if err != nil {
		return err
	}
	stream, err := client.WatchDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{FromSequence: state.Length() - 1})
	if err != nil {
		return gatewayFailure("watch the device roster", err)
	}
	for {
		served, err := stream.Recv()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return gatewayFailure("watch the device roster", err)
		}
		t.opMu.Lock()
		err = t.apply(served)
		t.opMu.Unlock()
		if errors.Is(err, roster.ErrConflict) {
			return nil
		}
		if err != nil {
			t.log.Warn("ignored an invalid device roster from the gateway", "error", err)
		}
	}
}

// pair asks to join an existing roster and pins it once a trusted device
// confirmed the pairing with this machine's code. A roster that merely
// contains this machine is never enough: the gateway could fabricate one.
func (t *Trust) pair(ctx context.Context) error {
	client, err := t.client(ctx)
	if err != nil {
		return err
	}
	served, err := client.GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{})
	if err != nil {
		return gatewayFailure("fetch the device roster", err)
	}
	if served.GetLength() == 0 && len(served.GetEntries()) == 0 {
		t.opMu.Lock()
		defer t.opMu.Unlock()
		if state, meta := t.snapshot(); state == nil && (!meta.NoRoster || meta.PairingSecret != "") {
			return t.update(nil, func(meta *trustMeta) {
				meta.NoRoster, meta.PairingSecret, meta.RequestID, meta.RequestedAt = true, "", "", ""
			})
		}
		return nil
	}
	_, rebased := t.signals()
	for ctx.Err() == nil {
		done, err := t.pairStep(ctx, client)
		if done || err != nil {
			return err
		}
		timer := time.NewTimer(t.poll())
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-rebased:
			timer.Stop()
			return nil
		case <-timer.C:
		}
	}
	return nil
}

// pairStep posts or refreshes this machine's request and checks it for a
// confirmation. It reports done once the roster is pinned.
func (t *Trust) pairStep(ctx context.Context, client gatewayv1.GatewayServiceClient) (bool, error) {
	t.opMu.Lock()
	defer t.opMu.Unlock()
	if state, _ := t.snapshot(); state != nil {
		return true, nil
	}
	_, meta := t.snapshot()
	secret, err := hex.DecodeString(meta.PairingSecret)
	if err != nil || len(secret) == 0 {
		if secret, _, err = roster.NewPairingSecret(); err != nil {
			return false, err
		}
		if err := t.update(nil, func(meta *trustMeta) {
			meta.NoRoster, meta.PairingSecret, meta.RequestID, meta.RequestedAt = false, hex.EncodeToString(secret), "", ""
		}); err != nil {
			return false, err
		}
		t.log.Info("this machine asked to join the account's device roster; type its code on a trusted device", "command", "dieter device status")
		_, meta = t.snapshot()
	}
	requests, err := t.pairingRequests(ctx)
	if err != nil {
		return false, err
	}
	var own *gatewayv1.PairingRequest
	for _, request := range requests {
		if request.GetId() == meta.RequestID || request.GetDevice().GetDeviceId() == t.DeviceID() {
			own = request
			break
		}
	}
	requestedAt, _ := time.Parse(time.RFC3339, meta.RequestedAt)
	if own == nil || own.GetId() != meta.RequestID || time.Since(requestedAt) > pairingRefresh {
		posted, err := client.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: t.self, Proof: roster.PairingProof(secret, t.self)})
		if err != nil {
			return false, gatewayFailure("post the pairing request", err)
		}
		if err := t.update(nil, func(meta *trustMeta) {
			meta.NoRoster, meta.RequestID, meta.RequestedAt = false, posted.GetId(), time.Now().UTC().Format(time.RFC3339)
		}); err != nil {
			return false, err
		}
		if own == nil || len(own.GetConfirmation()) == 0 {
			return false, nil
		}
	}
	confirmation := own.GetConfirmation()
	if len(confirmation) == 0 {
		return false, nil
	}
	served, err := client.GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{})
	if err != nil {
		return false, gatewayFailure("fetch the device roster", err)
	}
	state, err := roster.Verify(served.GetEntries())
	if err != nil {
		return false, fault.Wrap(fault.FailedPrecondition, fmt.Errorf("the gateway's device roster is invalid: %w", err))
	}
	member := state.Member(t.DeviceID())
	if member == nil {
		return false, nil
	}
	if !member.Active() || !proto.Equal(member.Descriptor, t.self) || !roster.VerifyPairingConfirmation(secret, state.Root(), state.HashAt(member.AddedAt), confirmation) {
		_ = t.update(nil, func(meta *trustMeta) {
			meta.Detail = "a pairing confirmation did not verify; still waiting for a trusted device"
		})
		return false, nil
	}
	if !strings.HasPrefix(state.Account(), strings.TrimRight(t.identity.Issuer(), "/")+"|") {
		return false, fault.New(fault.FailedPrecondition, "the confirmed device roster belongs to another gateway")
	}
	if err := t.update(state, func(meta *trustMeta) { *meta = trustMeta{SyncedAt: time.Now().UTC().Format(time.RFC3339)} }); err != nil {
		return false, err
	}
	if _, err := client.DeletePairingRequest(ctx, &gatewayv1.PairingRequestRef{Id: own.GetId()}); err != nil {
		t.log.Warn("could not delete the completed pairing request", "error", err)
	}
	t.log.Info("this machine joined the account's device roster", "device", t.DeviceID(), "head", state.HeadSequence())
	return true, nil
}
