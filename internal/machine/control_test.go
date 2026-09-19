package machine

import (
	"context"
	"testing"
)

func TestOperationCapabilitiesRetryFailedProbe(t *testing.T) {
	root := t.TempDir()
	calls := 0
	collect := func(context.Context, string) []OperationCapability {
		calls++
		if calls == 1 {
			return []OperationCapability{{Operation: OperationUpdate, UnavailableReason: "probe timed out", retryable: true}}
		}
		return []OperationCapability{{Operation: OperationUpdate, Supported: true, Authorized: true}}
	}
	first := cachedOperationCapabilitiesAtRoot(context.Background(), root, collect)
	if first[0].Supported {
		t.Fatal("failed probe was accepted")
	}
	second := cachedOperationCapabilitiesAtRoot(context.Background(), root, collect)
	if calls != 2 || !second[0].Supported {
		t.Fatalf("transient failure cached: calls=%d values=%+v", calls, second)
	}
	// Successful results stay cached, and callers cannot mutate the cache.
	second[0].Supported = false
	third := cachedOperationCapabilitiesAtRoot(context.Background(), root, collect)
	if calls != 2 || !third[0].Supported {
		t.Fatalf("successful cache changed: calls=%d values=%+v", calls, third)
	}
}

func TestOperationCapabilitiesDoNotCacheCanceledCollection(t *testing.T) {
	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	collect := func(context.Context, string) []OperationCapability {
		calls++
		if calls == 1 {
			cancel()
			return []OperationCapability{{Operation: OperationUpdate}}
		}
		return []OperationCapability{{Operation: OperationUpdate, Supported: true}}
	}
	cachedOperationCapabilitiesAtRoot(ctx, root, collect)
	next := cachedOperationCapabilitiesAtRoot(context.Background(), root, collect)
	if calls != 2 || !next[0].Supported {
		t.Fatalf("canceled collection cached: calls=%d values=%+v", calls, next)
	}
}

func TestOperationCapabilitiesCacheDefinitiveUnsupportedResult(t *testing.T) {
	root := t.TempDir()
	calls := 0
	collect := func(context.Context, string) []OperationCapability {
		calls++
		return []OperationCapability{{Operation: OperationUpdate, UnavailableReason: "formula is not installed"}}
	}
	cachedOperationCapabilitiesAtRoot(context.Background(), root, collect)
	cachedOperationCapabilitiesAtRoot(context.Background(), root, collect)
	if calls != 1 {
		t.Fatalf("definitive result was not cached: %d calls", calls)
	}
}
