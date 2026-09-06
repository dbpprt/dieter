//go:build !darwin && !linux

package machine

import "context"

func operationCapabilities(context.Context) []OperationCapability {
	return []OperationCapability{
		{Operation: OperationRestart, UnavailableReason: ErrOperationUnsupported.Error()},
		{Operation: OperationShutdown, UnavailableReason: ErrOperationUnsupported.Error()},
	}
}

func executeOperation(context.Context, Operation) error { return ErrOperationUnsupported }
