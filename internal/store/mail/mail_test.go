package mail_test

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/mail"
)

func newStore(t *testing.T, root string) *mail.Store {
	t.Helper()
	dir := home.New(root)
	if err := os.MkdirAll(dir.SyncDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	return mail.New(dir)
}

func agent(card, turn string) model.MailSender {
	return model.MailSender{Kind: model.MailSenderAgent, CardID: card, TurnID: turn, Title: "Card " + card}
}

func operator() model.MailSender { return model.MailSender{Kind: model.MailSenderOperator} }

func send(t *testing.T, store *mail.Store, draft mail.Draft) model.MailHeader {
	t.Helper()
	if draft.Body == "" {
		draft.Body = "A report."
	}
	if draft.Subject == "" {
		draft.Subject = "Report"
	}
	header, created, err := store.Send(draft)
	if err != nil || !created {
		t.Fatalf("send %q = %v, %v", draft.Subject, created, err)
	}
	return header
}

func wantKind(t *testing.T, err error, kind fault.Kind, context string) {
	t.Helper()
	if got, ok := fault.KindOf(err); !ok || got != kind {
		t.Fatalf("%s: err = %v, want %s", context, err, kind)
	}
}

func ids(headers []model.MailHeader) []string {
	result := make([]string, len(headers))
	for index, header := range headers {
		result[index] = header.ID
	}
	return result
}

func TestSendNormalizesValidatesAndStoresBodySeparately(t *testing.T) {
	root := t.TempDir()
	store := newStore(t, root)
	header := send(t, store, mail.Draft{Sender: operator(), Subject: "  Nightly\naudit:\t3 critical\u202e  ", Body: "## Summary\r\n\r\nThree **critical** advisories.\r\n", Important: true})
	if header.Subject != "Nightly audit: 3 critical" || header.Preview != "Three critical advisories." || header.Importance != model.MailImportanceHigh {
		t.Fatalf("header = %+v", header)
	}
	if header.Folder != model.MailFolderInbox || header.Read || header.Flagged || !strings.HasPrefix(header.ID, "ml_") || len(header.BodyDigest) != 64 {
		t.Fatalf("new message state = %+v", header)
	}
	stored, body, err := store.Get(header.ID)
	if err != nil || body != "## Summary\n\nThree **critical** advisories.\n" || stored.BodyBytes != len(body) {
		t.Fatalf("get = %+v %q %v", stored, body, err)
	}
	for _, name := range []string{header.ID + ".json", header.ID + ".md"} {
		info, err := os.Stat(filepath.Join(root, "mail", name))
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %v %v", name, info, err)
		}
	}
	for name, draft := range map[string]mail.Draft{
		"blank subject":     {Subject: " \n ", Body: "x"},
		"long subject":      {Subject: strings.Repeat("s", model.MailMaxSubjectRunes+1), Body: "x"},
		"blank body":        {Subject: "s", Body: " \n\t"},
		"large body":        {Subject: "s", Body: strings.Repeat("x\n", model.MailMaxBodyBytes/2+1)},
		"too many lines":    {Subject: "s", Body: strings.Repeat("x\n", model.MailMaxBodyLines+1)},
		"long line":         {Subject: "s", Body: strings.Repeat("x", model.MailMaxLineBytes+1)},
		"invalid UTF-8":     {Subject: "s", Body: "\xff"},
		"long operation ID": {Subject: "s", Body: "x", OperationID: strings.Repeat("o", model.MailMaxOperationID+1)},
	} {
		draft.Sender = operator()
		_, _, err := store.Send(draft)
		wantKind(t, err, fault.Invalid, name)
	}
	if _, _, err := store.Send(mail.Draft{Sender: operator(), Subject: "s", Body: strings.Repeat("x\n", model.MailMaxBodyLines)}); err != nil {
		t.Fatalf("a body at the line limit: %v", err)
	}
	if _, _, err := store.Get("ml_missing"); !errors.Is(err, mail.ErrNotFound) {
		t.Fatalf("missing = %v", err)
	}
	if _, _, err := store.Get("../secrets"); !errors.Is(err, mail.ErrNotFound) {
		t.Fatalf("path = %v", err)
	}
}

