package harness

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"time"
)

type ProcessCall struct {
	ID        string          `json:"id"`
	Operation string          `json:"operation"`
	Arguments json.RawMessage `json:"arguments"`
}

type ProcessHandler func(context.Context, ProcessCall) (json.RawMessage, error)

// Host calls use the existing private worker pipe. The model never chooses a
// daemon, conversation ID or transport credential; the app binds the handler.
func replyProcessCall(ctx context.Context, writer io.Writer, handler ProcessHandler, call *ProcessCall) error {
	if call == nil || call.ID == "" || len(call.ID) > 128 || len(call.Arguments) > 128<<10 {
		return errors.New("invalid background process host call")
	}
	response := struct {
		Type   string          `json:"type"`
		ID     string          `json:"id"`
		Result json.RawMessage `json:"result,omitempty"`
		Error  string          `json:"error,omitempty"`
	}{Type: "background-process-result", ID: call.ID}
	if handler == nil {
		response.Error = "background processes are unavailable on this daemon"
	} else {
		bounded, cancel := context.WithTimeout(ctx, 30*time.Second)
		result, err := handler(bounded, *call)
		cancel()
		if err != nil {
			response.Error = err.Error()
		} else if len(result) > 1<<20 || !json.Valid(result) {
			response.Error = "invalid background process response"
		} else {
			response.Result = result
		}
	}
	return json.NewEncoder(writer).Encode(response)
}
