package cli

import (
	"strings"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func TestCreationCheckoutDefaultsToTargetMachine(t *testing.T) {
	project := &dieterv1.Project{
		Id: "p_shared", Name: "Shared",
		Checkouts: []*dieterv1.Checkout{
			{Id: "co_remote", DaemonId: "remote"},
			{Id: "co_detached", DaemonId: "local", Path: "/detached", Detached: true},
			{Id: "co_local", DaemonId: "local", Path: "/local/repo"},
		},
	}

	got, err := creationCheckoutID(project, "")
	if err != nil || got != "co_local" {
		t.Fatalf("default checkout=%q err=%v", got, err)
	}
	got, err = creationCheckoutID(project, " co_local ")
	if err != nil || got != "co_local" {
		t.Fatalf("explicit local checkout=%q err=%v", got, err)
	}
	if _, err = creationCheckoutID(project, "co_remote"); err == nil || !strings.Contains(err.Error(), "global --machine") {
		t.Fatalf("remote checkout error=%v", err)
	}
}

func TestCreationCheckoutRequiresTargetMachineCheckout(t *testing.T) {
	project := &dieterv1.Project{Id: "p_remote", Name: "Remote only", Checkouts: []*dieterv1.Checkout{{Id: "co_remote", DaemonId: "remote"}}}
	if _, err := creationCheckoutID(project, ""); err == nil || !strings.Contains(err.Error(), "no checkout on the target machine") {
		t.Fatalf("missing local checkout error=%v", err)
	}
}

func TestCreationCheckoutRequiresDisambiguationOnTargetMachine(t *testing.T) {
	project := &dieterv1.Project{
		Id: "p_local", Name: "Two local checkouts",
		Checkouts: []*dieterv1.Checkout{
			{Id: "co_first", DaemonId: "local", Path: "/first"},
			{Id: "co_second", DaemonId: "local", Path: "/second"},
		},
	}
	if _, err := creationCheckoutID(project, ""); err == nil || !strings.Contains(err.Error(), "pass --checkout") {
		t.Fatalf("ambiguous local checkout error=%v", err)
	}
	got, err := creationCheckoutID(project, "co_second")
	if err != nil || got != "co_second" {
		t.Fatalf("selected checkout=%q err=%v", got, err)
	}
}
