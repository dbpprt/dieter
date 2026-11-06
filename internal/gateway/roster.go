package gateway

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/roster"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// The gateway stores and serves each account's device roster but cannot
// extend it: every entry is signed by a device that is already a member, and
// devices verify the chain against the root they pinned. The gateway verifies
// appends as well, so it never serves a chain that devices would reject.

// rosterCache keeps each account's verified roster, so an append verifies
// only its new entry. The gateway allowlist bounds the accounts.
type rosterCache struct {
	mu       sync.Mutex
	accounts map[int64]*accountRoster
}

type accountRoster struct {
	// mu serializes appends and loads.
	mu     sync.Mutex
	loaded bool
	// state is nil while the account has no roster.
	state *roster.State
	// epoch advances when the roster is replaced by a new genesis.
	epoch uint64
	// changed is closed and replaced after every change.
	changed chan struct{}
}

func (c *rosterCache) account(githubID int64) *accountRoster {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.accounts == nil {
		c.accounts = map[int64]*accountRoster{}
	}
	account := c.accounts[githubID]
	if account == nil {
		account = &accountRoster{changed: make(chan struct{})}
		c.accounts[githubID] = account
	}
	return account
}

// load verifies the stored roster once; a.mu is held.
func (a *accountRoster) load(store *Store, githubID int64) error {
	if a.loaded {
		return nil
	}
	entries, err := store.DeviceRoster(githubID)
	if err != nil {
		return err
	}
	a.state = nil
	if len(entries) > 0 {
		if a.state, err = roster.Verify(entries); err != nil {
			return err
		}
	}
	a.loaded = true
	return nil
}

func (s *Service) rosterSnapshot(githubID int64) (*roster.State, uint64, <-chan struct{}, error) {
	account := s.rosters.account(githubID)
	account.mu.Lock()
	defer account.mu.Unlock()
	if err := account.load(s.store, githubID); err != nil {
		return nil, 0, nil, status.Error(codes.Internal, "load device roster")
	}
	return account.state, account.epoch, account.changed, nil
}

func rosterProto(state *roster.State, from uint64) *gatewayv1.DeviceRoster {
	if state == nil {
		return &gatewayv1.DeviceRoster{}
	}
	return state.Proto(from)
}

func rosterLength(state *roster.State) uint64 {
	if state == nil {
		return 0
	}
	return state.Length()
}

func (s *Service) GetDeviceRoster(ctx context.Context, request *gatewayv1.GetDeviceRosterRequest) (*gatewayv1.DeviceRoster, error) {
	principal, ok := PrincipalFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "authentication required")
	}
	state, _, _, err := s.rosterSnapshot(principal.GitHubID)
	if err != nil {
		return nil, err
	}
	return rosterProto(state, request.GetFromSequence()), nil
}

// WatchDeviceRoster sends the roster from from_sequence, then every entry
// appended after it. A replaced roster is sent again from its genesis.
func (s *Service) WatchDeviceRoster(request *gatewayv1.GetDeviceRosterRequest, stream grpc.ServerStreamingServer[gatewayv1.DeviceRoster]) error {
	principal, ok := PrincipalFromContext(stream.Context())
	if !ok {
		return status.Error(codes.Unauthenticated, "authentication required")
	}
	from, sent, epoch, first := request.GetFromSequence(), uint64(0), uint64(0), true
	for {
		state, current, changed, err := s.rosterSnapshot(principal.GitHubID)
		if err != nil {
			return err
		}
		length := rosterLength(state)
		if first || current != epoch || length > sent {
			start := from
			if !first {
				start = sent
				if current != epoch {
					start = 0
				}
			}
			if err := stream.Send(rosterProto(state, start)); err != nil {
				return err
			}
			first, epoch, sent = false, current, length
		}
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case <-changed:
		}
	}
}

