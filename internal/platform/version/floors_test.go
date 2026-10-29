package version

import "testing"

func TestFloorsCompareReleasesNotBuildMetadata(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		current, minimum string
		want             Status
	}{
		{"0.4.309", "0.4.309", StatusCompatible},
		{"v0.4.309", "0.4.309", StatusCompatible},
		{"0.4.309+de14862b", "0.4.309", StatusCompatible},
		{"0.4.310-dev.1", "0.4.309", StatusCompatible},
		{"1.0.0", "0.9.99", StatusCompatible},
		{"0.0.0-dev.0", DevelopmentMinimum, StatusCompatible},
		{"0.0.1", DevelopmentMinimum, StatusCompatible},
		// A development build of the floor's release predates that release.
		{"0.4.309-dev.4370", "0.4.309", StatusUpdateRequired},
		{"0.4.309-dev.4370", "0.4.309-dev.4371", StatusUpdateRequired},
		{"0.4.308", "0.4.309", StatusUpdateRequired},
		{"0.3.999", "0.4.0", StatusUpdateRequired},
		{"", "0.4.309", StatusInvalidVersion},
		{"development", "0.4.309", StatusInvalidVersion},
		{"0.4.309", "latest", StatusInvalidVersion},
	} {
		if got, _ := Evaluate(test.current, test.minimum); got != test.want {
			t.Errorf("Evaluate(%q, %q)=%v want %v", test.current, test.minimum, got, test.want)
		}
	}
	if _, normalized := Evaluate(" v0.4.309 ", "latest"); normalized != "0.4.309" {
		t.Fatalf("an invalid floor dropped the normalized installed release: %q", normalized)
	}
}

func TestPolicyRevisionTracksFloorsAndIssuer(t *testing.T) {
	t.Parallel()
	base, err := NewPolicy("https://gateway.example", "0.5.0", "0.4.1", "0.4.2")
	if err != nil {
		t.Fatal(err)
	}
	same, err := NewPolicy("https://gateway.example", "v0.5.1", "v0.4.1", "0.4.2")
	if err != nil || same.Revision != base.Revision || same.MinimumClientVersion != "0.4.1" {
		t.Fatalf("normalization or a gateway-only release changed the policy: %+v %v", same, err)
	}
	for name, inputs := range map[string][4]string{
		"issuer":       {"https://other.example", "0.5.0", "0.4.1", "0.4.2"},
		"client floor": {"https://gateway.example", "0.5.0", "0.4.2", "0.4.2"},
		"daemon floor": {"https://gateway.example", "0.5.0", "0.4.1", "0.4.3"},
	} {
		changed, err := NewPolicy(inputs[0], inputs[1], inputs[2], inputs[3])
		if err != nil || changed.Revision == base.Revision {
			t.Errorf("%s: revision did not change: %+v %v", name, changed, err)
		}
	}
	for _, floors := range [][3]string{{"latest", "0.4.1", "0.4.2"}, {"0.5.0", "", "0.4.2"}, {"0.5.0", "0.4.1", "0.4"}} {
		if _, err := NewPolicy("https://gateway.example", floors[0], floors[1], floors[2]); err == nil {
			t.Errorf("NewPolicy accepted %q", floors)
		}
	}
	key := UpdateAttemptKey("https://gateway.example", base.Revision, "0.4.1", "0.4.2")
	if key != UpdateAttemptKey("https://gateway.example", base.Revision, "0.4.1", "0.4.2") || len(key) != 64 {
		t.Fatalf("update attempt key is not stable: %q", key)
	}
	for _, other := range []string{
		UpdateAttemptKey("https://other.example", base.Revision, "0.4.1", "0.4.2"),
		UpdateAttemptKey("https://gateway.example", "revision", "0.4.1", "0.4.2"),
		UpdateAttemptKey("https://gateway.example", base.Revision, "0.4.0", "0.4.2"),
		UpdateAttemptKey("https://gateway.example", base.Revision, "0.4.1", "0.4.3"),
	} {
		if other == key {
			t.Fatal("update attempt key ignores an input")
		}
	}
}
