package schema

import (
	"encoding/json"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

func TestRetainedCommentCountValidation(t *testing.T) {
	t.Parallel()
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
			r := crdt.Record{Kind: "item", ID: "card.summary", Versions: []crdt.Version{{Clock: crdt.Clock{"owner": 1}, Value: json.RawMessage(test.value)}}}
			before := r.Revision()
			if err := Validate(r); (err == nil) != test.valid {
				t.Fatalf("valid=%v: %v", test.valid, err)
			}
			if r.Revision() != before {
				t.Fatal("validation rewrote retained signed data")
			}
		})
	}
}
