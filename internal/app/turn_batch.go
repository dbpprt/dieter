package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/store"
)

const turnChunkBatchDelay = 20 * time.Millisecond

// Only adjacent token deltas may wait. Every semantic output is a durability
// barrier, including session/continuation state emitted after a terminal chunk.
func batchableTurnOutput(output harness.Output) bool {
	if output.Type != "chunk" || len(output.Chunk) > store.MaxUIChunkBatchBytes {
		return false
	}
	var chunk struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(output.Chunk, &chunk) != nil {
		return false
	}
	return chunk.Type == "text-delta" || chunk.Type == "reasoning-delta" || chunk.Type == "tool-input-delta"
}

// The runner callback accepts token deltas into at most 32 events/64 KiB of
// owned memory. It is not a durability acknowledgement. Only persist publishes
// chunks to clients, after a successful store append. All other callbacks wait
// for handle to finish. An unbuffered handoff provides producer backpressure.
// The consumer owns all mutable state and joins the runner before returning.
func runBatchedTurnOutputs(ctx context.Context, runner harness.Runner, request harness.Request, persist func([]json.RawMessage) error, handle func(harness.Output) error) error {
	runnerCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	type delivery struct {
		output harness.Output
		result chan error
	}
	outputs := make(chan delivery)
	done := make(chan error, 1)
	go func() {
		done <- runner.Run(runnerCtx, request, func(output harness.Output) error {
			item := delivery{output: output, result: make(chan error, 1)}
			// Cancellation still permits the runner's final continuation/session
			// output. The owning consumer stays alive until Run has returned.
			outputs <- item
			return <-item.result
		})
	}()
	var pending []json.RawMessage
	var size int
	var failure error
	var timer *time.Timer
	var ticks <-chan time.Time
	var deadline time.Time
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	fail := func(err error) error {
		if err != nil && failure == nil {
			failure = err
			cancel()
		}
		return err
	}
	flush := func() error {
		if timer != nil {
			timer.Stop()
		}
		ticks, deadline = nil, time.Time{}
		chunks := pending
		pending, size = nil, 0
		if len(chunks) == 0 {
			return nil
		}
		// Never replay an uncertain append after an I/O failure.
		return fail(persist(chunks))
	}
	for {
		// A continuously ready producer must not starve the latency bound.
		if !deadline.IsZero() && !time.Now().Before(deadline) {
			_ = flush()
		}
		select {
		case <-ticks:
			_ = flush()
		case err := <-done:
			flushErr := flush()
			return errors.Join(failure, err, flushErr)
		case item := <-outputs:
			if failure != nil {
				item.result <- failure
				continue
			}
			output := item.output
			var err error
			if batchableTurnOutput(output) {
				if size+len(output.Chunk) > store.MaxUIChunkBatchBytes {
					err = flush()
				}
				if err == nil {
					if len(pending) == 0 {
						deadline = time.Now().Add(turnChunkBatchDelay)
						if timer == nil {
							timer = time.NewTimer(turnChunkBatchDelay)
						} else {
							timer.Reset(turnChunkBatchDelay)
						}
						ticks = timer.C
					}
					pending = append(pending, bytes.Clone(output.Chunk))
					size += len(output.Chunk)
					if len(pending) == store.MaxUIChunkBatchEvents || size == store.MaxUIChunkBatchBytes {
						err = flush()
					}
				}
			} else {
				if output.Type != "heartbeat" {
					err = flush()
				}
				if err == nil {
					err = handle(output)
				}
			}
			item.result <- fail(err)
		}
	}
}
