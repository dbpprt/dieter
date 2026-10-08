package relaypolicy

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/proto"
)

func TestEveryDeclaredStreamingMethodHasSubscriptionAdmission(t *testing.T) {
	methods := dieterv1.File_dieter_v1_dieter_proto.Services().ByName("DieterService").Methods()
	for i := 0; i < methods.Len(); i++ {
		m := methods.Get(i)
		if m.IsStreamingServer() && Method("/dieter.v1.DieterService/"+string(m.Name())) != Subscription {
			t.Fatalf("streaming %s lacks subscription admission", m.Name())
		}
	}
	for _, name := range []string{"Health", "GetRuntimeStatus"} {
		if Method("/dieter.v1.DieterService/"+name) != Control {
			t.Fatal(name)
		}
	}
	for _, name := range []string{"GetPeerChanges", "GetPeerRecord", "GetPeerStoreStatus", "ListPeerRecords", "MergePeerRecords"} {
		if Method("/dieter.v1.DieterService/"+name) != Replication {
			t.Fatal(name)
		}
	}
	for _, name := range []string{"Health", "/foreign/Health", "/foreign/WatchKV", "/dieter.v1.DieterService/Unknown"} {
		if Method(name) != Command {
			t.Fatalf("foreign/unknown method got reserved capacity: %s", name)
		}
	}
}
func TestFragmentsAreFairAndReassembleSignedRequest(t *testing.T) {
	budget := NewBudget(2*MessageBytes, nil)
	q := NewQueue(budget)
	defer q.Close()
	large := &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC, StreamId: 1, Payload: bytes.Repeat([]byte("x"), ChunkBytes*3+17), DaemonId: "d", Generation: 2, Method: "/dieter.v1.DieterService/MergePeerRecords", RequestId: "r", DelegationAssertion: "signed", Metadata: map[string]string{"version": "1"}}
	small := &gatewayv1.DaemonLinkFrame{StreamId: 2, Payload: []byte("small")}
	if err := q.Add(large); err != nil {
		t.Fatal(err)
	}
	if err := q.Add(small); err != nil {
		t.Fatal(err)
	}
	a := NewAssembler(NewBudget(2*MessageBytes, nil), 4)
	defer a.Close()
	for n := 0; n < 5; n++ {
		f, release := q.Next()
		if f == nil || len(f.Payload) > ChunkBytes {
			t.Fatal("missing/oversize fragment")
		}
		if n == 1 && f.StreamId != 2 {
			t.Fatal("small RPC waited behind large payload")
		}
		assembled, free, err := a.Accept(f)
		release()
		if err != nil {
			t.Fatal(err)
		}
		if n == 4 && !proto.Equal(assembled, large) {
			t.Fatal("reassembly changed request/authentication metadata")
		}
		free()
	}
	if budget.Used() != 0 {
		t.Fatalf("reservation leak: %d", budget.Used())
	}
}
func TestCancellationRetainsInFlightAllocation(t *testing.T) {
	for _, closeQueue := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "close"}[closeQueue], func(t *testing.T) {
			b := NewBudget(4*ChunkBytes, nil)
			q := NewQueue(b)
			f := &gatewayv1.DaemonLinkFrame{StreamId: 1, Payload: make([]byte, 2*ChunkBytes)}
			if err := q.Add(f); err != nil {
				t.Fatal(err)
			}
			_, release := q.Next()
			used := b.Used()
			if closeQueue {
				q.Close()
			} else {
				q.Cancel(1)
			}
			if b.Used() != used {
				t.Fatal("in-flight backing allocation became unaccounted")
			}
			release()
			release()
			if b.Used() != 0 || q.Bytes() != 0 {
				t.Fatal("cancellation leaked reservation")
			}
		})
	}
}
func TestLaneAndParentByteLimitsRemainIndependent(t *testing.T) {
	parent := NewBudget(1024, nil)
	laneA := NewBudget(768, parent)
	laneB := NewBudget(768, parent)
	if !laneA.Reserve(768) || laneA.Reserve(1) || laneB.Reserve(257) || !laneB.Reserve(256) {
		t.Fatal("byte ceiling not enforced")
	}
	reservedControl := NewBudget(512, nil)
	if !reservedControl.Reserve(512) {
		t.Fatal("data exhausted maintenance capacity")
	}
	laneA.Release(768)
	laneB.Release(256)
	if parent.Used() != 0 {
		t.Fatal("parent budget leaked")
	}
}
func TestAssemblyRejectsMalformedPayloadsAndReleasesCapacity(t *testing.T) {
	tests := map[string]func(*gatewayv1.DaemonLinkFrame){
		"overlap":      func(f *gatewayv1.DaemonLinkFrame) { f.PayloadOffset = 1 },
		"changed size": func(f *gatewayv1.DaemonLinkFrame) { f.PayloadSize++ },
		"changed kind": func(f *gatewayv1.DaemonLinkFrame) {
			f.Kind = gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC
		},
		"duplicate first": func(f *gatewayv1.DaemonLinkFrame) { f.PayloadOffset = 0 },
	}
	for name, alter := range tests {
		t.Run(name, func(t *testing.T) {
			b := NewBudget(4*ChunkBytes, nil)
			a := NewAssembler(b, 1)
			first := &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, StreamId: 1, Payload: make([]byte, ChunkBytes), PayloadSize: 2 * ChunkBytes}
			if _, _, err := a.Accept(first); err != nil {
				t.Fatal(err)
			}
			tail := proto.Clone(first).(*gatewayv1.DaemonLinkFrame)
			tail.PayloadOffset = ChunkBytes
			alter(tail)
			if _, _, err := a.Accept(tail); !errors.Is(err, ErrFragment) {
				t.Fatalf("malformed assembly accepted: %v", err)
			}
			if b.Used() != 0 {
				t.Fatal("bad assembly retained allocation")
			}
		})
	}
}
func TestAssemblyCountExpiryAndOrphanBounds(t *testing.T) {
	b := NewBudget(4*ChunkBytes, nil)
	a := NewAssembler(b, 1)
	f := &gatewayv1.DaemonLinkFrame{StreamId: 1, Payload: make([]byte, ChunkBytes), PayloadSize: 2 * ChunkBytes}
	if _, _, err := a.Accept(f); err != nil {
		t.Fatal(err)
	}
	other := proto.Clone(f).(*gatewayv1.DaemonLinkFrame)
	other.StreamId = 2
	if _, _, err := a.Accept(other); !errors.Is(err, ErrCapacity) {
		t.Fatal("assembly count unbounded")
	}
	if got := a.Expired(time.Now().Add(AssemblyTimeout + time.Second)); len(got) != 1 || got[0] != 1 || b.Used() != 0 {
		t.Fatal("assembly expiry leaked")
	}
	f.PayloadOffset = ChunkBytes
	if got, _, err := a.Accept(f); got != nil || err != nil || b.Used() != 0 {
		t.Fatal("orphan allocated memory")
	}
}
func TestBlockedProducerCancellationAndCloseReleaseCapacity(t *testing.T) {
	b := NewBudget(1024, nil)
	q := NewQueue(b)
	for range 8 {
		if err := q.Add(&gatewayv1.DaemonLinkFrame{StreamId: 1}); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- q.AddWait(ctx, &gatewayv1.DaemonLinkFrame{StreamId: 1}) }()
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled producer blocked")
	}
	q.Close()
	if b.Used() != 0 {
		t.Fatal("closed queue retained allocations")
	}
}
