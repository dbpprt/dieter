package harness

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"time"
)

// MemoryHandler answers one agent memory host call (memory_recall,
// memory_save, and memory_apply for dream conversations). The engine binds it
// to the conversation and its project: the model never chooses either.
type MemoryHandler func(context.Context, ProcessCall) (json.RawMessage, error)

// Memory host calls carry at most this much input and answer with at most
// this much output; recall across machines is bounded well below the
// timeout.
const (
	maxMemoryInputBytes  = 32 << 10
	maxMemoryResultBytes = 24 << 10
	memoryCallTimeout    = 20 * time.Second
)

func validMemoryCall(call *ProcessCall) error {
	if call == nil || call.ID == "" || len(call.ID) > 128 || len(call.Arguments) > maxMemoryInputBytes {
		return errors.New("invalid memory host call")
	}
	switch call.Operation {
	case "recall", "save", "apply":
		return nil
	}
	return errors.New("unknown memory host call")
}

// replyMemory runs the handler and writes its memory-result line.
func replyMemory(ctx context.Context, writer io.Writer, handler MemoryHandler, call ProcessCall) {
	response := struct {
		Type   string          `json:"type"`
		ID     string          `json:"id"`
		Result json.RawMessage `json:"result,omitempty"`
		Error  string          `json:"error,omitempty"`
	}{Type: "memory-result", ID: call.ID}
	if handler == nil {
		response.Error = "agent memory is not available for this conversation"
	} else {
		bounded, cancel := context.WithTimeout(ctx, memoryCallTimeout)
		result, err := handler(bounded, call)
		cancel()
		switch {
		case err != nil:
			response.Error = err.Error()
		case len(result) > maxMemoryResultBytes || !json.Valid(result):
			response.Error = "invalid memory result"
		default:
			response.Result = result
		}
	}
	if ctx.Err() != nil {
		return
	}
	_ = json.NewEncoder(writer).Encode(response)
}
