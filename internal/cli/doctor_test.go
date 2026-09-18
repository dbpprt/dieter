package cli

import "testing"

func TestNodeVersionSupported(t *testing.T) {
	for _, value := range []string{"v22.19.0", "22.20.1", "v23.0.0"} {
		if err := nodeVersionSupported(value); err != nil {
			t.Errorf("nodeVersionSupported(%q): %v", value, err)
		}
	}
	for _, value := range []string{"v22.18.0", "v21.99.0", "not-a-version"} {
		if err := nodeVersionSupported(value); err == nil {
			t.Errorf("nodeVersionSupported(%q) unexpectedly succeeded", value)
		}
	}
}
