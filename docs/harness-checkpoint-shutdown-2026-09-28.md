# Preserve harness checkpoints during shutdown

The product-assessment task failed during a daemon update. Its worker reported
`decode harness worker output: unexpected end of JSON input`, and daemon shutdown
then reported that the conversation had no suspended turn continuation.

The worker queued its continuation on stdout and called `process.exit()` before
Node finished writing to the pipe. An isolated reproduction delivered only
65,536 bytes of a 1,048,637-byte JSON message. Waiting for the write callback
delivered the complete message.

## Change

- Every explicit worker exit now waits for a stdout write barrier. Exit is
  shared between competing shutdown paths, heartbeats stop, and late events
  cannot enqueue output behind the barrier. Existing host shutdown deadlines
  still bound an unresponsive worker.
- Suspension failures retain their nonzero exit code even when stream cleanup
  also enters the worker's exception handler.
- Durable error events mark unfinished subagents failed and abandon tasks that
  were in progress. Completed subagents and their saved findings are preserved.
- Conversation projection version 6 rebuilds older checkpoints from their
  authoritative event journals, correcting stale Running labels on historical
  failures. Successful suspension emits no error/abort and preserves active work.

## Regression coverage

- The real worker runs against a deterministic provider fixture with stdout
  backpressure and a 1.1 MB checkpoint. SIGUSR1 suspension preserves the full
  checkpoint; the next worker continues the same turn without repeating its
  initial tool call. SIGINT/SIGTERM flush session and terminal subagent events.
- Failed suspension exits unsuccessfully without inventing a continuation.
- The real Go subprocess decoder and daemon turn lifecycle process truncated
  checkpoints and worker crashes. Reopening the store retains the failure and
  terminal capability states, including completed research.
- A version 5 checkpoint with stale Running children is rebuilt correctly.
- Existing graceful-restart tests cover all five providers with the race detector.
- The process-group fixture waits for child readiness with a bounded deadline
  and always stops its processes, including when a readiness assertion fails.
  This removes a startup race exposed by the full harness run under build load.

Validation passed: dependency-selected Go race tests and `go vet`, plus all 83
tests in `just harness test`. The initial parallel Go run hit existing short
deadlines in scheduler/server tests; both complete packages passed when rerun
serially. Native integration was outside this fix's scope; concurrent native
edits were excluded from its selected checks and commit.

Tests use disposable processes and storage. They do not restart or replace the
operator's daemon. The fixed worker applies to turns using the updated runtime;
an already active turn retains its pinned runtime across an update.
