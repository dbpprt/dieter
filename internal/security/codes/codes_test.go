package codes

import (
	"bytes"
	"strings"
	"testing"
)

func TestRoundTripAcceptsTypedForms(t *testing.T) {
	t.Parallel()
	for _, value := range [][]byte{{}, {0}, {0xff}, []byte("dieter"), bytes.Repeat([]byte{0xa5}, 33)} {
		encoded := Encode(value)
		for _, typed := range []string{encoded, strings.ToLower(encoded), Group(encoded, 4)} {
			decoded, err := Decode(typed)
			if err != nil || !bytes.Equal(decoded, value) {
				t.Fatalf("Decode(%q) = %x, %v; want %x", typed, decoded, err, value)
			}
		}
	}
	decoded, err := Decode("oil")
	if want, _ := Decode("011"); err != nil || !bytes.Equal(decoded, want) {
		t.Fatal("confusable characters were not normalized")
	}
	if _, err := Decode("U"); err == nil {
		t.Fatal("a character outside the alphabet was accepted")
	}
}

func TestSameIgnoresCaseAndSeparators(t *testing.T) {
	t.Parallel()
	if !Same("ABCD-EFGH", "abcd efgh") || !Same("0011", "OoIl") || Same("ABCD-EFGH", "ABCD-EFGJ") {
		t.Fatal("Same compared codes incorrectly")
	}
}
