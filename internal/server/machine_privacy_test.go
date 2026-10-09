package server

import (
	"context"
	"errors"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"io"
	"log/slog"
	"testing"
	"time"
)

type fakePrivacy struct {
	value      *dieterv1.MachinePrivacy
	calls      int
	failure    error
	setupCalls int
}

func (f *fakePrivacy) Setup(ctx context.Context) (*dieterv1.MachinePrivacy, error) {
	f.setupCalls++
	if f.failure != nil {
		return nil, f.failure
	}
	return f.Snapshot(ctx)
}

func TestPrivacySetupIsIdempotentAndNeverEnablesProtection(t *testing.T) {
	s, driver := privacyFixture(t)
	api := &grpcAPI{server: s}
	request := &dieterv1.MachineOperationRequest{Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_PRIVACY_SETUP, IdempotencyKey: "setup"}
	for range 2 {
		if response, err := api.PerformMachineOperation(t.Context(), request); err != nil || !response.GetAccepted() {
			t.Fatalf("setup=%v error=%v", response, err)
		}
	}
	if driver.setupCalls != 1 || driver.calls != 0 {
		t.Fatalf("setup=%d privacy=%d", driver.setupCalls, driver.calls)
	}
	stored, err := s.store.MachinePrivacyRequest()
	if err != nil || stored.Enabled {
		t.Fatalf("setup enabled privacy: %v %v", stored, err)
	}
	request.IdempotencyKey = "failed-setup"
	driver.failure = errors.New("registration denied")
	if _, err := api.PerformMachineOperation(t.Context(), request); status.Code(err) != codes.FailedPrecondition {
		t.Fatal(err)
	}
	setupCalls := driver.setupCalls
	driver.failure = nil
	driver.value = &dieterv1.MachinePrivacy{Requested: true, State: dieterv1.MachinePrivacy_STATE_DEGRADED}
	request.IdempotencyKey = "degraded-setup"
	if _, err := api.PerformMachineOperation(t.Context(), request); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("setup changed a degraded privacy lease: %v", err)
	}
	if driver.setupCalls != setupCalls {
		t.Fatalf("setup ran while privacy was requested: %d", driver.setupCalls)
	}
}

