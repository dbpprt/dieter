// Package fault gives domain errors an explicit kind. The API maps kinds to
// RPC status codes in one place; an error without a kind is an internal
// failure. Kinds survive wrapping with fmt.Errorf("...: %w", err).
package fault

import (
	"errors"
	"fmt"
)

// Kind classifies why an operation failed.
type Kind int

const (
	// Internal is a failure the caller cannot fix; retrying may succeed.
	Internal Kind = iota
	// Invalid rejects the request itself: a malformed or unsupported value.
	Invalid
	// NotFound reports that a referenced entity does not exist.
	NotFound
	// AlreadyExists reports that an entity to create exists.
	AlreadyExists
	// FailedPrecondition rejects a valid request in the current state.
	FailedPrecondition
	// PermissionDenied rejects a caller that may not perform the operation.
	PermissionDenied
	// Conflict reports a lost optimistic-concurrency race; reload and retry.
	Conflict
	// ResourceExhausted reports a capacity or quota limit.
	ResourceExhausted
	// Unavailable reports a temporarily unavailable dependency.
	Unavailable
	// Unimplemented reports an operation this host does not support.
	Unimplemented
	// DataLoss reports unrecoverable corruption, such as tampered ciphertext.
	DataLoss
	// Unauthenticated rejects a caller without valid credentials.
	Unauthenticated
	// OutOfRange rejects a position past the end of the data.
	OutOfRange
)

func (k Kind) String() string {
	switch k {
	case Invalid:
		return "invalid"
	case NotFound:
		return "not found"
	case AlreadyExists:
		return "already exists"
	case FailedPrecondition:
		return "failed precondition"
	case PermissionDenied:
		return "permission denied"
	case Conflict:
		return "conflict"
	case ResourceExhausted:
		return "resource exhausted"
	case Unavailable:
		return "unavailable"
	case Unimplemented:
		return "unimplemented"
	case DataLoss:
		return "data loss"
	case Unauthenticated:
		return "unauthenticated"
	case OutOfRange:
		return "out of range"
	default:
		return "internal"
	}
}

// Error is an error with an explicit kind. Its message is the wrapped
// error's, unchanged.
type Error struct {
	Kind Kind
	Err  error
}

func (e *Error) Error() string { return e.Err.Error() }
func (e *Error) Unwrap() error { return e.Err }

// Wrap attaches kind to err. A nil err stays nil.
func Wrap(kind Kind, err error) error {
	if err == nil {
		return nil
	}
	return &Error{Kind: kind, Err: err}
}

// KindOf returns the first explicit kind in err's chain, the outermost wrap.
func KindOf(err error) (Kind, bool) {
	var classified *Error
	if errors.As(err, &classified) {
		return classified.Kind, true
	}
	return Internal, false
}

// New and Errorf create errors of a kind, like errors.New and fmt.Errorf.
func New(kind Kind, message string) error { return &Error{Kind: kind, Err: errors.New(message)} }
func Errorf(kind Kind, format string, args ...any) error {
	return &Error{Kind: kind, Err: fmt.Errorf(format, args...)}
}

// Invalidf, NotFoundf, ... are shorthands for the most common kinds.
func Invalidf(format string, args ...any) error  { return Errorf(Invalid, format, args...) }
func NotFoundf(format string, args ...any) error { return Errorf(NotFound, format, args...) }
func FailedPreconditionf(format string, args ...any) error {
	return Errorf(FailedPrecondition, format, args...)
}
