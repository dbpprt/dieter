package channels_test

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/channels"
	"github.com/dbpprt/dieter/internal/store/home"
)

func newStore(t *testing.T) (*channels.Store, string) {
	t.Helper()
	root := t.TempDir()
	dir := home.New(root)
	if err := os.MkdirAll(dir.SyncDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	return channels.New(dir), root
}

func agent(card string) model.ChannelAuthor {
	return model.ChannelAuthor{Kind: model.ChannelAuthorAgent, CardID: card, Title: "Card " + card}
}

func TestPostsOrderDeduplicateAndThread(t *testing.T) {
	store, _ := newStore(t)
	first, created, err := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "note", Author: agent("c_a"), Body: "hello"}, "op_1")
	if err != nil || !created || first.Seq != 1 || first.ID == "" {
		t.Fatalf("first post = %+v, %v, %v", first, created, err)
	}
	again, created, err := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "note", Author: agent("c_a"), Body: "hello"}, "op_1")
	if err != nil || created || again.ID != first.ID {
		t.Fatalf("retried post = %+v, %v, %v; want the original", again, created, err)
	}
	reply, _, err := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "note", Author: agent("c_b"), Body: "re", ThreadID: first.ID}, "")
	if err != nil || reply.Seq != 2 || reply.ThreadID != first.ID {
		t.Fatalf("reply = %+v, %v", reply, err)
	}
	nested, _, err := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "note", Author: agent("c_a"), Body: "re re", ThreadID: reply.ID}, "")
	if err != nil || nested.ThreadID != first.ID {
		t.Fatalf("a reply to a reply must attach to the root: %+v, %v", nested, err)
	}
	if _, _, err := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "note", Author: agent("c_a"), Body: "x", ThreadID: "m_missing"}, ""); err == nil {
		t.Fatal("a reply to an unknown thread was accepted")
	}
	root, err := store.Message("p_1", first.ID)
	if err != nil || root.ReplyCount != 2 {
		t.Fatalf("root = %+v, %v; want 2 replies", root, err)
	}
	thread, _, _, err := store.Page("p_1", 0, 0, 0, first.ID)
	if err != nil || len(thread) != 3 {
		t.Fatalf("thread page = %d messages, %v", len(thread), err)
	}
}

func TestDeliveriesAndUndeliveredFilterAddressees(t *testing.T) {
	store, _ := newStore(t)
	broadcast, _, _ := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "note", Author: agent("c_a"), Body: "all"}, "")
	direct, _, _ := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "request", Author: agent("c_a"), To: []string{"c_c"}, Body: "only c"}, "")
	pending, err := store.Undelivered("p_1", "c_b", "")
	if err != nil || len(pending) != 1 || pending[0].ID != broadcast.ID {
		t.Fatalf("c_b pending = %+v, %v; want only the broadcast", pending, err)
	}
	if own, _ := store.Undelivered("p_1", "c_a", ""); len(own) != 0 {
		t.Fatalf("an author received its own messages: %+v", own)
	}
	pending, _ = store.Undelivered("p_1", "c_c", "")
	if len(pending) != 2 {
		t.Fatalf("c_c pending = %d, want 2", len(pending))
	}
	if err := store.Deliver("p_1", "c_c", model.ChannelDeliverySteered, []string{broadcast.ID, direct.ID}); err != nil {
		t.Fatal(err)
	}
	if pending, _ = store.Undelivered("p_1", "c_c", ""); len(pending) != 0 {
		t.Fatalf("delivered messages are still pending: %+v", pending)
	}
	message, _ := store.Message("p_1", direct.ID)
	if len(message.Deliveries) != 1 || message.Deliveries[0].Mode != model.ChannelDeliverySteered {
		t.Fatalf("deliveries = %+v", message.Deliveries)
	}
	if later, _ := store.Undelivered("p_1", "c_b", "9999"); len(later) != 0 {
		t.Fatalf("since did not exclude older messages: %+v", later)
	}
}