func (f *fakePrivacy) Snapshot(context.Context) (*dieterv1.MachinePrivacy, error) {
	return proto.Clone(f.value).(*dieterv1.MachinePrivacy), nil
}
func (f *fakePrivacy) Set(_ context.Context, enabled bool) (*dieterv1.MachinePrivacy, error) {
	f.calls++
	if f.failure != nil {
		return nil, f.failure
	}
	f.value.Requested = enabled
	f.value.State = dieterv1.MachinePrivacy_STATE_OFF
	if enabled {
		f.value.State = dieterv1.MachinePrivacy_STATE_ON
	}
	return f.Snapshot(context.Background())
}
func privacyFixture(t *testing.T) (*Server, *fakePrivacy) {
	t.Helper()
	driver := &fakePrivacy{value: &dieterv1.MachinePrivacy{Supported: true, DisplayCount: 1}}
	application := NewWithOptions(store.New(t.TempDir()), slog.New(slog.NewTextHandler(io.Discard, nil)), Options{
		PrivacyDriver: driver, PrivacyBootID: func(context.Context) (string, error) { return "boot-one", nil },
	})
	return application, driver
}
func TestPrivacyOperationPersistenceIdempotencyAndDegradation(t *testing.T) {
	s, driver := privacyFixture(t)
	api := &grpcAPI{server: s}
	request := &dieterv1.MachineOperationRequest{Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_PRIVACY_ON, IdempotencyKey: "lock-once"}
	for range 2 {
		response, err := api.PerformMachineOperation(t.Context(), request)
		if err != nil || !response.GetAccepted() {
			t.Fatalf("response=%v error=%v", response, err)
		}
	}
	if driver.calls != 1 {
		t.Fatalf("dispatched %d times", driver.calls)
	}
	stored, err := s.store.MachinePrivacyRequest()
	if err != nil || !stored.Enabled || stored.BootID != "boot-one" {
		t.Fatalf("stored=%v err=%v", stored, err)
	}
	request.Action = dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_PRIVACY_OFF
	if _, err := api.PerformMachineOperation(t.Context(), request); status.Code(err) != codes.AlreadyExists {
		t.Fatalf("key conflict: %v", err)
	}
	driver.value.State = dieterv1.MachinePrivacy_STATE_OFF
	driver.value.Requested = false
	s.privacyReadAt = time.Time{}
	if value := s.privacyState(t.Context()); !value.Requested || value.State != dieterv1.MachinePrivacy_STATE_DEGRADED {
		t.Fatalf("lost helper=%v", value)
	}
	request.IdempotencyKey = "unlock-once"
	if _, err := api.PerformMachineOperation(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	if value := s.privacyState(t.Context()); value.Requested || value.State != dieterv1.MachinePrivacy_STATE_OFF {
		t.Fatalf("unlock=%v", value)
	}
}
func TestPrivacyRestoresOnlySameBootAndNeverInConstructor(t *testing.T) {
	s, driver := privacyFixture(t)
	if driver.calls != 0 {
		t.Fatal("constructor started privacy")
	}
	if err := s.store.SetMachinePrivacyRequest(store.MachinePrivacyRequest{BootID: "boot-one", Enabled: true}); err != nil {
		t.Fatal(err)
	}
	s.restorePrivacy(t.Context())
	if driver.calls != 1 {
		t.Fatal("same boot was not restored")
	}
	driver.value.Requested = false
	driver.value.State = dieterv1.MachinePrivacy_STATE_OFF
	s.privacyBootID = func(context.Context) (string, error) { return "boot-two", nil }
	s.restorePrivacy(t.Context())
	if driver.calls != 1 {
		t.Fatal("reboot restored privacy")
	}
	s.privacyReadAt = time.Time{}
	if s.privacyState(t.Context()).Requested {
		t.Fatal("reboot retained request")
	}
}
func TestPrivacyRecoveryAdoptsDegradedOwnerWithoutReacquiring(t *testing.T) {
	s, driver := privacyFixture(t)
	if err := s.store.SetMachinePrivacyRequest(store.MachinePrivacyRequest{BootID: "boot-one", Enabled: true}); err != nil {
		t.Fatal(err)
	}
	driver.value = &dieterv1.MachinePrivacy{Requested: true, State: dieterv1.MachinePrivacy_STATE_DEGRADED, Reason: "privileged helper restarted"}
	s.restorePrivacy(t.Context())
	value := s.privacyState(t.Context())
	if driver.calls != 0 || value.GetState() != dieterv1.MachinePrivacy_STATE_DEGRADED || value.GetReason() != driver.value.GetReason() {
		t.Fatalf("recovery reacquired protection: calls=%d state=%v", driver.calls, value)
	}
	_, err := (&grpcAPI{server: s}).PerformMachineOperation(t.Context(), &dieterv1.MachineOperationRequest{Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_PRIVACY_ON})
	if err != nil || driver.calls != 1 || driver.value.GetState() != dieterv1.MachinePrivacy_STATE_ON {
		t.Fatalf("explicit recovery: calls=%d state=%v error=%v", driver.calls, driver.value, err)
	}
}
func TestPrivacyUncertainMutationRetainsIntent(t *testing.T) {
	s, driver := privacyFixture(t)
	driver.failure = errors.New("lost native acknowledgement")
	_, err := (&grpcAPI{server: s}).PerformMachineOperation(t.Context(), &dieterv1.MachineOperationRequest{Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_PRIVACY_ON})
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("error=%v", err)
	}
	value := s.privacyState(t.Context())
	if !value.Requested || value.State != dieterv1.MachinePrivacy_STATE_DEGRADED {
		t.Fatalf("uncertain lock=%v", value)
	}
}
func TestPrivacyChangeStreamInitialAndLiveWithoutTelemetry(t *testing.T) {
	s, _ := privacyFixture(t)
	api := &grpcAPI{server: s}
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{})
	initial := untilCaughtUp(t, frames)
	found := false
	for _, frame := range initial {
		if frame.Privacy != nil {
			found = true
			if frame.Privacy.Requested {
				t.Fatal("initial requested")
			}
		}
	}
	if !found {
		t.Fatal("initial snapshot omitted privacy")
	}
	if _, err := api.PerformMachineOperation(t.Context(), &dieterv1.MachineOperationRequest{Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_PRIVACY_ON}); err != nil {
		t.Fatal(err)
	}
	deadline := time.After(5 * time.Second)
	for {
		select {
		case frame := <-frames:
			if frame.Privacy.GetState() == dieterv1.MachinePrivacy_STATE_ON {
				return
			}
		case <-deadline:
			t.Fatal("privacy did not update the owner stream")
		}
	}
}
