package api

import (
	"context"
	"fmt"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/testkit"
	"google.golang.org/grpc/codes"
)

func TestKVWatchSnapshotResumeAndAccountIsolation(t *testing.T) {
	t.Parallel()
	s := testkit.Store(t)
	api := newService(&Server{store: s})
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(time.Minute))
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
		done <- api.server.watchKV(ctx, &dieterv1.KVWatchRequest{Namespace: "navigation", Account: info.Account}, func(f *dieterv1.KVFrame) error {
			select {
			case frames <- f:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()
	receive := func() *dieterv1.KVFrame {
		t.Helper()
		select {
		case frame := <-frames:
			return frame
		case err := <-done:
			t.Fatalf("watch ended early: %v", err)
		case <-ctx.Done():
			t.Fatalf("no watch frame: %v", ctx.Err())
		}
		return nil
	}
	first := receive()
	second := receive()
	if !first.Reset_ || first.CaughtUp || len(first.Entries) != 64 || second.Reset_ || !second.CaughtUp || len(second.Entries) != 6 {
		t.Fatal(first, second)
	}
	_, e = api.PutKV(ctx, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Namespace: "navigation", Key: "projects-folder.new.name", Account: info.Account}, ValueJson: []byte(`"New"`), OperationId: "new", DaemonId: info.DaemonId})
	if e != nil {
		t.Fatal(e)
	}
	third := receive()
	if third.Reset_ || len(third.Entries) != 1 || third.Cursor.Sequence <= second.Cursor.Sequence {
		t.Fatal(third)
	}
	// Agent channel records are written only by their daemon.
	for _, namespace := range []string{"channel", "channel-receipt", "channel-pins", "channel-claims"} {
		_, e = api.PutKV(ctx, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Namespace: namespace, Key: "p_one.d_one", Account: info.Account}, ValueJson: []byte(`{}`), OperationId: "forged-" + namespace, DaemonId: info.DaemonId})
		if codeOf(e) != codes.PermissionDenied {
			t.Fatalf("%s: forged write = %v", namespace, e)
		}
	}
	if _, e = api.ListKV(ctx, &dieterv1.KVListRequest{Account: "another"}); codeOf(e) != codes.PermissionDenied {
		t.Fatal(e)
	}
	if _, e = api.ListKV(ctx, &dieterv1.KVListRequest{Snapshot: second.Cursor}); codeOf(e) != codes.Aborted {
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
	t.Parallel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, newFakeRunner())
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(30*time.Second))
	defer cancel()
	info, e := client.ListKV(ctx, &dieterv1.KVListRequest{Namespace: "navigation"})
	if e != nil {
		t.Fatal(e)
	}
	request := &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Namespace: "navigation", Key: "chats-folder.f.expanded", Account: info.Account}, ValueJson: []byte("false"), OperationId: "collapse", DaemonId: info.DaemonId}
	written, e := client.PutKV(ctx, request)
	if e != nil {
		t.Fatal(e)
	}
	replay, e := client.PutKV(ctx, request)
	if e != nil || written.Revision != replay.Revision {
		t.Fatal(replay, e)
	}
	stream, e := client.WatchKV(ctx, &dieterv1.KVWatchRequest{Namespace: "navigation", Account: info.Account})
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
