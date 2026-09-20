package server

import (
	"connectrpc.com/connect"
	"context"
	"fmt"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestKVWatchSnapshotResumeAndAccountIsolation(t *testing.T) {
	s := store.New(t.TempDir())
	api := &grpcAPI{server: &Server{store: s}}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	info, e := api.ListKV(ctx, &dieterv1.KVListRequest{Namespace: "navigation"})
	if e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 70; i++ {
		_, e = api.PutKV(ctx, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Namespace: "navigation", Key: fmt.Sprintf("projects-folder.f%d.name", i), Account: info.Account}, ValueJson: []byte(`"Folder"`), OperationId: fmt.Sprint("op", i), DaemonId: info.DaemonId})
		if e != nil {
			t.Fatal(e)
		}
	}
	frames := make(chan *dieterv1.KVFrame, 4)
	done := make(chan error, 1)
	go func() {
		done <- api.watchKV(ctx, &dieterv1.KVWatchRequest{Namespace: "navigation", Account: info.Account}, func(f *dieterv1.KVFrame) error {
			select {
			case frames <- f:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()
	first := <-frames
	second := <-frames
	if !first.Reset_ || first.CaughtUp || len(first.Entries) != 64 || second.Reset_ || !second.CaughtUp || len(second.Entries) != 6 {
		t.Fatal(first, second)
	}
	_, e = api.PutKV(ctx, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Namespace: "navigation", Key: "projects-folder.new.name", Account: info.Account}, ValueJson: []byte(`"New"`), OperationId: "new", DaemonId: info.DaemonId})
	if e != nil {
		t.Fatal(e)
	}
	third := <-frames
	if third.Reset_ || len(third.Entries) != 1 || third.Cursor.Sequence <= second.Cursor.Sequence {
		t.Fatal(third)
	}
	if _, e = api.ListKV(ctx, &dieterv1.KVListRequest{Account: "another"}); status.Code(e) != codes.PermissionDenied {
		t.Fatal(e)
	}
	if _, e = api.ListKV(ctx, &dieterv1.KVListRequest{Snapshot: second.Cursor}); status.Code(e) != codes.Aborted {
		t.Fatal(e)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("watch did not cancel")
	}
	if api.server.kvWatches.Load() != 0 {
		t.Fatal("watch capacity leaked")
	}
}

func TestKVConnectAdapterLocalEndToEnd(t *testing.T) {
	data := store.New(t.TempDir())
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	info, e := client.ListKV(ctx, connect.NewRequest(&dieterv1.KVListRequest{Namespace: "navigation"}))
	if e != nil {
		t.Fatal(e)
	}
	request := &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Namespace: "navigation", Key: "chats-folder.f.expanded", Account: info.Msg.Account}, ValueJson: []byte("false"), OperationId: "collapse", DaemonId: info.Msg.DaemonId}
	written, e := client.PutKV(ctx, connect.NewRequest(request))
	if e != nil {
		t.Fatal(e)
	}
	replay, e := client.PutKV(ctx, connect.NewRequest(request))
	if e != nil || written.Msg.Revision != replay.Msg.Revision {
		t.Fatal(replay, e)
	}
	stream, e := client.WatchKV(ctx, connect.NewRequest(&dieterv1.KVWatchRequest{Namespace: "navigation", Account: info.Msg.Account}))
	if e != nil {
		t.Fatal(e)
	}
	if !stream.Receive() {
		t.Fatal(stream.Err())
	}
	frame := stream.Msg()
	if !frame.GetReset_() || !frame.CaughtUp || len(frame.Entries) != 1 || string(frame.Entries[0].ValueJson) != "false" {
		t.Fatal(frame)
	}
	_ = stream.Close()
}
