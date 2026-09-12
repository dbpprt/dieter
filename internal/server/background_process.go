package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/remoteexec"
	"google.golang.org/protobuf/encoding/protojson"
)

// Agent tools and native/CLI executions share one daemon manager and the same
// admission policy. The owning card comes from the active harness, never input.
func (s *Server) backgroundProcess(ctx context.Context, cardID string, call harness.ProcessCall) (json.RawMessage, error) {
	api := &grpcAPI{server: s}
	var input struct {
		Argv             []string          `json:"argv"`
		Name             string            `json:"name"`
		WorkingDirectory string            `json:"workingDirectory"`
		Environment      map[string]string `json:"environment"`
		TimeoutMs        int64             `json:"timeoutMs"`
		IdempotencyKey   string            `json:"idempotencyKey"`
		ExecutionID      string            `json:"executionId"`
		AfterSequence    uint64            `json:"afterSequence"`
	}
	decoder := json.NewDecoder(bytes.NewReader(call.Arguments))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		return nil, fmt.Errorf("invalid background process arguments: %w", err)
	}
	switch call.Operation {
	case "start":
		value, err := api.StartExecution(ctx, &dieterv1.StartExecutionRequest{
			CardId: cardID, Argv: input.Argv, Name: input.Name, WorkingDirectory: input.WorkingDirectory,
			Environment: input.Environment, TimeoutMs: input.TimeoutMs,
			IdempotencyKey: input.IdempotencyKey, StdinEof: true, MaxOutputBytes: 8 << 20,
		})
		if err != nil {
			return nil, err
		}
		return protojson.Marshal(value)
	case "list":
		value, err := api.ListExecutions(ctx, &dieterv1.ListExecutionsRequest{CardId: cardID})
		if err != nil {
			return nil, err
		}
		return protojson.Marshal(value)
	case "read", "stop":
		value, err := api.GetExecution(ctx, &dieterv1.ExecutionRef{ExecutionId: input.ExecutionID})
		if err != nil {
			return nil, err
		}
		if value.CardId != cardID {
			return nil, errors.New("process does not belong to this conversation")
		}
		if call.Operation == "stop" {
			value, err = api.CancelExecution(ctx, &dieterv1.ExecutionRef{ExecutionId: input.ExecutionID})
			if err != nil {
				return nil, err
			}
			return protojson.Marshal(value)
		}
		// A read is a bounded snapshot of the same resumable event log used by
		// WatchExecution. It does not wait for completion or kill the process.
		events, _, err := s.executions.Events(input.ExecutionID, input.AfterSequence)
		if err != nil {
			return nil, err
		}
		type frame struct {
			Sequence uint64 `json:"sequence"`
			Stream   string `json:"stream"`
			Text     string `json:"text,omitempty"`
			Reset    bool   `json:"reset,omitempty"`
		}
		result := struct {
			Execution     json.RawMessage `json:"execution"`
			Events        []frame         `json:"events"`
			AfterSequence uint64          `json:"afterSequence"`
			HasMore       bool            `json:"hasMore"`
		}{AfterSequence: input.AfterSequence, Events: []frame{}}
		result.Execution, err = protojson.Marshal(value)
		if err != nil {
			return nil, err
		}
		outputBytes := 0
		for _, event := range events {
			if len(result.Events) >= 128 || outputBytes+len(event.Data) > 64<<10 {
				result.HasMore = true
				break
			}
			stream := "state"
			switch event.Stream {
			case remoteexec.StreamStdout:
				stream = "stdout"
			case remoteexec.StreamStderr:
				stream = "stderr"
			case remoteexec.StreamPTY:
				stream = "pty"
			}
			result.Events = append(result.Events, frame{Sequence: event.Sequence, Stream: stream, Text: strings.ToValidUTF8(string(event.Data), "�"), Reset: event.Reset})
			if event.Sequence > result.AfterSequence {
				result.AfterSequence = event.Sequence
			}
			outputBytes += len(event.Data)
		}
		return json.Marshal(result)
	default:
		return nil, errors.New("unknown background process operation")
	}
}
