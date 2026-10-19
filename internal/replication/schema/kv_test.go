package schema

import (
	"encoding/json"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

func TestInboxPinRequiresBoolean(t *testing.T) {
	t.Parallel()
	for _, value := range []string{"true", "false", "null", `"true"`, "1", "{}"} {
		t.Run(value, func(t *testing.T) {
			t.Parallel()
			record := crdt.Record{Kind: "kv.navigation", ID: "inbox-pin.c1.pinned", Versions: []crdt.Version{{Value: json.RawMessage(value)}}}
			err := ValidateKV(record)
			valid := value == "true" || value == "false"
			if (err == nil) != valid {
				t.Fatalf("value %s: error = %v", value, err)
			}
		})
	}
}