func TestOperationIDsAreScopedByOrigin(t *testing.T) {
	store := newStore(t, t.TempDir())
	first := send(t, store, mail.Draft{Sender: agent("c_a", "t_1"), OperationID: "op"})
	again, created, err := store.Send(mail.Draft{Sender: agent("c_a", "t_2"), Subject: "Other", Body: "Other", OperationID: "op"})
	if err != nil || created || again.ID != first.ID || again.Subject != "Report" {
		t.Fatalf("retry = %+v %v %v, want the original", again, created, err)
	}
	other := send(t, store, mail.Draft{Sender: agent("c_b", "t_3"), OperationID: "op"})
	local := send(t, store, mail.Draft{Sender: operator(), OperationID: "op"})
	labelled, created, err := store.Send(mail.Draft{Sender: model.MailSender{Kind: model.MailSenderOperator, Label: "backup.sh"}, Subject: "s", Body: "b", OperationID: "op"})
	if err != nil || created || labelled.ID != local.ID {
		t.Fatalf("local retry = %+v %v %v", labelled, created, err)
	}
	device := send(t, store, mail.Draft{Sender: model.MailSender{Kind: model.MailSenderOperator, DeviceID: "dv_1"}, OperationID: "op"})
	if len(slices.Compact(slices.Sorted(slices.Values([]string{first.ID, other.ID, local.ID, device.ID})))) != 4 {
		t.Fatalf("origins shared a message: %s %s %s %s", first.ID, other.ID, local.ID, device.ID)
	}
}

func TestAgentRateBoundsCountStoredMessagesAcrossReopen(t *testing.T) {
	root := t.TempDir()
	store := newStore(t, root)
	now := time.Date(2026, 10, 25, 9, 0, 0, 0, time.UTC)
	mail.SetNow(store, func() time.Time { return now })
	for index := range model.MailMaxPerTurn {
		send(t, store, mail.Draft{Sender: agent("c_a", "t_1"), Subject: fmt.Sprint("Report ", index)})
	}
	_, _, err := store.Send(mail.Draft{Sender: agent("c_a", "t_1"), Subject: "One more", Body: "x"})
	wantKind(t, err, fault.ResourceExhausted, "eleventh in a turn")
	if !strings.Contains(err.Error(), "10") {
		t.Fatalf("the refusal does not name the limit: %v", err)
	}
	// Operators and other conversations are not bound by this turn.
	send(t, store, mail.Draft{Sender: operator()})
	send(t, store, mail.Draft{Sender: agent("c_b", "t_9")})

	reopened := newStore(t, root)
	mail.SetNow(reopened, func() time.Time { return now })
	_, _, err = reopened.Send(mail.Draft{Sender: agent("c_a", "t_1"), Subject: "After restart", Body: "x"})
	wantKind(t, err, fault.ResourceExhausted, "turn bound after reopen")
	// Ten per turn, up to 50 per conversation in any 24 hours.
	for index := model.MailMaxPerTurn; index < model.MailMaxPerConversation; index++ {
		send(t, reopened, mail.Draft{Sender: agent("c_a", fmt.Sprint("t_", 1+index/model.MailMaxPerTurn)), Subject: fmt.Sprint("Report ", index)})
	}
	_, _, err = reopened.Send(mail.Draft{Sender: agent("c_a", "t_new"), Subject: "Over the day", Body: "x"})
	wantKind(t, err, fault.ResourceExhausted, "51st in a day")
	now = now.Add(model.MailConversationWindow + time.Minute)
	send(t, reopened, mail.Draft{Sender: agent("c_a", "t_new")})
}

func TestStoreBoundsPruneTrashThenReadOldestFirst(t *testing.T) {
	restore := mail.SetBounds(6, 1<<20)
	defer restore()
	store := newStore(t, t.TempDir())
	now := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	mail.SetNow(store, func() time.Time { return now })
	at := func(hours int) time.Time { return now.Add(time.Duration(hours) * time.Hour) }
	yes := true
	put := func(subject string, sent time.Time, change mail.Change) model.MailHeader {
		header := send(t, store, mail.Draft{Sender: operator(), Subject: subject, SentAt: sent})
		if change.Read != nil || change.Flagged != nil || change.Folder != "" {
			if _, err := store.Update([]string{header.ID}, change); err != nil {
				t.Fatal(err)
			}
		}
		return header
	}
	unread := put("unread, oldest", at(-10), mail.Change{})
	flagged := put("read and flagged", at(-9), mail.Change{Read: &yes, Flagged: &yes})
	inboxOld := put("read inbox, old", at(-8), mail.Change{Read: &yes})
	archived := put("read archive", at(-1), mail.Change{Read: &yes, Folder: model.MailFolderArchive})
	inboxNew := put("read inbox, new", at(-2), mail.Change{Read: &yes})
	trashed := put("unread trash", at(-3), mail.Change{Folder: model.MailFolderTrash})

	left := func() []string {
		headers, _, err := store.Headers()
		if err != nil {
			t.Fatal(err)
		}
		return ids(headers)
	}
	// Each send over the bound prunes one: Trash, archived read, read Inbox
	// oldest first.
	for index, gone := range []string{trashed.ID, archived.ID, inboxOld.ID, inboxNew.ID} {
		send(t, store, mail.Draft{Sender: operator(), Subject: fmt.Sprint("new ", index)})
		if current := left(); slices.Contains(current, gone) || len(current) != 6 {
			t.Fatalf("after send %d: %v still holds %s", index, current, gone)
		}
	}
	// Only unread and flagged messages are left: the mailbox is full and
	// nothing is pruned.
	before := left()
	_, _, err := store.Send(mail.Draft{Sender: operator(), Subject: "no room", Body: "x"})
	if !errors.Is(err, mail.ErrFull) {
		t.Fatalf("full mailbox = %v", err)
	}
	wantKind(t, err, fault.ResourceExhausted, "full mailbox")
	if after := left(); !slices.Equal(before, after) || !slices.Contains(after, unread.ID) || !slices.Contains(after, flagged.ID) {
		t.Fatalf("a refused send pruned: %v -> %v", before, after)
	}
}

