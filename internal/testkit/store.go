package testkit

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

// ProjectDir returns a fresh directory that passes for a Git working tree (it
// holds an empty .git directory) for project fixtures that never run Git.
func ProjectDir(tb testing.TB) string {
	tb.Helper()
	path := filepath.Join(tb.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(path, ".git"), 0o700); err != nil {
		tb.Fatal(err)
	}
	return path
}

// BoardStore returns an initialized Store holding the project "Atlas"
// (kp_atlas) on a ProjectDir and its board "Delivery" with the workflow.
func BoardStore(tb testing.TB, workflow string) (*store.Store, model.Project, model.Board) {
	tb.Helper()
	data := Store(tb)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{ID: "kp_atlas", Name: "Atlas", Path: ProjectDir(tb), Prompt: "Ship carefully."})
	if err != nil {
		tb.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Delivery", Workflow: workflow})
	if err != nil {
		tb.Fatal(err)
	}
	return data, project, board
}

// PeerStore returns a store in a fresh Home bound to the shared test account
// as the daemon daemonID. Stores from PeerStore replicate with JoinPeers.
func PeerStore(tb testing.TB, daemonID string) *store.Store {
	tb.Helper()
	data := store.New(Home(tb))
	if _, err := data.Replica.BindPeerAccount("account", "subject", daemonID, "https://gateway.test"); err != nil {
		tb.Fatal(err)
	}
	return data
}

// JoinPeers merges every replica record of from into to, one page at a time,
// as peer sync would.
func JoinPeers(tb testing.TB, from, to *store.Store) {
	tb.Helper()
	identity, err := to.Replica.PeerIdentity()
	if err != nil {
		tb.Fatal(err)
	}
	source, err := from.Replica.PeerData(identity.Account)
	if err != nil {
		tb.Fatal(err)
	}
	records := source.Sorted()
	for len(records) > 0 {
		n := min(len(records), crdt.PageSize)
		if err = to.Replica.MergePeerRecords(identity, records[:n]); err != nil {
			tb.Fatal(err)
		}
		records = records[n:]
	}
}

// ChangeCounters reads the committed change counter of data and the sequence
// of its latest metadata change.
func ChangeCounters(tb testing.TB, data *store.Store) (changes, metadata uint64) {
	tb.Helper()
	changes, err := data.ChangeCount()
	if err != nil {
		tb.Fatal(err)
	}
	revision, err := data.MetadataRevision()
	if err != nil {
		tb.Fatal(err)
	}
	return changes, revision.Sequence
}
