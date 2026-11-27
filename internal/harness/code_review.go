package harness

import (
	"context"
	"encoding/json"
	"errors"
	"io"
)

// CodeReviewHandler answers one request_code_review call with the review's
// tool result. It runs for minutes and must honour ctx: the call is cancelled
// when the worker exits.
type CodeReviewHandler func(context.Context, ProcessCall) (json.RawMessage, error)

// Code review host calls carry at most this much input and answer with at
// most this much output.
const (
	maxCodeReviewInputBytes  = 8 << 10
	maxCodeReviewResultBytes = 256 << 10
)

func validCodeReviewCall(call *ProcessCall) error {
	if call == nil || call.ID == "" || len(call.ID) > 128 || len(call.Arguments) > maxCodeReviewInputBytes {
		return errors.New("invalid code review host call")
	}
	return nil
}

// replyCodeReview runs the handler and writes its code-review-result line.
// The model never chooses the conversation: the engine binds the handler.
func replyCodeReview(ctx context.Context, writer io.Writer, handler CodeReviewHandler, call ProcessCall) {
	response := struct {
		Type   string          `json:"type"`
		ID     string          `json:"id"`
		Result json.RawMessage `json:"result,omitempty"`
		Error  string          `json:"error,omitempty"`
	}{Type: "code-review-result", ID: call.ID}
	if handler == nil {
		response.Error = "the code reviewer is not available for this conversation"
	} else {
		result, err := handler(ctx, call)
		switch {
		case err != nil:
			response.Error = err.Error()
		case len(result) > maxCodeReviewResultBytes || !json.Valid(result):
			response.Error = "invalid code review result"
		default:
			response.Result = result
		}
	}
	if ctx.Err() != nil {
		// The worker is gone; nobody reads the reply.
		return
	}
	_ = json.NewEncoder(writer).Encode(response)
}
