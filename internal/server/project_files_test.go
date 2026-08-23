package server

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
)

func TestProjectFilesConnectEndToEnd(t *testing.T) {
	repo := filepath.Join(t.TempDir(), "workspace")
	for _, directory := range []string{filepath.Join(repo, ".git"), filepath.Join(repo, "src", "nested")} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(repo, "src", "main.go"), []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".env.example"), []byte("SAFE=true\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "binary.dat"), []byte{'a', 0, 'b'}, 0o644); err != nil {
		t.Fatal(err)
	}

	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Workspace", Path: repo})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	listing, err := client.ListFiles(ctx, connect.NewRequest(&dieterv1.ListFilesRequest{ProjectId: project.ID}))
	if err != nil || len(listing.Msg.GetEntries()) != 2 {
		t.Fatalf("listing=%#v err=%v", listing, err)
	}
	hidden, err := client.ListFiles(ctx, connect.NewRequest(&dieterv1.ListFilesRequest{ProjectId: project.ID, ShowHidden: true}))
	if err != nil || len(hidden.Msg.GetEntries()) != 3 {
		t.Fatalf("hidden listing=%#v err=%v", hidden, err)
	}
	document, err := client.ReadFile(ctx, connect.NewRequest(&dieterv1.ReadFileRequest{ProjectId: project.ID, Path: "src/main.go"}))
	if err != nil || document.Msg.GetContent() != "package main\n" || document.Msg.GetBinary() {
		t.Fatalf("document=%#v err=%v", document, err)
	}
	binary, err := client.ReadFile(ctx, connect.NewRequest(&dieterv1.ReadFileRequest{ProjectId: project.ID, Path: "binary.dat"}))
	if err != nil || !binary.Msg.GetBinary() || string(binary.Msg.GetData()) != string([]byte{'a', 0, 'b'}) {
		t.Fatalf("binary=%#v err=%v", binary, err)
	}
	saved, err := client.SaveFile(ctx, connect.NewRequest(&dieterv1.SaveFileRequest{ProjectId: project.ID, Path: "src/main.go", Revision: document.Msg.GetRevision(), Content: "package board\n"}))
	if err != nil || saved.Msg.GetRevision() == document.Msg.GetRevision() {
		t.Fatalf("saved=%#v err=%v", saved, err)
	}
	if _, err := client.SaveFile(ctx, connect.NewRequest(&dieterv1.SaveFileRequest{ProjectId: project.ID, Path: "src/main.go", Revision: document.Msg.GetRevision(), Content: "stale"})); err == nil {
		t.Fatal("expected stale revision error")
	}
	if _, err := client.CreateFile(ctx, connect.NewRequest(&dieterv1.CreateFileRequest{ProjectId: project.ID, Path: "notes", Kind: "directory"})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.CreateFile(ctx, connect.NewRequest(&dieterv1.CreateFileRequest{ProjectId: project.ID, Path: "notes/todo.md", Kind: "file", Content: "todo\n"})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.MoveFile(ctx, connect.NewRequest(&dieterv1.MoveFileRequest{ProjectId: project.ID, Source: "notes/todo.md", Destination: "notes/done.md"})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.DeleteFile(ctx, connect.NewRequest(&dieterv1.DeleteFileRequest{ProjectId: project.ID, Path: "notes", Recursive: true})); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(repo, "notes")); !os.IsNotExist(err) {
		t.Fatalf("notes still exists: %v", err)
	}
}

func TestProjectFilesConnectRejectsTraversalAndEscapingSymlinks(t *testing.T) {
	repo := filepath.Join(t.TempDir(), "workspace")
	outside := filepath.Join(t.TempDir(), "outside.txt")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(outside, []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(repo, "escape")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Workspace", Path: repo})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	for _, path := range []string{"../outside.txt", ".git/config", "/tmp/outside"} {
		if _, err := client.ReadFile(ctx, connect.NewRequest(&dieterv1.ReadFileRequest{ProjectId: project.ID, Path: path})); err == nil {
			t.Fatalf("expected read rejection for %q", path)
		}
	}
	if _, err := client.ReadFile(ctx, connect.NewRequest(&dieterv1.ReadFileRequest{ProjectId: project.ID, Path: "escape"})); err == nil {
		t.Fatal("expected escaping symlink rejection")
	}
	if _, err := client.DeleteFile(ctx, connect.NewRequest(&dieterv1.DeleteFileRequest{ProjectId: project.ID, Path: "escape"})); err != nil {
		t.Fatalf("delete symlink: %v", err)
	}
	raw, err := os.ReadFile(outside)
	if err != nil || string(raw) != "secret" {
		t.Fatalf("outside file changed: %q %v", raw, err)
	}
}
