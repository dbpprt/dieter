package replica_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestSharedEffectsRecoveryDoesNotReplayOldMetadata(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	if _, err := s.Replica.BindPeerAccount("account", "subject", "machine_a", "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	p, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: testkit.ProjectDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: p.ID, Title: "Before", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	identity, _ := s.Replica.PeerIdentity()
	db, err := s.Replica.Database(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	// Simulate a crash after committing metadata and before applying a file effect.
	if _, err = db.Exec("INSERT INTO peer_effects(path,value,remove_file) VALUES(?,?,0)", "receipts/recovered.json", []byte(`{"durable":true}`)); err != nil {
		t.Fatal(err)
	}
	reopened := store.New(s.Root)
	if _, err = reopened.Kanban.RenameCard(card.ID, "After"); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(filepath.Join(s.Root, "receipts/recovered.json")); err != nil {
		t.Fatal(err)
	}
	got, err := reopened.Kanban.ResolveCard(card.ID)
	if err != nil || got.Title != "After" {
		t.Fatalf("%v %v", got, err)
	}
	var count int
	if err = db.QueryRow("SELECT COUNT(*) FROM peer_effects").Scan(&count); err != nil || count != 0 {
		t.Fatalf("effects=%d %v", count, err)
	}
}