func TestStoreBoundsCountBodyBytes(t *testing.T) {
	restore := mail.SetBounds(100, 1000)
	defer restore()
	store := newStore(t, t.TempDir())
	yes := true
	first := send(t, store, mail.Draft{Sender: operator(), Body: strings.Repeat("a", 600)})
	if _, err := store.Update([]string{first.ID}, mail.Change{Read: &yes}); err != nil {
		t.Fatal(err)
	}
	second := send(t, store, mail.Draft{Sender: operator(), Body: strings.Repeat("b", 600)})
	headers, _, _ := store.Headers()
	if got := ids(headers); !slices.Equal(got, []string{second.ID}) {
		t.Fatalf("headers = %v, want only %s", got, second.ID)
	}
	if _, _, err := store.Send(mail.Draft{Sender: operator(), Subject: "s", Body: strings.Repeat("c", 600)}); !errors.Is(err, mail.ErrFull) {
		t.Fatalf("unread bytes were pruned: %v", err)
	}
}

func TestTrashExpiresAndOrphanBodiesAreRemovedOnLoad(t *testing.T) {
	root := t.TempDir()
	store := newStore(t, root)
	now := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	mail.SetNow(store, func() time.Time { return now })
	trashed := send(t, store, mail.Draft{Sender: operator(), Subject: "trash"})
	kept := send(t, store, mail.Draft{Sender: operator(), Subject: "kept"})
	if _, err := store.Update([]string{trashed.ID}, mail.Change{Folder: model.MailFolderTrash}); err != nil {
		t.Fatal(err)
	}
	now = now.Add(model.MailTrashRetention - time.Hour)
	headers, revision, _ := store.Headers()
	if len(headers) != 2 {
		t.Fatalf("trash expired early: %v", ids(headers))
	}
	now = now.Add(2 * time.Hour)
	headers, after, err := store.Headers()
	if err != nil || !slices.Equal(ids(headers), []string{kept.ID}) {
		t.Fatalf("after 30 days = %v, %v", ids(headers), err)
	}
	if after == revision {
		t.Fatal("the purge did not change the revision")
	}
	for _, name := range []string{trashed.ID + ".json", trashed.ID + ".md"} {
		if _, err := os.Stat(filepath.Join(root, "mail", name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s survived the purge: %v", name, err)
		}
	}

	// A send interrupted between the body and the record leaves a body that
	// the next load removes.
	orphan := filepath.Join(root, "mail", "ml_orphan.md")
	if err := os.WriteFile(orphan, []byte("half sent"), 0o600); err != nil {
		t.Fatal(err)
	}
	reopened := newStore(t, root)
	if headers, _, err := reopened.Headers(); err != nil || !slices.Equal(ids(headers), []string{kept.ID}) {
		t.Fatalf("reopened = %v, %v", ids(headers), err)
	}
	if _, err := os.Stat(orphan); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("orphan body survived the load: %v", err)
	}
	if _, body, err := reopened.Get(kept.ID); err != nil || body != "A report." {
		t.Fatalf("kept body = %q, %v", body, err)
	}
}

