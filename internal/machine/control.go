package machine

import (
	"context"
	"errors"
	"sync"
	"time"
)

type Operation string

const (
	OperationRestart  Operation = "restart"
	OperationShutdown Operation = "shutdown"
)

var ErrOperationUnsupported = errors.New("machine operation is not supported on this host")

type OperationCapability struct {
	Operation         Operation
	Supported         bool
	Authorized        bool
	UnavailableReason string
}

var operationCapabilityCache struct {
	sync.Mutex
	values []OperationCapability
	at     time.Time
}

func OperationCapabilities(ctx context.Context) []OperationCapability {
	operationCapabilityCache.Lock()
	defer operationCapabilityCache.Unlock()
	if !operationCapabilityCache.at.IsZero() && time.Since(operationCapabilityCache.at) < 30*time.Second {
		return append([]OperationCapability(nil), operationCapabilityCache.values...)
	}
	values := operationCapabilities(ctx)
	operationCapabilityCache.values = append([]OperationCapability(nil), values...)
	operationCapabilityCache.at = time.Now()
	return values
}

func Capability(ctx context.Context, operation Operation) OperationCapability {
	for _, value := range OperationCapabilities(ctx) {
		if value.Operation == operation {
			return value
		}
	}
	return OperationCapability{Operation: operation, UnavailableReason: ErrOperationUnsupported.Error()}
}

func SupportsOperations() bool {
	for _, value := range OperationCapabilities(context.Background()) {
		if value.Supported && value.Authorized {
			return true
		}
	}
	return false
}

func ExecuteOperation(ctx context.Context, operation Operation) error {
	if operation != OperationRestart && operation != OperationShutdown {
		return errors.New("invalid machine operation")
	}
	return executeOperation(ctx, operation)
}