func TestReloadPinsSeenAndTornLine(t *testing.T) {
	store, root := newStore(t)
	first, _, _ := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "decision", Author: agent("c_a"), Body: "keep it pure"}, "")
	if _, err := store.Pin("p_1", first.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "note", Author: model.ChannelAuthor{Kind: model.ChannelAuthorHuman}, Body: "ok"}, ""); err != nil {
		t.Fatal(err)
	}
	// A torn final line (crash mid-append) is ignored on reload.
	path := filepath.Join(root, "channels", "p_1", "events.ndjson")
	file, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	_, _ = file.WriteString(`{"type":"post","message":{"id":"m_torn"`)
	_ = file.Close()
	reloaded := channels.New(home.New(root))
	message, err := reloaded.Message("p_1", first.ID)
	if err != nil || !message.Pinned {
		t.Fatalf("pin lost on reload: %+v, %v", message, err)
	}
	if _, err := reloaded.Message("p_1", "m_torn"); err == nil {
		t.Fatal("torn line became a message")
	}
	seen, unread, err := reloaded.Unread("p_1")
	if err != nil || seen != 0 || unread != 1 {
		t.Fatalf("unread = %d after %d, %v; want 1 agent message (humans do not count)", unread, seen, err)
	}
	if err := reloaded.MarkSeen("p_1", 2); err != nil {
		t.Fatal(err)
	}
	if err := reloaded.MarkSeen("p_1", 1); err != nil {
		t.Fatal(err)
	}
	if seen, unread, _ = reloaded.Unread("p_1"); seen != 2 || unread != 0 {
		t.Fatalf("seen = %d unread = %d; want 2, 0 (never backwards)", seen, unread)
	}
	projects, _ := reloaded.Projects()
	if len(projects) != 1 || projects[0] != "p_1" {
		t.Fatalf("projects = %v", projects)
	}
	if _, _, err := reloaded.Post(model.ChannelMessage{ProjectID: "../escape", Author: agent("c_a"), Body: "x"}, ""); err == nil {
		t.Fatal("an invalid project ID was accepted")
	}
}

func TestCompactionKeepsNewestAndPinned(t *testing.T) {
	const retain, compact = 20, 60
	defer channels.SetRetention(retain, compact)()
	store, root := newStore(t)
	pinned, _, _ := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "decision", Author: agent("c_a"), Body: "pinned decision"}, "")
	if _, err := store.Pin("p_1", pinned.ID, true); err != nil {
		t.Fatal(err)
	}
	// Each post plus delivery is two lines; cross the compaction threshold.
	for i := 0; i < compact/2+10; i++ {
		message, _, err := store.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "note", Author: agent("c_a"), Body: fmt.Sprintf("n%d", i)}, "")
		if err != nil {
			t.Fatal(err)
		}
		if err := store.Deliver("p_1", "c_b", model.ChannelDeliveryDigest, []string{message.ID}); err != nil {
			t.Fatal(err)
		}
	}
	raw, _ := os.ReadFile(filepath.Join(root, "channels", "p_1", "events.ndjson"))
	if lines := strings.Count(string(raw), "\n"); lines >= compact {
		t.Fatalf("log has %d lines; compaction did not run", lines)
	}
	reloaded := channels.New(home.New(root))
	page, last, _, err := reloaded.Page("p_1", 0, 0, 200, "")
	if err != nil || last != int64(compact/2+11) || len(page) >= compact/2+11 {
		t.Fatalf("last seq = %d, %v", last, err)
	}
	if page[len(page)-1].Deliveries[0].CardID != "c_b" {
		t.Fatalf("deliveries lost in compaction: %+v", page[len(page)-1])
	}
	message, err := reloaded.Message("p_1", pinned.ID)
	if err != nil || !message.Pinned {
		t.Fatalf("pinned message dropped by compaction: %+v, %v", message, err)
	}
	next, _, err := reloaded.Post(model.ChannelMessage{ProjectID: "p_1", Kind: "note", Author: agent("c_a"), Body: "after"}, "")
	if err != nil || next.Seq != last+1 {
		t.Fatalf("post after compaction = %+v, %v", next, err)
	}
}
