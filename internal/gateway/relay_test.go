package gateway

import (
	"context"
	"testing"
	"time"
)

func TestRelayDeadlineOnlyPropagatesClientDeadline(t *testing.T) {
	if got := relayDeadlineUnixMillis(context.Background()); got != 0 {
		t.Fatalf("background relay deadline = %d, want 0", got)
	}

	deadline := time.Now().Add(time.Minute).Truncate(time.Millisecond)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	if got := relayDeadlineUnixMillis(ctx); got != deadline.UnixMilli() {
		t.Fatalf("relay deadline = %d, want %d", got, deadline.UnixMilli())
	}
}
