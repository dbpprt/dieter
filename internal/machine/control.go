package machine

import (
	"context"
	"errors"
)

type Operation string

const (
	OperationRestart  Operation = "restart"
	OperationShutdown Operation = "shutdown"
)

var ErrOperationUnsupported = errors.New("machine operation is not supported on this host")

func SupportsOperations() bool { return supportsOperations() }

func ExecuteOperation(ctx context.Context, operation Operation) error {
	if operation != OperationRestart && operation != OperationShutdown {
		return errors.New("invalid machine operation")
	}
	return executeOperation(ctx, operation)
}
