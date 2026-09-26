package server

import (
	"testing"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/store"
)

func TestDaemonRejectsClientBelowPersistedGatewayFloor(t *testing.T) {
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	if err := data.SaveGatewayCompatibilityPolicy(store.GatewayCompatibilityPolicy{
		GatewayReleaseVersion: "0.4.310", MinimumClientVersion: "0.4.309",
		MinimumDaemonVersion: "0.4.308", Revision: "policy-revision",
	}); err != nil {
		t.Fatal(err)
	}
	interceptor := clientCompatibilityInterceptor{store: data}
	if err := interceptor.check(dieterv1connect.DieterServiceHealthProcedure, ""); err != nil {
		t.Fatalf("health bootstrap rejected: %v", err)
	}
	if err := interceptor.check(dieterv1connect.DieterServiceGetStateProcedure, "0.4.309"); err != nil {
		t.Fatalf("current client rejected: %v", err)
	}
	for name, release := range map[string]string{"outdated": "0.4.308", "missing": "", "invalid": "development"} {
		t.Run(name, func(t *testing.T) {
			if err := interceptor.check(dieterv1connect.DieterServiceGetStateProcedure, release); connect.CodeOf(err) != connect.CodeFailedPrecondition {
				t.Fatalf("error=%v code=%v", err, connect.CodeOf(err))
			}
		})
	}
}
