package api

import (
	"context"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"google.golang.org/protobuf/types/known/emptypb"
)

// DeviceTrust is the daemon's verified device roster (internal/link). Only an
// enrolled daemon has one.
type DeviceTrust interface {
	Status() *dieterv1.TrustStatus
	Entries(from uint64) *gatewayv1.DeviceRoster
	Sync(ctx context.Context, entries []*gatewayv1.DeviceRosterEntry) (*dieterv1.TrustStatus, error)
	Initialize(ctx context.Context, replace bool) (*dieterv1.TrustStatus, string, error)
	ListRequests(ctx context.Context) ([]*dieterv1.PairingRequestInfo, error)
	Approve(ctx context.Context, code string) (*dieterv1.TrustStatus, error)
	Revoke(ctx context.Context, deviceID string) (*dieterv1.TrustStatus, error)
	Recover(ctx context.Context, recoveryKey string) (*dieterv1.TrustStatus, error)
}

const (
	deviceIDMetadata  = "x-dieter-device-id"
	maxOfferedEntries = 4096
)

// Device trust rules:
//   - Agent turns never change device trust: a call carrying a turn token is
//     refused for every mutation, including roster gossip.
//   - Starting a roster and recovering with the recovery key run only on the
//     local route, never for a remote device.
//   - Any trusted device may read the roster, offer entries, approve a code
//     its user typed, and revoke a device.

func (api *trustAPI) admit(ctx context.Context, localOnly bool) (DeviceTrust, error) {
	if requestHeader(ctx, turnTokenMetadata) != "" {
		return nil, fault.New(fault.PermissionDenied, "agents cannot change device trust")
	}
	if localOnly && requestHeader(ctx, operatorSubjectMetadata) != "" {
		return nil, fault.New(fault.PermissionDenied, "this operation runs only on the machine itself; run the command there without --machine")
	}
	return api.enrolled()
}

func (api *trustAPI) enrolled() (DeviceTrust, error) {
	if api.server.trust == nil {
		return nil, fault.New(fault.FailedPrecondition, "this machine is not enrolled; run `dieter daemon enroll`")
	}
	return api.server.trust, nil
}

func (api *trustAPI) GetTrustStatus(context.Context, *emptypb.Empty) (*dieterv1.TrustStatus, error) {
	if api.server.trust == nil {
		return &dieterv1.TrustStatus{State: dieterv1.TrustState_TRUST_STATE_NOT_ENROLLED}, nil
	}
	return api.server.trust.Status(), nil
}

func (api *trustAPI) GetDeviceRoster(_ context.Context, request *gatewayv1.GetDeviceRosterRequest) (*gatewayv1.DeviceRoster, error) {
	if api.server.trust == nil {
		return &gatewayv1.DeviceRoster{}, nil
	}
	return api.server.trust.Entries(request.GetFromSequence()), nil
}

func (api *trustAPI) SyncDeviceRoster(ctx context.Context, request *dieterv1.SyncDeviceRosterRequest) (*dieterv1.TrustStatus, error) {
	trust, err := api.admit(ctx, false)
	if err != nil {
		return nil, err
	}
	if len(request.GetEntries()) > maxOfferedEntries {
		return nil, fault.New(fault.Invalid, "too many roster entries")
	}
	return trust.Sync(ctx, request.GetEntries())
}

func (api *trustAPI) InitializeDeviceRoster(ctx context.Context, request *dieterv1.InitializeDeviceRosterRequest) (*dieterv1.InitializeDeviceRosterResponse, error) {
	trust, err := api.admit(ctx, true)
	if err != nil {
		return nil, err
	}
	value, recoveryKey, err := trust.Initialize(ctx, request.GetReplace())
	if err != nil {
		return nil, err
	}
	return &dieterv1.InitializeDeviceRosterResponse{Status: value, RecoveryKey: recoveryKey}, nil
}

func (api *trustAPI) ListPairingRequests(ctx context.Context, _ *emptypb.Empty) (*dieterv1.ListPairingRequestsResponse, error) {
	trust, err := api.enrolled()
	if err != nil {
		return nil, err
	}
	requests, err := trust.ListRequests(ctx)
	if err != nil {
		return nil, err
	}
	return &dieterv1.ListPairingRequestsResponse{Requests: requests}, nil
}

func (api *trustAPI) ApproveDevice(ctx context.Context, request *dieterv1.ApproveDeviceRequest) (*dieterv1.TrustStatus, error) {
	trust, err := api.admit(ctx, false)
	if err != nil {
		return nil, err
	}
	return trust.Approve(ctx, request.GetCode())
}

func (api *trustAPI) RevokeDevice(ctx context.Context, request *dieterv1.RevokeDeviceRequest) (*dieterv1.TrustStatus, error) {
	trust, err := api.admit(ctx, false)
	if err != nil {
		return nil, err
	}
	return trust.Revoke(ctx, request.GetDeviceId())
}

func (api *trustAPI) RecoverDeviceTrust(ctx context.Context, request *dieterv1.RecoverDeviceTrustRequest) (*dieterv1.TrustStatus, error) {
	trust, err := api.admit(ctx, true)
	if err != nil {
		return nil, err
	}
	return trust.Recover(ctx, request.GetRecoveryKey())
}
