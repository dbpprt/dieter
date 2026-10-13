package relay

import (
	"context"
	"errors"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

var ErrCapacity = errors.New("relay buffer capacity is exhausted")
var ErrFull = errors.New("relay tunnel queue is full")

// QueuedFrames bounds the frames one tunnel may have queued in one direction:
// a full window of DATA, as many WINDOW credits, and the frames that open and
// close it. A peer that respects the window never reaches it.
const QueuedFrames = 2*TunnelWindow + 2

// Budget reserves actual allocations. Independent parent budgets for each lane
// preserve capacity for maintenance even when another lane reaches its ceiling.
type Budget struct {
	mu     sync.Mutex
	used   int64
	limit  int64
	parent *Budget
}

func NewBudget(limit int64, parent *Budget) *Budget { return &Budget{limit: limit, parent: parent} }
func (b *Budget) Reserve(n int64) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	limit := b.limit
	if limit == 0 {
		limit = BufferedBytes
	}
	if n < 0 || n > limit-b.used {
		return false
	}
	if b.parent != nil && !b.parent.Reserve(n) {
		return false
	}
	b.used += n
	return true
}
func (b *Budget) Release(n int64) {
	b.mu.Lock()
	b.used -= n
	b.mu.Unlock()
	if b.parent != nil {
		b.parent.Release(n)
	}
}
func (b *Budget) Used() int64 { b.mu.Lock(); defer b.mu.Unlock(); return b.used }

type queued struct {
	frame *gatewayv1.DaemonLinkFrame
	bytes int64
}

// Queue schedules the tunnel frames of one link connection, one frame per
// tunnel per round, so a busy tunnel cannot delay the others. Each frame is
// reserved against the link's byte budget from Add until the writer releases
// it after sending, including a frame whose tunnel was canceled meanwhile.
type Queue struct {
	mu      sync.Mutex
	streams map[uint64][]queued
	order   []uint64
	bytes   int64
	budget  *Budget
	closed  bool
	changed chan struct{}
	Wake    chan struct{}
}

func NewQueue(b *Budget) *Queue {
	return &Queue{streams: map[uint64][]queued{}, budget: b, Wake: make(chan struct{}, 1), changed: make(chan struct{})}
}

// signal wakes producers waiting in AddWait; q.mu is held.
func (q *Queue) signal() {
	close(q.changed)
	q.changed = make(chan struct{})
}
func (q *Queue) wake() {
	select {
	case q.Wake <- struct{}{}:
	default:
	}
}

// Add queues f behind its tunnel's earlier frames. It never blocks: a tunnel
// whose peer ignores its window gets ErrFull and is closed by its owner.
func (q *Queue) Add(f *gatewayv1.DaemonLinkFrame) error {
	if len(f.GetPayload()) > ChunkBytes {
		return ErrCapacity
	}
	n := int64(proto.Size(f))
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return ErrCapacity
	}
	if len(q.streams[f.GetStreamId()]) >= QueuedFrames {
		return ErrFull
	}
	if !q.budget.Reserve(n) {
		return ErrCapacity
	}
	if len(q.streams[f.GetStreamId()]) == 0 {
		q.order = append(q.order, f.GetStreamId())
	}
	q.streams[f.GetStreamId()] = append(q.streams[f.GetStreamId()], queued{frame: f, bytes: n})
	q.bytes += n
	q.wake()
	return nil
}

// AddWait applies bounded backpressure to one producer while its tunnel's
// queue is full, never to the writer or other tunnels. It gives up after
// WriteTimeout, when ctx ends, or when the queue closes.
func (q *Queue) AddWait(ctx context.Context, f *gatewayv1.DaemonLinkFrame) error {
	timer := time.NewTimer(WriteTimeout)
	defer timer.Stop()
	for {
		q.mu.Lock()
		changed := q.changed
		q.mu.Unlock()
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := q.Add(f); !errors.Is(err, ErrFull) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			return ErrCapacity
		case <-changed:
		}
	}
}

// Next returns the next frame in round-robin order and the function that
// releases its reservation once it was written.
func (q *Queue) Next() (*gatewayv1.DaemonLinkFrame, func()) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.order) == 0 {
		return nil, func() {}
	}
	id := q.order[0]
	q.order = q.order[1:]
	items := q.streams[id]
	item := items[0]
	if len(items) == 1 {
		delete(q.streams, id)
	} else {
		q.streams[id] = items[1:]
		q.order = append(q.order, id)
		q.wake()
	}
	q.signal()
	return item.frame, sync.OnceFunc(func() { q.release(item.bytes) })
}

func (q *Queue) release(n int64) {
	q.mu.Lock()
	q.bytes -= n
	q.mu.Unlock()
	q.budget.Release(n)
}

func (q *Queue) cancel(id uint64) {
	for _, item := range q.streams[id] {
		q.bytes -= item.bytes
		q.budget.Release(item.bytes)
	}
	delete(q.streams, id)
	for i, v := range q.order {
		if v == id {
			q.order = append(q.order[:i], q.order[i+1:]...)
			break
		}
	}
}

// Cancel drops a tunnel's queued frames.
func (q *Queue) Cancel(id uint64) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.cancel(id)
	q.signal()
}
func (q *Queue) Close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.closed = true
	for id := range q.streams {
		q.cancel(id)
	}
	q.signal()
}
func (q *Queue) Bytes() int64 { q.mu.Lock(); defer q.mu.Unlock(); return q.bytes }
