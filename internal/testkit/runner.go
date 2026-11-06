package testkit

import (
	"context"
	"encoding/json"
	"strconv"
	"sync"

	"github.com/dbpprt/dieter/internal/harness"
)

// FakeRunner is a deterministic harness.Runner. Every turn is recorded, may be
// held until Release closes, fails with Err when set, and otherwise streams
// Script or a one-message text reply followed by a resumable session.
type FakeRunner struct {
	// Reply chooses the assistant text; nil replies "done".
	Reply func(harness.Request) string
	// Script replaces the default stream entirely.
	Script func(context.Context, harness.Request, func(harness.Output) error) error
	// Err fails every turn after it was recorded and released.
	Err error
	// Release holds every turn until it is closed or the turn is canceled.
	Release chan struct{}

	mu       sync.Mutex
	requests []harness.Request
}

// FakeThreadID is the provider thread every default FakeRunner session resumes.
const FakeThreadID = "thread_1"

func (f *FakeRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	f.mu.Lock()
	f.requests = append(f.requests, request)
	f.mu.Unlock()
	if f.Release != nil {
		select {
		case <-f.Release:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if f.Err != nil {
		return f.Err
	}
	if f.Script != nil {
		return f.Script(ctx, request, emit)
	}
	text := "done"
	if f.Reply != nil {
		text = f.Reply(request)
	}
	return EmitText(emit, text, FakeThreadID)
}

// Requests returns a copy of every recorded request in arrival order.
func (f *FakeRunner) Requests() []harness.Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]harness.Request(nil), f.requests...)
}

// Count returns how many turns ran.
func (f *FakeRunner) Count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

// Request returns the index-th recorded request.
func (f *FakeRunner) Request(index int) harness.Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.requests[index]
}

// EmitText streams one completed assistant text message with token usage and
// then a resumable session for threadID.
func EmitText(emit func(harness.Output) error, text, threadID string) error {
	for _, chunk := range []string{
		`{"type":"start","messageId":"assistant"}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":` + strconv.Quote(text) + `}`,
		`{"type":"text-end","id":"text"}`,
		`{"type":"finish","finishReason":"stop","messageMetadata":{"createdAt":"2026-08-12T12:00:00Z","usage":{"inputTokens":120,"outputTokens":30,"totalTokens":150},"contextWindowTokens":1000}}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return EmitSession(emit, threadID)
}

// EmitSession streams the resumable provider session for threadID.
func EmitSession(emit func(harness.Output) error, threadID string) error {
	state, err := json.Marshal(map[string]any{"type": "resume-session", "data": map[string]string{"threadId": threadID}})
	if err != nil {
		return err
	}
	return emit(harness.Output{Type: "session", State: state})
}
