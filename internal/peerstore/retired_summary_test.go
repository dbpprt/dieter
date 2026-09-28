package peerstore

import (
	"encoding/json"
	"testing"
)

func TestRetainedCommentCountValidation(t *testing.T) {
	for _, test := range []struct {
		value string
		valid bool
	}{
		{`{"commentCount":0}`, true}, {`{"commentCount":42}`, true},
		{`{"commentCount":-1}`, false}, {`{"commentCount":1.5}`, false},
		{`{"commentCount":"0"}`, false}, {`{"commentCount":null}`, false},
		{`{"commentCount":9223372036854775808}`, false}, {`{"unknown":0}`, false},
	} {
		t.Run(test.value, func(t *testing.T) {
			r := Record{Kind: "item", ID: "card.summary", Versions: []Version{{Clock: Clock{"owner": 1}, Value: json.RawMessage(test.value)}}}
			before := r.Revision()
			if err := ValidateSettings(r); (err == nil) != test.valid {
				t.Fatalf("valid=%v: %v", test.valid, err)
			}
			if r.Revision() != before {
				t.Fatal("validation rewrote retained signed data")
			}
		})
	}
}
