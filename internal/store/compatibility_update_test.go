package store

import "testing"

func TestCompatibilityUpdateReceiptAdmitsOncePerKey(t *testing.T) {
	value := New(t.TempDir())
	receipt := CompatibilityUpdateReceipt{Key: "one", GatewayIssuer: "gateway", PolicyRevision: "policy", InstalledVersion: "0.4.1", MinimumDaemonVersion: "0.4.2"}
	if admitted, err := value.BeginCompatibilityUpdate(receipt); err != nil || !admitted {
		t.Fatalf("first admission=%v error=%v", admitted, err)
	}
	if admitted, err := value.BeginCompatibilityUpdate(receipt); err != nil || admitted {
		t.Fatalf("duplicate admission=%v error=%v", admitted, err)
	}
	if err := value.FinishCompatibilityUpdate("one", "failed", "release unavailable"); err != nil {
		t.Fatal(err)
	}
	stored, err := value.CompatibilityUpdateReceipt()
	if err != nil || stored.Outcome != "failed" || stored.Error != "release unavailable" {
		t.Fatalf("stored=%+v error=%v", stored, err)
	}
	receipt.Key = "two"
	if admitted, err := value.BeginCompatibilityUpdate(receipt); err != nil || !admitted {
		t.Fatalf("new policy admission=%v error=%v", admitted, err)
	}
}
