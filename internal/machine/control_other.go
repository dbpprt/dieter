//go:build !darwin && !linux

package machine

import "context"

func operationCapabilities(context.Context, string) []OperationCapability {
	return []OperationCapability{
		{Operation: OperationRestart, UnavailableReason: ErrOperationUnsupported.Error()},
		{Operation: OperationShutdown, UnavailableReason: ErrOperationUnsupported.Error()},
		{Operation: OperationUpdate, UnavailableReason: "automatic daemon updates currently require a Homebrew-managed macOS installation"},
	}
}

func executeOperation(context.Context, string, Operation) error { return ErrOperationUnsupported }