func TestRevisionTracksEveryChangeAndOtherProcesses(t *testing.T) {
	root := t.TempDir()
	store := newStore(t, root)
	start, err := store.Revision()
	if err != nil {
		t.Fatal(err)
	}
	header := send(t, store, mail.Draft{Sender: operator()})
	sent, _ := store.Revision()
	yes := true
	if _, err := store.Update([]string{header.ID}, mail.Change{Read: &yes}); err != nil {
		t.Fatal(err)
	}
	read, _ := store.Revision()
	if _, err := store.Update([]string{header.ID}, mail.Change{Read: &yes}); err != nil {
		t.Fatal(err)
	}
	unchanged, _ := store.Revision()
	if !(start < sent && sent < read && read == unchanged) {
		t.Fatalf("revisions %d %d %d %d", start, sent, read, unchanged)
	}
	// Another process (a second handle on the same home) sees the change.
	other := newStore(t, root)
	if headers, _, _ := other.Headers(); len(headers) != 1 || !headers[0].Read {
		t.Fatalf("other handle = %+v", headers)
	}
	if _, err := other.Delete([]string{header.ID, "ml_unknown"}, false); err != nil {
		t.Fatal(err)
	}
	deleted, _ := store.Revision()
	if headers, _, _ := store.Headers(); deleted == unchanged || len(headers) != 0 {
		t.Fatalf("first handle after the other's delete: %d %+v", deleted, headers)
	}
}

func TestListFiltersPagesAndUpdatesState(t *testing.T) {
	store := newStore(t, t.TempDir())
	base := time.Date(2026, 10, 25, 9, 0, 0, 0, time.UTC)
	var all []model.MailHeader
	for index := range 7 {
		all = append(all, send(t, store, mail.Draft{Sender: operator(), Subject: fmt.Sprint("m", index), SentAt: base.Add(time.Duration(index) * time.Minute)}))
	}
	yes, no := true, false
	updated, err := store.Update([]string{all[1].ID, "ml_gone", all[1].ID, all[2].ID}, mail.Change{Read: &yes, Flagged: &yes})
	if err != nil || !slices.Equal(ids(updated), []string{all[1].ID, all[2].ID}) || !updated[0].Read || !updated[0].Flagged || updated[0].StateChangedAt == "" {
		t.Fatalf("update = %+v, %v", updated, err)
	}
	if _, err := store.Update([]string{all[2].ID}, mail.Change{Flagged: &no, Folder: model.MailFolderArchive}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Update([]string{all[3].ID}, mail.Change{Folder: model.MailFolderTrash}); err != nil {
		t.Fatal(err)
	}
	page := func(filter mail.Filter) ([]string, bool) {
		t.Helper()
		headers, more, err := store.List(filter)
		if err != nil {
			t.Fatal(err)
		}
		return ids(headers), more
	}
	if got, more := page(mail.Filter{Limit: 3}); !slices.Equal(got, []string{all[6].ID, all[5].ID, all[4].ID}) || !more {
		t.Fatalf("first page = %v %v", got, more)
	}
	if got, more := page(mail.Filter{Limit: 3, BeforeID: all[4].ID}); !slices.Equal(got, []string{all[3].ID, all[2].ID, all[1].ID}) || !more {
		t.Fatalf("second page = %v %v", got, more)
	}
	if got, more := page(mail.Filter{Folder: model.MailFolderInbox, Unread: true}); !slices.Equal(got, []string{all[6].ID, all[5].ID, all[4].ID, all[0].ID}) || more {
		t.Fatalf("unread inbox = %v %v", got, more)
	}
	if got, _ := page(mail.Filter{Flagged: true}); !slices.Equal(got, []string{all[1].ID}) {
		t.Fatalf("flagged = %v", got)
	}
	if got, _ := page(mail.Filter{Folder: model.MailFolderArchive}); !slices.Equal(got, []string{all[2].ID}) {
		t.Fatalf("archive = %v", got)
	}
	if _, _, err := store.List(mail.Filter{BeforeID: "ml_gone"}); !errors.Is(err, mail.ErrNotFound) {
		t.Fatalf("unknown cursor = %v", err)
	}
	_, _, err = store.List(mail.Filter{Folder: "sent"})
	wantKind(t, err, fault.Invalid, "unknown folder")
	_, err = store.Update([]string{all[0].ID}, mail.Change{})
	wantKind(t, err, fault.Invalid, "empty change")
	_, err = store.Update(make([]string, model.MailMaxIDsPerCall+1), mail.Change{Read: &yes})
	wantKind(t, err, fault.Invalid, "too many IDs")
	_, err = store.Delete(nil, false)
	wantKind(t, err, fault.Invalid, "nothing to delete")
	_, err = store.Delete([]string{all[0].ID}, true)
	wantKind(t, err, fault.Invalid, "IDs and empty trash")

	emptied, err := store.Delete(nil, true)
	if err != nil || !slices.Equal(emptied, []string{all[3].ID}) {
		t.Fatalf("empty trash = %v, %v", emptied, err)
	}
	if got, _ := page(mail.Filter{}); len(got) != 6 || slices.Contains(got, all[3].ID) {
		t.Fatalf("after empty trash = %v", got)
	}
}
