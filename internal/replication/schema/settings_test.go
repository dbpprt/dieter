package schema

import (
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

func TestRejectNonportableSettings(t *testing.T) {
	t.Parallel()
	for _, value := range []string{`{"path":"/private"}`, `{"credentials":"secret"}`, `{"hostnames":["https://user:pass@host"]}`, `null`, `{"name":null}`} {
		record, err := crdt.Put(crdt.Record{}, "project-settings", "project", "a", "", []byte(value), false)
		if err != nil {
			t.Fatal(err)
		}
		if Validate(record) == nil {
			t.Fatalf("accepted %s", value)
		}
	}
}
