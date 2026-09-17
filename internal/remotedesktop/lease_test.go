package remotedesktop

import (
	"bytes"
	"math"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/proto"
)

func TestReceiverLivenessRenewsLeaseOnlyWhileSignalingIsAuthorized(t *testing.T) {
	now := time.Now().UTC()
	manager := New(Options{Now: func() time.Time { return now }})
	s := &Session{manager: manager, inputEpoch: bytes.Repeat([]byte{7}, 16),
		leaseExpiresAt: now.Add(time.Second), subscribers: map[uint64]chan *dieterv1.RemoteDesktopSignal{1: make(chan *dieterv1.RemoteDesktopSignal, 1)}}
	feedback := &dieterv1.RemoteDesktopReceiverFeedback{ProtocolVersion: inputProtocolVersion, InputEpoch: s.inputEpoch, Sequence: 1}
	send := func() { raw, _ := proto.Marshal(feedback); s.receiveFeedback(raw) }
	now = now.Add(2 * time.Second)
	send()
	if !s.leaseExpiresAt.Equal(now.Add(defaultSessionLease)) {
		t.Fatal("fresh authenticated peer heartbeat did not renew the lease")
	}
	expires := s.leaseExpiresAt
	now = now.Add(time.Second)
	send()
	if !s.leaseExpiresAt.Equal(expires) {
		t.Fatal("replayed heartbeat renewed the lease")
	}
	feedback.Sequence++
	feedback.InputEpoch = []byte("wrong session")
	send()
	if !s.leaseExpiresAt.Equal(expires) {
		t.Fatal("wrong epoch renewed the lease")
	}
	feedback.InputEpoch = s.inputEpoch
	feedback.DecodeMs = math.NaN()
	send()
	if !s.leaseExpiresAt.Equal(now.Add(defaultSessionLease)) {
		t.Fatal("invalid statistics discarded valid liveness")
	}
	expires = s.leaseExpiresAt
	now = now.Add(time.Second)
	delete(s.subscribers, 1)
	feedback.Sequence++
	send()
	if !s.leaseExpiresAt.Equal(expires) {
		t.Fatal("detached signaling bypassed authorization expiry")
	}
	s.subscribers[2] = make(chan *dieterv1.RemoteDesktopSignal, 1)
	s.closed = true
	feedback.Sequence++
	send()
	if !s.leaseExpiresAt.Equal(expires) {
		t.Fatal("closed session was resurrected")
	}
}
