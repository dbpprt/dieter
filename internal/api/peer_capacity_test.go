package api

import (
	"fmt"
	"strings"
	"testing"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/testkit"
	"google.golang.org/protobuf/proto"
)

func TestKVRetainedPagesBoundWireBytesAndResumeAcrossNativeAdapter(t *testing.T) {
	t.Parallel()
	s := testkit.Store(t)
	defer s.Close()
	identity, err := s.Replica.EnsureIdentity()
	if err != nil {
		t.Fatal(err)
	}
	for start := 0; start < 100; start += 50 {
		var records []crdt.Record
		for i := start; i < start+50; i++ {
			r, err := crdt.Put(crdt.Record{}, "kv.retained", fmt.Sprintf("key_%03d", i), "old_actor", "", []byte(`"`+strings.Repeat("x", 30000)+`"`), false)
			if err != nil {
				t.Fatal(err)
			}
			records = append(records, r)
		}
		if err = s.Replica.MergePeerRecords(identity, records); err != nil {
			t.Fatal(err)
		}
	}
	client, _ := newConnectTestClient(t, s, newFakeRunner())
	request := &dieterv1.KVListRequest{Namespace: "retained", Prefix: "key_"}
	seen := map[string]bool{}
	for page := 0; page < 10; page++ {
		response, err := client.ListKV(t.Context(), request)
		if err != nil {
			t.Fatal(err)
		}
		if size := proto.Size(response); size > crdt.MaxPageBytes {
			t.Fatalf("KV page exceeds wire budget: %d", size)
		}
		if len(response.Entries) > crdt.PageSize {
			t.Fatal("KV page exceeds count budget")
		}
		for _, entry := range response.Entries {
			if seen[entry.Key] {
				t.Fatal("duplicate continuation")
			}
			seen[entry.Key] = true
		}
		if response.NextKey == "" {
			break
		}
		request.AfterKey = response.NextKey
		request.Snapshot = response.Cursor
	}
	if len(seen) != 100 {
		t.Fatalf("pagination lost records: %d", len(seen))
	}
	// Cursors remain tied to the complete replica projection, not page arrival.
	if _, err = s.Replica.PutPeerRecord(identity, "kv.retained", "key_new", "", []byte(`true`), false); err != nil {
		t.Fatal(err)
	}
	if _, err = client.ListKV(t.Context(), request); connect.CodeOf(err) != connect.CodeAborted {
		t.Fatalf("stale snapshot accepted: %v", err)
	}
}
