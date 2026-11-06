package relay

import (
	"context"
	"errors"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
)

func TestDaemonMethodAdmitsOnlyDieterServices(t *testing.T) {
	t.Parallel()
	for method, want := range map[string]bool{
		"/dieter.v1.CardService/CreateCard":          true,
		"/dieter.v1.FutureService/NewRPC":            true,
		"/dieter.gateway.v1.GatewayService/GetState": false,
		"/dieter.v1/CreateCard":                      false,
		"/dieter.v1.CardService/":                    false,
		"/dieter.v1.a.b.CardService/CreateCard":      false,
		"/dieter.v1.CardService/Create/Card":         false,
		"dieter.v1.CardService/CreateCard":           false,
	} {
		if got := DaemonMethod(method); got != want {
			t.Errorf("DaemonMethod(%q) = %v, want %v", method, got, want)
		}
	}
}

func tunnelData(stream uint64, size int) *gatewayv1.DaemonLinkFrame {
	return &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA, StreamId: stream, Payload: make([]byte, size)}
}

func TestQueueSchedulesTunnelsRoundRobin(t *testing.T) {
	t.Parallel()
	budget := NewBudget(0, nil)
	q := NewQueue(budget)
	defer q.Close()
	for range 3 {
		if err := q.Add(tunnelData(1, ChunkBytes)); err != nil {
			t.Fatal(err)
		}
	}
	if err := q.Add(tunnelData(2, 5)); err != nil {
		t.Fatal(err)
	}
	var order []uint64
	for {
		frame, release := q.Next()
		if frame == nil {
			break
		}
		order = append(order, frame.GetStreamId())
		release()
		release()
	}
	if len(order) != 4 || order[0] != 1 || order[1] != 2 {
		t.Fatalf("a busy tunnel delayed another: %v", order)
	}
	if budget.Used() != 0 || q.Bytes() != 0 {
		t.Fatalf("reservation leak: budget=%d queue=%d", budget.Used(), q.Bytes())
	}
}

func TestQueueBoundsEachTunnelAndFrame(t *testing.T) {
	t.Parallel()
	budget := NewBudget(0, nil)
	q := NewQueue(budget)
	defer q.Close()
	if err := q.Add(tunnelData(1, ChunkBytes+1)); !errors.Is(err, ErrCapacity) {
		t.Fatalf("oversized frame = %v", err)
	}
	for range QueuedFrames {
		if err := q.Add(tunnelData(1, 16)); err != nil {
			t.Fatal(err)
		}
	}
	if err := q.Add(tunnelData(1, 16)); !errors.Is(err, ErrFull) {
		t.Fatalf("tunnel exceeded its queue: %v", err)
	}
	if err := q.Add(tunnelData(2, 16)); err != nil {
		t.Fatalf("one full tunnel blocked another: %v", err)
	}
	small := NewQueue(NewBudget(ChunkBytes, nil))
	if err := small.Add(tunnelData(3, ChunkBytes)); !errors.Is(err, ErrCapacity) {
		t.Fatalf("frame beyond the byte budget = %v", err)
	}
}

func TestCancellationRetainsInFlightAllocation(t *testing.T) {
	t.Parallel()
	for _, closeQueue := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "close"}[closeQueue], func(t *testing.T) {
			b := NewBudget(4*ChunkBytes, nil)
			q := NewQueue(b)
			for range 2 {
				if err := q.Add(tunnelData(1, ChunkBytes)); err != nil {
					t.Fatal(err)
				}
			}
			_, release := q.Next()
			used := b.Used()
			if closeQueue {
				q.Close()
			} else {
				q.Cancel(1)
			}
			if b.Used() >= used || b.Used() == 0 {
				t.Fatal("cancellation did not keep exactly the in-flight frame reserved")
			}
			if frame, _ := q.Next(); frame != nil {
				t.Fatal("canceled frame was still scheduled")
			}
			release()
			release()
			if b.Used() != 0 || q.Bytes() != 0 {
				t.Fatal("cancellation leaked reservation")
			}
			if closeQueue {
				if err := q.Add(tunnelData(1, 1)); !errors.Is(err, ErrCapacity) {
					t.Fatalf("closed queue accepted a frame: %v", err)
				}
			}
		})
	}
}

func TestLaneAndParentByteLimitsRemainIndependent(t *testing.T) {
	t.Parallel()
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

func TestBlockedProducerWaitsForItsTunnelAndReleasesOnCancellation(t *testing.T) {
	t.Parallel()
	b := NewBudget(0, nil)
	q := NewQueue(b)
	for range QueuedFrames {
		if err := q.Add(tunnelData(1, 1)); err != nil {
			t.Fatal(err)
		}
	}
	waited := make(chan error, 1)
	go func() { waited <- q.AddWait(t.Context(), tunnelData(1, 1)) }()
	select {
	case err := <-waited:
		t.Fatalf("producer did not wait for a full tunnel: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	_, release := q.Next()
	release()
	select {
	case err := <-waited:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("producer was not woken when its tunnel drained")
	}
	ctx, cancel := context.WithCancel(t.Context())
	canceled := make(chan error, 1)
	go func() { canceled <- q.AddWait(ctx, tunnelData(1, 1)) }()
	cancel()
	select {
	case err := <-canceled:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled producer blocked")
	}
	q.Close()
	if err := q.AddWait(t.Context(), tunnelData(1, 1)); !errors.Is(err, ErrCapacity) {
		t.Fatalf("closed queue accepted a producer: %v", err)
	}
	if b.Used() != 0 {
		t.Fatal("closed queue retained allocations")
	}
}
