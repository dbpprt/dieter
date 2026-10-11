package daemonstate

import (
	"testing"

	"github.com/dbpprt/dieter/internal/store"
)

func TestGatewayCompatibilityPolicyPersists(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	first := New(store.New(root))
	want := GatewayCompatibilityPolicy{GatewayReleaseVersion: "0.4.3", MinimumClientVersion: "0.4.1", MinimumDaemonVersion: "0.4.2", Revision: "revision"}
	if err := first.SaveGatewayCompatibilityPolicy(want); err != nil {
		t.Fatal(err)
	}
	got, err := New(store.New(root)).GatewayCompatibilityPolicy()
	if err != nil || got != want {
		t.Fatalf("policy=%+v error=%v", got, err)
	}
}
