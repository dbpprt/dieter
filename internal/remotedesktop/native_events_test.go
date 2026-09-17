package remotedesktop

import (
	"context"
	"errors"
	"fmt"
	"io"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func TestNativeEventsCoalesceWithoutLosingShapeStateOrFailure(t *testing.T) {
	mailbox := newNativeEventMailbox()
	failure := errors.New("encoder failed")
	mailbox.push(SourceEvent{StreamID: 1, State: &dieterv1.RemoteDesktopSessionState{Width: 640}, Cursor: &dieterv1.RemoteDesktopCursor{ShapeId: "a", Png: []byte{1, 2}}, Err: failure})
	for i := int32(0); i < 1000; i++ {
		if !mailbox.push(SourceEvent{StreamID: 1, Cursor: &dieterv1.RemoteDesktopCursor{ShapeId: "a", NormalizedX: i}}) {
			t.Fatal("position burst exhausted mailbox")
		}
	}
	if len(mailbox.pending) != 1 {
		t.Fatal("unbounded event history")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	received := make(chan SourceEvent, 1)
	done := make(chan struct{})
	go func() { mailbox.run(ctx, func(event SourceEvent) { received <- event }); close(done) }()
	select {
	case event := <-received:
		if event.State.GetWidth() != 640 || event.Cursor.GetNormalizedX() != 999 || len(event.Cursor.Png) != 2 || event.Err != failure {
			t.Fatalf("coalesced event: %+v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("no event")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("event worker did not stop")
	}
}

func TestNativeEventMailboxBoundsStreamsAndReplacesShapes(t *testing.T) {
	mailbox := newNativeEventMailbox()
	mailbox.push(SourceEvent{StreamID: 0, Cursor: &dieterv1.RemoteDesktopCursor{ShapeId: "old", Png: []byte{1}}})
	mailbox.push(SourceEvent{StreamID: 0, Cursor: &dieterv1.RemoteDesktopCursor{ShapeId: "new"}})
	if len(mailbox.pending[0].Cursor.Png) != 0 {
		t.Fatal("old shape crossed identity")
	}
	for id := uint64(1); id < uint64(2*maxClients+1); id++ {
		if !mailbox.push(SourceEvent{StreamID: id}) {
			t.Fatal("stream rejected before bound")
		}
	}
	if mailbox.push(SourceEvent{StreamID: 99}) {
		t.Fatal("unbounded streams")
	}
}

func TestNativeStoppedCommandsRetainFailureCause(t *testing.T) {
	cause := errors.New("native helper heartbeat acknowledgment: context deadline exceeded")
	stopped := make(chan struct{})
	close(stopped)
	source := &nativeHelperSource{writes: make(chan nativeWrite), stopped: stopped, stoppedErr: cause, pending: make(map[uint64]chan error)}
	if err := source.send(context.Background(), nativeCommand{Kind: "configure"}, true); !errors.Is(err, cause) {
		t.Fatalf("failure cause lost: %v", err)
	}
}

func TestNativeLivenessRequiresNewAcknowledgments(t *testing.T) {
	now := time.Now()
	liveness := nativeLiveness{at: now}
	// Autonomous state/cursor events and unknown/replayed ACKs must not keep
	// a helper alive if its command reader has stopped progressing.
	liveness.acknowledge(0, 10, now.Add(time.Second))
	liveness.acknowledge(11, 10, now.Add(time.Second))
	if _, age := liveness.snapshot(now.Add(4 * time.Second)); age != 4*time.Second {
		t.Fatal("unsolicited event renewed liveness")
	}
	liveness.acknowledge(9, 10, now.Add(4*time.Second))
	liveness.acknowledge(8, 10, now.Add(5*time.Second))
	liveness.acknowledge(9, 10, now.Add(6*time.Second))
	if ack, age := liveness.snapshot(now.Add(7 * time.Second)); ack != 9 || age != 3*time.Second {
		t.Fatal("late/replayed ACK renewed liveness")
	}
}

func TestCaptureRecoveryPreservesPermanentFailures(t *testing.T) {
	for _, err := range []error{nil, errors.New("capture permission denied"), errors.New("invalid native frame metadata"),
		nativeCaptureFailure(io.EOF, "The user declined TCCs")} {
		if recoverableCaptureFailure(err) {
			t.Fatalf("permanent failure retried: %v", err)
		}
	}
	for _, err := range []error{io.EOF, io.ErrUnexpectedEOF, fmt.Errorf("event pipe: %w", errNativeHelperStopped),
		errors.New("native daemon heartbeat expired"), errors.New("native capture rendition stopped"), errors.New("native capture helper unresponsive")} {
		if !recoverableCaptureFailure(err) {
			t.Fatalf("transient capture failure did not recover: %v", err)
		}
	}
}
