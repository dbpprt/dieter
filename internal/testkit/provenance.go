package testkit

import (
	"crypto/ed25519"
	"fmt"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

// SignedCheckout is daemon owner's registration of checkout id, signed with
// key for account.
func SignedCheckout(tb testing.TB, account, id, owner string, key ed25519.PrivateKey) crdt.Record {
	tb.Helper()
	value := fmt.Sprintf(`{"id":%q,"projectId":"p_shared","daemonId":%q,"name":"shared","detached":false}`, id, owner)
	record, err := crdt.Put(crdt.Record{}, "checkout", id+".registration", "actor_owner", "", []byte(value), false)
	if err != nil {
		tb.Fatal(err)
	}
	record.Versions[0] = crdt.SignOwnerVersion(account, record, record.Versions[0], owner, key)
	return record
}
