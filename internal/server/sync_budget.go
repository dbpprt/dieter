package server

import (
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// Large directories are transferred as a reset followed by bounded delta
// pages. Only the last page carries the applied cursor. Interrupted batches
// therefore cannot be persisted or resumed as complete projections.
func sendBoundedSyncFrame(frame *dieterv1.SyncFrame, send func(*dieterv1.SyncFrame) error) error {
	if proto.Size(frame) <= maxSyncFrameBytes {
		return send(frame)
	}

	delta := frame.GetDelta()
	if snapshot := frame.GetSnapshot(); snapshot != nil {
		state := snapshot.GetState()
		base := &dieterv1.SyncFrame{Reset_: frame.Reset_, ProjectionPending: true, Snapshot: &dieterv1.GlobalSnapshot{State: &dieterv1.State{StorePath: state.GetStorePath()}}}
		if err := send(base); err != nil {
			return err
		}
		delta = &dieterv1.GlobalDelta{Projects: state.GetProjects(), Boards: state.GetBoards(), Cards: state.GetCards(), Chats: state.GetChats(), Settings: snapshot.GetSettings(), Conversations: snapshot.GetConversations()}
	}
	if delta == nil {
		return status.Error(codes.ResourceExhausted, "sync diagnostic frame exceeds the byte budget")
	}
	page := &dieterv1.SyncFrame{ProjectionPending: true, Delta: &dieterv1.GlobalDelta{}}
	flush := func() error {
		if err := send(page); err != nil {
			return err
		}
		page = &dieterv1.SyncFrame{ProjectionPending: true, Delta: &dieterv1.GlobalDelta{}}
		return nil
	}
	var failure error
	delta.ProtoReflect().Range(func(field protoreflect.FieldDescriptor, value protoreflect.Value) bool {
		appendValue := func(value protoreflect.Value) bool {
			target := page.Delta.ProtoReflect()
			if field.IsList() {
				target.Mutable(field).List().Append(value)
			} else {
				target.Set(field, value)
			}
			if proto.Size(page) <= maxSyncFrameBytes-65536 {
				return true
			}
			if field.IsList() {
				list := target.Mutable(field).List()
				list.Truncate(list.Len() - 1)
			} else {
				target.Clear(field)
			}
			if failure = flush(); failure != nil {
				return false
			}
			target = page.Delta.ProtoReflect()
			if field.IsList() {
				target.Mutable(field).List().Append(value)
			} else {
				target.Set(field, value)
			}
			if proto.Size(page) > maxSyncFrameBytes-65536 {
				failure = status.Error(codes.ResourceExhausted, "a workspace metadata item exceeds the 8 MiB sync budget")
				return false
			}
			return true
		}
		if field.IsList() {
			list := value.List()
			for i := 0; i < list.Len(); i++ {
				if !appendValue(list.Get(i)) {
					return false
				}
			}
			return true
		}
		return appendValue(value)
	})
	if failure != nil {
		return failure
	}
	page.Cursor = frame.Cursor
	page.Event = frame.Event
	page.Events = frame.Events
	page.ProjectionPending = false
	if proto.Size(page) > maxSyncFrameBytes {
		return status.Error(codes.ResourceExhausted, "sync cursor diagnostics exceed the frame budget")
	}
	return send(page)
}
