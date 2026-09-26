package compatibility

import "testing"

func TestNormalizeAndCompare(t *testing.T) {
	if got, err := Normalize(" v0.4.128-dev.4369+de14862b "); err != nil || got != "0.4.128-dev.4369+de14862b" {
		t.Fatalf("normalize=%q error=%v", got, err)
	}
	tests := []struct {
		left, right string
		want        int
	}{
		{"0.4.127", "0.4.127", 0},
		{"0.4.128", "0.4.127", 1},
		{"0.4.127", "0.4.128", -1},
		{"0.4.128-dev.4369", "0.4.128-dev.4370", -1},
		{"0.4.128-dev.4370", "0.4.128", -1},
		{"v1.0.0+one", "1.0.0+two", 0},
		{"1.0.0-1", "1.0.0-alpha", -1},
	}
	for _, test := range tests {
		got, err := Compare(test.left, test.right)
		if err != nil || got != test.want {
			t.Errorf("Compare(%q, %q)=%d,%v want %d", test.left, test.right, got, err, test.want)
		}
	}
}

func TestRejectsInvalidVersions(t *testing.T) {
	for _, value := range []string{"", "1", "1.2", "01.2.3", "1.02.3", "1.2.03", "1.2.3-01", "1.2.3+", "1.2.3 nope", "test"} {
		if _, err := Normalize(value); err == nil {
			t.Errorf("Normalize(%q) succeeded", value)
		}
	}
}

func TestPolicyRevisionAndEvaluation(t *testing.T) {
	policy, err := NewPolicy("https://gateway.example", "v0.4.130", "0.4.128", "0.4.129")
	if err != nil || policy.GatewayReleaseVersion != "0.4.130" || len(policy.Revision) != 64 {
		t.Fatalf("policy=%+v error=%v", policy, err)
	}
	newGateway, err := NewPolicy("https://gateway.example", "0.4.131", "0.4.128", "0.4.129")
	if err != nil || newGateway.Revision != policy.Revision {
		t.Fatalf("gateway-only release changed policy revision: %+v error=%v", newGateway, err)
	}
	if status, _ := Evaluate("0.4.127", policy.MinimumClientVersion); status != StatusUpdateRequired {
		t.Fatalf("status=%v", status)
	}
	if status, normalized := Evaluate("v0.4.129", policy.MinimumClientVersion); status != StatusCompatible || normalized != "0.4.129" {
		t.Fatalf("status=%v normalized=%q", status, normalized)
	}
	if status, _ := Evaluate("development", policy.MinimumClientVersion); status != StatusInvalidVersion {
		t.Fatalf("status=%v", status)
	}
}