// AppendDeviceRoster stores one signed entry if it extends the current head
// exactly (compare-and-swap). With replace, a genesis entry starts a new
// roster for the account; devices that pinned the old one reject it.
func (s *Service) AppendDeviceRoster(ctx context.Context, request *gatewayv1.AppendDeviceRosterRequest) (*gatewayv1.DeviceRoster, error) {
	principal, ok := PrincipalFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "authentication required")
	}
	entry := request.GetEntry()
	if entry == nil {
		return nil, status.Error(codes.InvalidArgument, "a roster entry is required")
	}
	if entry.GetAccount() != roster.Account(s.config.IdentityOrigin(), principal.GitHubID) {
		return nil, status.Error(codes.PermissionDenied, "the roster entry belongs to another account")
	}
	account := s.rosters.account(principal.GitHubID)
	account.mu.Lock()
	defer account.mu.Unlock()
	if err := account.load(s.store, principal.GitHubID); err != nil {
		return nil, status.Error(codes.Internal, "load device roster")
	}
	length := rosterLength(account.state)
	var next *roster.State
	var err error
	switch {
	case request.GetReplace():
		if entry.GetOperation() != gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_GENESIS {
			return nil, status.Error(codes.InvalidArgument, "only a genesis entry can replace the device roster")
		}
		next, err = roster.Verify([]*roster.Entry{entry})
	case entry.GetSequence() != length || (account.state != nil && !bytes.Equal(entry.GetPrevious(), account.state.HeadHash())):
		return nil, status.Error(codes.Aborted, "the device roster changed; refresh it and sign the entry again")
	case account.state == nil:
		next, err = roster.Verify([]*roster.Entry{entry})
	default:
		next, err = account.state.Extend([]*roster.Entry{entry})
	}
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	if err := s.store.AppendDeviceRoster(principal.GitHubID, entry, length, request.GetReplace()); err != nil {
		// Reload from storage before the next operation.
		account.loaded = false
		if errors.Is(err, errRosterConflict) {
			return nil, status.Error(codes.Aborted, "the device roster changed; refresh it and sign the entry again")
		}
		return nil, status.Error(codes.Internal, "store device roster entry")
	}
	account.state = next
	if request.GetReplace() {
		account.epoch++
	}
	close(account.changed)
	account.changed = make(chan struct{})
	return next.Proto(0), nil
}

// PostPairingRequest leaves a joining device's note for the account. It is
// idempotent per device: re-posting refreshes the expiry and keeps the ID.
func (s *Service) PostPairingRequest(ctx context.Context, request *gatewayv1.PostPairingRequestRequest) (*gatewayv1.PairingRequest, error) {
	principal, ok := PrincipalFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "authentication required")
	}
	if err := roster.ValidateDescriptor(request.GetDevice()); err != nil {
		return nil, status.Error(codes.InvalidArgument, "the pairing device is invalid: "+err.Error())
	}
	if len(request.GetProof()) != sha256.Size {
		return nil, status.Error(codes.InvalidArgument, "the pairing proof must be 32 bytes")
	}
	record, err := s.store.PutPairingRequest(principal.GitHubID, request.GetDevice(), request.GetProof(), time.Now())
	if errors.Is(err, errPairingLimit) {
		return nil, status.Error(codes.ResourceExhausted, "too many devices are waiting to pair; try again later")
	}
	if err != nil {
		return nil, status.Error(codes.Internal, "store pairing request")
	}
	return record.proto(), nil
}

func (s *Service) ListPairingRequests(ctx context.Context, _ *emptypb.Empty) (*gatewayv1.ListPairingRequestsResponse, error) {
	principal, ok := PrincipalFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "authentication required")
	}
	records, err := s.store.PairingRequests(principal.GitHubID, time.Now())
	if err != nil {
		return nil, status.Error(codes.Internal, "list pairing requests")
	}
	response := &gatewayv1.ListPairingRequestsResponse{}
	for _, record := range records {
		response.Requests = append(response.Requests, record.proto())
	}
	return response, nil
}

// ConfirmPairingRequest attaches the approver's confirmation, which the new
// device verifies before it pins the roster.
func (s *Service) ConfirmPairingRequest(ctx context.Context, request *gatewayv1.ConfirmPairingRequestRequest) (*gatewayv1.PairingRequest, error) {
	principal, ok := PrincipalFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "authentication required")
	}
	if len(request.GetConfirmation()) != sha256.Size {
		return nil, status.Error(codes.InvalidArgument, "the pairing confirmation must be 32 bytes")
	}
	record, err := s.store.ConfirmPairingRequest(principal.GitHubID, request.GetId(), request.GetConfirmation(), time.Now())
	switch {
	case errors.Is(err, errPairingNotFound):
		return nil, status.Error(codes.NotFound, "pairing request not found")
	case errors.Is(err, errPairingConfirmed):
		return nil, status.Error(codes.FailedPrecondition, "the pairing request was already confirmed")
	case err != nil:
		return nil, status.Error(codes.Internal, "confirm pairing request")
	}
	return record.proto(), nil
}

func (s *Service) DeletePairingRequest(ctx context.Context, request *gatewayv1.PairingRequestRef) (*emptypb.Empty, error) {
	principal, ok := PrincipalFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "authentication required")
	}
	err := s.store.DeletePairingRequest(principal.GitHubID, request.GetId(), time.Now())
	if errors.Is(err, errPairingNotFound) {
		return nil, status.Error(codes.NotFound, "pairing request not found")
	}
	if err != nil {
		return nil, status.Error(codes.Internal, "delete pairing request")
	}
	return &emptypb.Empty{}, nil
}
