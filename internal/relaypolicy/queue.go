package relaypolicy

import (
	"context"
	"errors"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

var ErrCapacity = errors.New("relay buffer capacity is exhausted")
var ErrFull = errors.New("relay stream queue is full")
var ErrFragment = errors.New("invalid relay payload fragment")

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

// Copy only metadata. Cloning a large payload just to replace it would allocate
// an unaccounted second copy of the logical message.
func metadataFrame(f *gatewayv1.DaemonLinkFrame) *gatewayv1.DaemonLinkFrame {
	return &gatewayv1.DaemonLinkFrame{Kind: f.Kind, StreamId: f.StreamId, DaemonId: f.DaemonId, Generation: f.Generation, Method: f.Method, RequestId: f.RequestId, DeadlineUnixMillis: f.DeadlineUnixMillis, Metadata: f.Metadata, StatusCode: f.StatusCode, StatusMessage: f.StatusMessage, DelegationAssertion: f.DelegationAssertion, PayloadSha256: f.PayloadSha256}
}

type queued struct {
	frame   *gatewayv1.DaemonLinkFrame
	offset  int
	bytes   int64
	refs    int
	removed bool
}

// Queue schedules one fragment per stream per round. A reservation stays alive
// through Send, including cancellation of an in-flight fragment.
type Queue struct {
	mu      sync.Mutex
	streams map[uint64][]*queued
	order   []uint64
	bytes   int64
	budget  *Budget
	closed  bool
	changed chan struct{}
	Wake    chan struct{}
}

func NewQueue(b *Budget) *Queue {
	return &Queue{streams: map[uint64][]*queued{}, budget: b, Wake: make(chan struct{}, 1), changed: make(chan struct{})}
}
func (q *Queue) wake() {
	select {
	case q.Wake <- struct{}{}:
	default:
	}
}
func (q *Queue) Add(f *gatewayv1.DaemonLinkFrame) error {
	n := int64(proto.Size(f))
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed || len(f.Payload) > MessageBytes || n-int64(len(f.Payload)) > ChunkBytes {
		return ErrCapacity
	}
	if len(q.streams[f.StreamId]) >= 8 {
		return ErrFull
	}
	if !q.budget.Reserve(n) {
		return ErrCapacity
	}
	if len(q.streams[f.StreamId]) == 0 {
		q.order = append(q.order, f.StreamId)
	}
	q.streams[f.StreamId] = append(q.streams[f.StreamId], &queued{frame: f, bytes: n})
	q.bytes += n
	q.wake()
	return nil
}

// AddWait applies bounded backpressure to a producing RPC, never the receiver.
func (q *Queue) AddWait(ctx context.Context, f *gatewayv1.DaemonLinkFrame) error {
	timer := time.NewTimer(WriteTimeout)
	defer timer.Stop()
	for {
		q.mu.Lock()
		changed := q.changed
		closed := q.closed
		q.mu.Unlock()
		if closed {
			return ErrCapacity
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err := q.Add(f); err == nil {
			return nil
		} else if !errors.Is(err, ErrFull) {
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
func (q *Queue) free(item *queued) {
	if item.removed && item.refs == 0 && item.bytes != 0 {
		q.bytes -= item.bytes
		q.budget.Release(item.bytes)
		item.bytes = 0
		close(q.changed)
		q.changed = make(chan struct{})
	}
}
func (q *Queue) Next() (*gatewayv1.DaemonLinkFrame, func()) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.order) == 0 {
		return nil, func() {}
	}
	id := q.order[0]
	q.order = q.order[1:]
	item := q.streams[id][0]
	f := item.frame
	end := min(item.offset+ChunkBytes, len(f.Payload))
	if len(f.Payload) > ChunkBytes {
		if item.offset == 0 {
			f = metadataFrame(f)
		} else {
			f = &gatewayv1.DaemonLinkFrame{Kind: f.Kind, StreamId: id}
		}
		f.Payload = item.frame.Payload[item.offset:end]
		f.PayloadSize = uint32(len(item.frame.Payload))
		f.PayloadOffset = uint32(item.offset)
	}
	item.offset = end
	item.refs++
	if end == len(item.frame.Payload) {
		q.streams[id] = q.streams[id][1:]
		item.removed = true
		close(q.changed)
		q.changed = make(chan struct{})
	}
	if len(q.streams[id]) > 0 {
		q.order = append(q.order, id)
		q.wake()
	} else {
		delete(q.streams, id)
	}
	return f, sync.OnceFunc(func() { q.mu.Lock(); defer q.mu.Unlock(); item.refs--; q.free(item) })
}
func (q *Queue) cancel(id uint64) {
	for _, item := range q.streams[id] {
		item.removed = true
		q.free(item)
	}
	delete(q.streams, id)
	for i, v := range q.order {
		if v == id {
			q.order = append(q.order[:i], q.order[i+1:]...)
			break
		}
	}
}
func (q *Queue) Cancel(id uint64) { q.mu.Lock(); defer q.mu.Unlock(); q.cancel(id) }
func (q *Queue) Close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.closed = true
	close(q.changed)
	q.changed = make(chan struct{})
	for id := range q.streams {
		q.cancel(id)
	}
}
func (q *Queue) Bytes() int64 { q.mu.Lock(); defer q.mu.Unlock(); return q.bytes }

type assembly struct {
	head     *gatewayv1.DaemonLinkFrame
	size     int
	reserved int64
	expires  time.Time
}

// Assembler is confined to one receiving loop. Orphan continuations allocate
// nothing: cancellation can overtake an already-sent fragment.
type Assembler struct {
	messages map[uint64]*assembly
	budget   *Budget
	limit    int
}

func NewAssembler(b *Budget, limit int) *Assembler {
	return &Assembler{messages: map[uint64]*assembly{}, budget: b, limit: limit}
}
func (a *Assembler) Accept(f *gatewayv1.DaemonLinkFrame) (*gatewayv1.DaemonLinkFrame, func(), error) {
	noop := func() {}
	if f.PayloadSize == 0 {
		if a.messages[f.StreamId] != nil {
			a.Cancel(f.StreamId)
			return nil, noop, ErrFragment
		}
		if f.PayloadOffset != 0 || len(f.Payload) > ChunkBytes {
			return nil, noop, ErrFragment
		}
		return f, noop, nil
	}
	if f.StreamId == 0 || f.PayloadSize > MessageBytes || len(f.Payload) > ChunkBytes || len(f.Payload) == 0 || uint64(f.PayloadOffset)+uint64(len(f.Payload)) > uint64(f.PayloadSize) {
		a.Cancel(f.StreamId)
		return nil, noop, ErrFragment
	}
	m := a.messages[f.StreamId]
	if f.PayloadOffset == 0 {
		if m != nil {
			a.Cancel(f.StreamId)
			return nil, noop, ErrFragment
		}
		n := int64(f.PayloadSize) + int64(proto.Size(f)) - int64(len(f.Payload))
		if len(a.messages) >= a.limit || !a.budget.Reserve(n) {
			return nil, noop, ErrCapacity
		}
		head := metadataFrame(f)
		head.Payload = make([]byte, 0, int(f.PayloadSize))
		m = &assembly{head: head, size: int(f.PayloadSize), reserved: n, expires: time.Now().Add(AssemblyTimeout)}
		a.messages[f.StreamId] = m
	}
	if m == nil {
		return nil, noop, nil
	}
	if m.head.Kind != f.Kind || m.size != int(f.PayloadSize) || len(m.head.Payload) != int(f.PayloadOffset) {
		a.Cancel(f.StreamId)
		return nil, noop, ErrFragment
	}
	m.head.Payload = append(m.head.Payload, f.Payload...)
	if len(m.head.Payload) != m.size {
		return nil, noop, nil
	}
	delete(a.messages, f.StreamId)
	return m.head, sync.OnceFunc(func() { a.budget.Release(m.reserved) }), nil
}
func (a *Assembler) Cancel(id uint64) {
	if m := a.messages[id]; m != nil {
		delete(a.messages, id)
		a.budget.Release(m.reserved)
	}
}
func (a *Assembler) Expired(now time.Time) []uint64 {
	var ids []uint64
	for id, m := range a.messages {
		if !now.Before(m.expires) {
			ids = append(ids, id)
			a.Cancel(id)
		}
	}
	return ids
}
func (a *Assembler) Close() {
	for id := range a.messages {
		a.Cancel(id)
	}
}
