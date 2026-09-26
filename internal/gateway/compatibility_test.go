package gateway

import (
	"context"
	"testing"

	"github.com/dbpprt/dieter/internal/buildinfo"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func TestCompatibilityBootstrapEvaluatesClientAndDaemonFloors(t *testing.T) {
	previous := buildinfo.ReleaseVersion
	buildinfo.ReleaseVersion = "0.4.310"
	t.Cleanup(func() { buildinfo.ReleaseVersion = previous })

	config := Config{MinimumClientVersion: "0.4.309", MinimumDaemonVersion: "0.4.308"}
	service := NewService(nil, nil, nil, nil, config)
	for _, test := range []struct {
		name      string
		component gatewayv1.CompatibilityComponent
		release   string
		want      gatewayv1.CompatibilityStatus
		minimum   string
	}{
		{"client below", gatewayv1.CompatibilityComponent_COMPATIBILITY_COMPONENT_CLIENT, "0.4.308", gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_UPDATE_REQUIRED, "0.4.309"},
		{"client current", gatewayv1.CompatibilityComponent_COMPATIBILITY_COMPONENT_CLIENT, "v0.4.309", gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE, "0.4.309"},
		{"daemon below", gatewayv1.CompatibilityComponent_COMPATIBILITY_COMPONENT_DAEMON, "0.4.307", gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_UPDATE_REQUIRED, "0.4.308"},
		{"invalid", gatewayv1.CompatibilityComponent_COMPATIBILITY_COMPONENT_CLIENT, "development", gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_INVALID_VERSION, "0.4.309"},
	} {
		t.Run(test.name, func(t *testing.T) {
			response, err := service.GetCompatibility(context.Background(), &gatewayv1.CompatibilityRequest{
				ReleaseVersion: test.release, Component: test.component,
			})
			if err != nil || response.GetStatus() != test.want || response.GetMinimumReleaseVersion() != test.minimum {
				t.Fatalf("response=%#v error=%v", response, err)
			}
			if policy := response.GetPolicy(); policy.GetGatewayReleaseVersion() != "0.4.310" || policy.GetRevision() == "" {
				t.Fatalf("policy=%#v", policy)
			}
		})
	}
}

func TestGatewayRejectsClientBelowPublishedFloor(t *testing.T) {
	auth := NewAuth(Config{MinimumClientVersion: "0.4.309", MinimumDaemonVersion: "0.4.308"}, nil, nil)
	compatible := metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-dieter-client-version", "0.4.309"))
	if err := auth.requireCompatibleClient(compatible); err != nil {
		t.Fatalf("current client rejected: %v", err)
	}

	for name, release := range map[string]string{"outdated": "0.4.308", "missing": "", "invalid": "development"} {
		t.Run(name, func(t *testing.T) {
			ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-dieter-client-version", release))
			err := auth.requireCompatibleClient(ctx)
			if status.Code(err) != codes.FailedPrecondition {
				t.Fatalf("error=%v code=%v", err, status.Code(err))
			}
			value := status.Convert(err)
			found := false
			for _, detail := range value.Details() {
				if info, ok := detail.(*errdetails.ErrorInfo); ok && info.GetReason() == "CLIENT_UPDATE_REQUIRED" && info.GetMetadata()["minimumVersion"] == "0.4.309" {
					found = true
				}
			}
			if !found {
				t.Fatalf("missing structured update detail: %v", value.Details())
			}
		})
	}
}
