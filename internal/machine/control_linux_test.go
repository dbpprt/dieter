//go:build linux

package machine

import "testing"

func TestParseBusctlString(t *testing.T) {
	for _, test := range []struct {
		input string
		want  string
		fail  bool
	}{
		{`s "yes"`, "yes", false},
		{"s \"challenge\"\n", "challenge", false},
		{`s "no"`, "no", false},
		{`b true`, "", true},
		{`s yes`, "", true},
	} {
		got, err := parseBusctlString([]byte(test.input))
		if (err != nil) != test.fail || got != test.want {
			t.Fatalf("parseBusctlString(%q) = %q, %v", test.input, got, err)
		}
	}
}
