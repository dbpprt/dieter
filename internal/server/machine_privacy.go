package server

import (
	"context"
	"fmt"
	"strings"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func (s *Server) privacyState(ctx context.Context) *dieterv1.MachinePrivacy {
	s.privacyMu.Lock()
	defer s.privacyMu.Unlock()
	if s.privacySnapshot != nil && time.Since(s.privacyReadAt) < time.Second {
		return proto.Clone(s.privacySnapshot).(*dieterv1.MachinePrivacy)
	}
	probe, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	value, err := s.privacyDriver.Snapshot(probe)
	if err != nil {
		value = &dieterv1.MachinePrivacy{Reason: fmt.Sprintf("Privacy status unavailable: %v", err)}
	}
	if value == nil {
		value = &dieterv1.MachinePrivacy{Reason: "Privacy status unavailable"}
	}
	request, readErr := s.store.MachinePrivacyRequest()
	if readErr != nil {
		value.Reason = "Privacy request could not be read"
		value.State = dieterv1.MachinePrivacy_STATE_DEGRADED
	}
	if request.Enabled {
		boot, bootErr := s.privacyBootID(probe)
		if bootErr != nil {
			value.Requested = true
			value.State = dieterv1.MachinePrivacy_STATE_DEGRADED
			value.Reason = "Privacy boot identity is unavailable; protection cannot be verified"
		} else if boot == request.BootID {
			value.Requested = true
			if value.State != dieterv1.MachinePrivacy_STATE_ON {
				value.State = dieterv1.MachinePrivacy_STATE_DEGRADED
				if value.Reason == "" {
					value.Reason = "Privacy helper stopped; local protection is no longer verified. Unlock or enable privacy mode again."
				}
			}
		}
	}
	s.privacySnapshot, s.privacyReadAt = proto.Clone(value).(*dieterv1.MachinePrivacy), time.Now()
	return value
}

func (api *grpcAPI) performPrivacyOperation(ctx context.Context, request *dieterv1.MachineOperationRequest) (*dieterv1.MachineOperationResponse, error) {
	key := strings.TrimSpace(request.GetIdempotencyKey())
	if len(key) > 128 || strings.ContainsAny(key, "\r\n\x00") {
		return nil, status.Error(codes.InvalidArgument, "idempotency_key must be at most 128 printable characters")
	}
	if key == "" {
		key = randomMachineOperationID()
	}
	s := api.server
	s.machineOperationMu.Lock()
	defer s.machineOperationMu.Unlock()
	if previous, ok := s.machineOperations[key]; ok {
		if previous.action != request.GetAction() {
			return nil, status.Error(codes.AlreadyExists, "idempotency_key was already used for a different machine operation")
		}
		return proto.Clone(previous.response).(*dieterv1.MachineOperationResponse), nil
	}
	if s.pendingMachineOperation != "" {
		return nil, status.Error(codes.FailedPrecondition, "another machine operation is already pending")
	}
	s.privacyMu.Lock()
	defer s.privacyMu.Unlock()
	bounded, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if request.GetAction() == dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_PRIVACY_SETUP {
		current, err := s.privacyDriver.Snapshot(bounded)
		if err != nil {
			return nil, status.Error(codes.FailedPrecondition, "Cannot verify privacy before helper setup")
		}
		if current.GetRequested() || current.GetState() == dieterv1.MachinePrivacy_STATE_ON {
			return nil, status.Error(codes.FailedPrecondition, "Unlock privacy before changing the helper registration")
		}
		driver, ok := s.privacyDriver.(remotedesktop.PrivacySetupDriver)
		if !ok {
			return nil, status.Error(codes.FailedPrecondition, "Privacy helper setup is unavailable")
		}
		if _, err := driver.Setup(bounded); err != nil {
			return nil, status.Error(codes.FailedPrecondition, err.Error())
		}
		s.privacySnapshot = nil
		response := &dieterv1.MachineOperationResponse{Accepted: true, OperationId: key, Message: "Privacy helper setup requested. On the target Mac, approve Dieter Daemon in System Settings > General > Login Items & Extensions and grant Input Monitoring. Privacy stays off until you lock the local screen."}
		s.machineOperations[key] = acceptedMachineOperation{action: request.GetAction(), response: response}
		s.machineOperationOrder = append(s.machineOperationOrder, key)
		for len(s.machineOperationOrder) > 32 {
			delete(s.machineOperations, s.machineOperationOrder[0])
			s.machineOperationOrder = s.machineOperationOrder[1:]
		}
		return proto.Clone(response).(*dieterv1.MachineOperationResponse), nil
	}
	boot, err := s.privacyBootID(bounded)
	if err != nil {
		return nil, status.Error(codes.FailedPrecondition, err.Error())
	}
	enabled := request.GetAction() == dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_PRIVACY_ON
	// Commit the intent before dispatch. Recovery must not mistake a lost
	// response for an instruction to unlock. Only this boot can recover it.
	if err := s.store.SetMachinePrivacyRequest(store.MachinePrivacyRequest{BootID: boot, Enabled: enabled}); err != nil {
		return nil, grpcFailure(err)
	}
	value, err := s.privacyDriver.Set(bounded, enabled)
	if err != nil {
		// A transport failure may follow a committed native action. Preserve
		// intent and reconcile current state; never turn an uncertain lock off.
		s.privacySnapshot = nil
		return nil, status.Error(codes.FailedPrecondition, err.Error())
	}
	if value == nil || value.Requested != enabled || (enabled && value.State != dieterv1.MachinePrivacy_STATE_ON) || (!enabled && value.State != dieterv1.MachinePrivacy_STATE_OFF) {
		s.privacySnapshot = nil
		return nil, status.Error(codes.FailedPrecondition, "native privacy protection did not confirm the requested state")
	}
	s.privacySnapshot, s.privacyReadAt = proto.Clone(value).(*dieterv1.MachinePrivacy), time.Now()
	message := "Privacy mode is on. Local displays and input are blocked until you unlock or reboot this Mac."
	if !enabled {
		message = "Privacy mode is off. Local displays and input are restored."
	}
	response := &dieterv1.MachineOperationResponse{Accepted: true, Message: message, OperationId: key}
	s.machineOperations[key] = acceptedMachineOperation{action: request.GetAction(), response: response}
	s.machineOperationOrder = append(s.machineOperationOrder, key)
	for len(s.machineOperationOrder) > 32 {
		old := s.machineOperationOrder[0]
		s.machineOperationOrder = s.machineOperationOrder[1:]
		if old != s.pendingMachineOperation {
			delete(s.machineOperations, old)
		}
	}
	return proto.Clone(response).(*dieterv1.MachineOperationResponse), nil
}

func (s *Server) restorePrivacy(ctx context.Context) {
	s.machineOperationMu.Lock()
	defer s.machineOperationMu.Unlock()
	s.privacyMu.Lock()
	defer s.privacyMu.Unlock()
	request, err := s.store.MachinePrivacyRequest()
	if err != nil || !request.Enabled {
		return
	}
	bounded, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	boot, err := s.privacyBootID(bounded)
	if err != nil || boot != request.BootID {
		return
	}
	current, err := s.privacyDriver.Snapshot(bounded)
	if err != nil {
		s.log.Error("could not verify machine privacy recovery", "error", err)
		return
	}
	// Adopt a surviving capture owner without issuing another on request. That
	// owner may have detected a privileged-helper restart; recovery must retain
	// its degraded state until an explicit privacy operation adopts a new lease.
	if current.GetRequested() {
		s.privacySnapshot, s.privacyReadAt = proto.Clone(current).(*dieterv1.MachinePrivacy), time.Now()
		return
	}
	value, err := s.privacyDriver.Set(bounded, true)
	if err != nil {
		s.log.Error("could not recover machine privacy", "error", err)
		return
	}
	s.privacySnapshot, s.privacyReadAt = value, time.Now()
}
