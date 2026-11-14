package main

import (
	"context"
	"testing"
	"time"

	hostfolders "github.com/dbpprt/dieter/internal/host/folders"
	"github.com/dbpprt/dieter/internal/testkit"
)

// The folder flows rely on an "Inbox" folder whose index already lists
// welcome.txt when a client first asks.
func TestE2EFixtureSeedsTheFolderFlowsRelyOn(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	folders := hostfolders.New(hostfolders.Options{Store: data, Name: "Isolated", Walk: time.Second})
	done := make(chan struct{})
	go func() {
		defer close(done)
		folders.Run(ctx)
	}()
	defer func() {
		cancel()
		<-done
	}()
	if err := seedFoldersFixture(ctx, folders, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	definitions, err := folders.Definitions(false)
	if err != nil || len(definitions) != 1 || definitions[0].Name != FoldersFixtureName {
		t.Fatalf("definitions = %+v, %v", definitions, err)
	}
	page, err := folders.IndexPage(ctx, definitions[0].ID, "", 0, 512, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, entry := range page.Entries {
		found = found || entry.Path == "welcome.txt"
	}
	if !found {
		t.Fatalf("index = %+v", page.Entries)
	}
}
