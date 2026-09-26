# Background waiters in OMP and Claude

Investigated on 2026-09-26 against Dieter v0.4.303 on mini-home.

## Observed failure

The screenshot's task to pull changes and run the Mac tests used OMP with
`tailscale/glm-5.3-flash-exl3`. Its only assistant response ended at
08:57:01 UTC, saying `just mac test` was running and promising to report its
result. The daemon then marked the conversation Idle.

The test command's tool result said:

> Backgrounded as job bg_1; its output is injected into the conversation as a
> follow-up the moment it finishes. Do NOT poll for it ... Do other work, or
> end your reply and wait to be woken.

Its structured output reported `async.state=running`, `jobId=bg_1`, and
`type=bash`. The model explicitly reasoned that it should end the reply and
wait for the background job to wake it. The Dieter CLI's remote process list
for that card on mini-home returned no registered executions.
This was an OMP-owned job, not a Dieter process. The transcript contains no
test completion or exit status; this investigation cannot establish whether
the tests completed before provider cleanup.

## Cause

- OMP 18.2.11 enables native async execution and automatic backgrounding by
  default. Its ACP `#waitForAcpPromptIdle` drains already queued deliveries;
  `drainAsyncJobDeliveriesForAcp` returns immediately when none is queued. A
  still-running job therefore does not keep the ACP prompt open.
- Dieter's runner stops the provider session after the stream completes and
  cleans up its child processes. No provider completion can start another
  Dieter turn after that point.
- The pinned Claude harness bridge similarly closes its SDK query on a
  successful `result` when there are no active user messages. It does not
  keep that query open for native background tasks. This is a code-confirmed
  exposure; no separate failing Claude conversation was established here.
- Dieter's process manager is independent of provider sessions. Registered
  executions survive a turn, but their completion currently does not admit
  a new conversation turn either.

## Prevention

The OMP runtime overlay disables `async.enabled`,
`bash.autoBackground.enabled`, and `eval.autoBackground.enabled`. Claude gets
`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` through the adapter's SDK environment
on both new and resumed sessions. Native tools therefore return their result
within the active provider turn. Background commands go through Dieter's
existing process tools, with explicit instructions to collect required
results before the final reply and verify readiness for persistent servers.

This prevents the unsupported provider wake-up path; it does not implement
automatic wake-up for Dieter processes. The change must be released and
installed before it affects the operator daemon. A previously ended task
will need a human follow-up and may need its checks rerun if the native job
result was lost. No live daemon was restarted, no follow-up was sent to the
affected card, and the Mac test suite was not rerun by this investigation.

## Validation

- `just harness test`: all 79 tests passed. The new Claude test drives the
  pinned adapter and real WebSocket bridge with an offline SDK fixture,
  checking the environment on both fresh and resumed turns. It does not call
  a live provider. The OMP regression checks its runtime overlay.
- `just check-changed --dry-run` selected the affected Go packages and harness
  tests. The initial `just check-changed` failed on two unchanged tests:
  `TestEnsureManagedBunPublishesAndReusesExactVersion` and
  `TestAutoRunStartsAlongsideOtherConversations`. All other selected Go
  packages passed with the race detector.
- The complete scheduler package passed on an isolated rerun. The complete
  harness Go package passed with `TMPDIR` set to the canonical macOS temp
  directory (`/private/var/...`); its existing Bun containment check compares
  an unresolved installation path against a resolved executable and rejects
  the equivalent `/var/...` alias. That separate path issue was not changed.
- All selected `go vet` checks and `git diff --check` passed. No native app
  sources or schemas changed, so native integration tests were not selected.
