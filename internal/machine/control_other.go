//go:build !darwin

package machine

import "context"

func supportsOperations() bool { return false }

func executeOperation(context.Context, Operation) error { return ErrOperationUnsupported }
