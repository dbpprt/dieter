# Proposal: Antigravity harness (Google `agy`)

Status: proposal 2026-10-29 · implementation open in
[#173](https://github.com/dbpprt/dieter/pull/173) · scope: one adapter in
`internal/harness/runtime` (`antigravity-runtime.mjs`), a stdio MCP proxy
(`antigravity-host-tools.mjs`), a catalog entry, one dispatch case in
`runner.mjs`, user docs and changelog · no Go, proto, client or gateway
changes, no compatibility floor

## TL;DR

Google's Antigravity CLI (`agy`) runs Gemini, Claude and GPT-OSS models
behind one sign-in. This proposal adds it as a sixth harness. Each turn is one
headless `agy --output-format stream-json` run in the session's work
directory; later turns continue it with `--conversation`, so `agy` keeps the
history. Antigravity's own tools show as provider-executed tool calls.
Dieter's host tools reach `agy` as an MCP server.

Most of the adapter is a straightforward stream translation. Five decisions
deserve a maintainer's view before review of the code (§5):

1. **Registering an MCP server in `agy`'s own configuration.** The CLI has no
   per-run MCP flag, so the adapter runs `agy mcp add dieter …` once per
   worker process. That writes one entry outside `DIETER_HOME`.
2. **A second loopback listener** for host tools, alive only while a turn
   offers them, guarded by a per-session bearer token.
3. **Permissions.** The runner always asks for `allow-all`, so in practice the
   adapter always passes `--dangerously-skip-permissions`.
4. **A static model list** in the catalog instead of discovery.
5. **Instructions in the first prompt**, because headless `agy` has no
   system-prompt flag.

## 1. Goals and non-goals

Goals:

1. Conversations, cards and schedules can use Antigravity like any other
   harness: model and effort between turns, durable history, usage, abort,
   compaction.
2. Host tools (`present_content`, the background process tools) work in
   Antigravity turns.
3. Failures read as one plain sentence; raw stderr and stack traces stay out
   of the conversation.
4. Nothing changes for the five existing harnesses, the daemon or the
   clients.

Non-goals:

- Installing or signing in `agy`. It must be installed and signed in on the
  execution machine, as the other CLIs are; Dieter stores no credentials.
- Suspend/continue, mid-turn messages, history reads and image input: the CLI
  offers none of them (§3).
- Model discovery in this change (§5.4).

## 2. What exists today (code facts)

| What               | Where                                                                                                                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Harness catalog    | `internal/harness/catalog/harnesses.yaml`: `codex`, `claude-code`, `pi`, `omp` (`omp-acp`), `dsh` (`dsh-acp`); per harness `adapter`, `capabilities`, `defaultModel`, `effort`, `models`; overridable by `$DIETER_HOME/harnesses.yaml` |
| Adapters           | `@ai-sdk/harness-*` packages (Codex, Claude Code, Pi, ACP) pinned in `internal/harness/runtime/package.json`; Dieter-side wrappers such as `claude-runtime.mjs`, `codex-runtime.mjs`, `omp-runtime.mjs`                                |
| Dispatch           | `runner.mjs`: `switch (adapter)` creates the harness, then one `HarnessAgent` per turn                                                                                                                                                 |
| Host tools         | `runner.mjs`: `present_content` (`createContentPresentationTool`) and the background process tools are passed as `tools` to `HarnessAgent`; the SDK packages deliver them to their CLI                                                 |
| Permission mode    | `runner.mjs`: `permissionMode: "allow-all"` for every harness                                                                                                                                                                          |
| Discovery          | `internal/harness/discovery.go` plus `omp-discovery.mjs`, `dsh-discovery.mjs`; Codex follows its CLI's live catalog; others use the YAML list                                                                                          |
| Worker environment | allowlisted (`Environment.harnessEnvironment`, `internal/harness/harness.go`), extended by `DIETER_HARNESS_ENV` ([threat model](../threat-model.md))                                                                                   |
| Sandbox            | none; harness workers run as the daemon user ([invariants](../invariants.md#execution)); harness-level approval settings still apply                                                                                                   |

There is no `@ai-sdk/harness` package for Antigravity, so the adapter
implements `HarnessV1` itself, like the Dieter-side wrappers do for parts of
the other harnesses.

## 3. How `agy` behaves (observed with agy 1.4.8)

- `agy --output-format stream-json` reads the prompt from stdin and writes
  one JSON event per line: `init` (conversation id, model, tools, permission
  mode), `step_update` (text deltas, tool steps with parameters, output and
  errors, system messages, checkpoints), and `result` (status, response, error,
  usage).
- A step's `usage` is that model request (its input tokens are the context it
  saw); the result's `usage` is the sum over the turn. Thinking is counted
  (`thinking_tokens`) but not streamed.
- `--conversation <id>` continues a stored conversation. If `agy` no longer
  has it, it warns and silently starts a new one.
- Model ids carry their reasoning level (`gemini-3.8-flash-high`,
  `claude-opus-5-5-low`); `agy` rejects an `--effort` that differs from it.
- Headless runs deny tool use unless `--dangerously-skip-permissions` is set.
- MCP servers come only from `agy`'s config
  (`~/.gemini/config/mcp_config.json`, managed with `agy mcp add`); a call
  shows as the tool `call_mcp_tool` with `{ServerName, ToolName, Arguments}`.
- On failure, stderr carries one `AGY_ERROR: {…}` line (quota, sign-in, …).
- There is no system-prompt flag, no mid-turn input, no suspend, no history
  read and no image input in headless mode.

## 4. Design (as implemented in #173)

| Harness surface   | Behaviour                                                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Turn              | One `agy` child process, argument array (no shell), prompt on stdin; `--model`, `--effort` (omitted for ids with a level), `--conversation` after the first turn          |
| Session state     | `{conversationId, instructionsApplied}` in the harness resume data; the first `init` event provides the id                                                                |
| Instructions      | Prepended to the first prompt of a conversation inside `<instructions>`; not repeated on later turns                                                                      |
| Text and tools    | Text deltas stream; `agy`'s own tools become provider-executed tool calls with their output or error                                                                      |
| Host tools        | MCP server `dieter` (§5.1, §5.2); a call becomes a host `tool-call`, `submitToolResult` answers `agy`; `agy`'s own `call_mcp_tool` step for it is not shown a second time |
| Usage             | Each model request closes a step with its own usage; the turn total stays `agy`'s sum                                                                                     |
| Compaction        | `doCompact` runs `agy`'s `/compact` on the stored conversation                                                                                                            |
| Lost conversation | The turn restarts without `--conversation`, with the instructions, and a one-line note in the chat says the earlier history is gone                                       |
| Abort             | Aborting the turn stops the `agy` process                                                                                                                                 |
| Errors            | `AGY_ERROR` and the result error become one sentence; stderr and stacks are not shown                                                                                     |
| Unsupported       | Suspend, continue and mid-turn messages throw `HarnessCapabilityUnsupportedError`; images reach the agent as files (`local-attachments.mjs`)                              |
| Catalog           | `id: antigravity`, `model-selection` and `effort-selection` between turns, default `gemini-3.8-flash-high`, a static list of 13 model ids                                 |

## 5. Decisions for review

### 5.1 Writing one entry into `agy`'s configuration

The CLI offers MCP servers only from its config file. The adapter therefore
runs `agy mcp add dieter <node> <proxy>` once per worker process. It is an
add-or-update of that single entry; nothing else in the file changes. If it
fails, the turn runs without host tools and says so in a stream warning.

This is a write outside `DIETER_HOME`, on the user's own `agy` setup. The
entry is harmless outside Dieter (the proxy offers no tools without a running
turn), but it is visible in `agy mcp list` and points at the runtime's path;
the next worker process rewrites it if that path changed.

Options:

- **A (as implemented):** register on first use, document it in
  `harnesses.md`.
- **B:** register only when the user opts in (a catalog option or
  `DIETER_HARNESS_ENV` flag); without it, Antigravity turns have no host
  tools.
- **C:** wait for a per-run MCP flag in `agy` and drop the registration.

Recommendation: A now, C when `agy` allows it. The alternative of shipping no
host tools makes `present_content` and background processes silently
unavailable in one harness only.

### 5.2 A second loopback listener

The proxy that `agy` starts cannot reach the worker's in-process tools, so the
adapter serves the running turn's tools over HTTP on `127.0.0.1` with a random
port and a per-session random bearer token (24 bytes). The endpoint exists
only while a turn offers tools; the URL and token are passed to `agy` through
its environment (`DIETER_AGY_TOOLS_URL`, `DIETER_AGY_TOOLS_TOKEN`) and removed
for turns without tools.

Consequences for the [threat model](../threat-model.md#local-attackers-on-a-daemon-host):

- Like the raw API, other local users can reach the port but not the token.
- Processes the agent starts inherit `agy`'s environment and can call the
  current turn's host tools. They run as the same agent, so this grants
  nothing the agent cannot already do.
- Follow-ups worth considering: a constant-time token comparison, and a Unix
  socket under `DIETER_HOME/runtime` (mode 0600) instead of a TCP port.

The threat model gains one bullet under "Local attackers on a daemon host"
when this lands.

### 5.3 Permissions

The adapter passes `--dangerously-skip-permissions` only for `allow-all`. The
runner asks every harness for `allow-all`, so today every Antigravity turn
runs without `agy`'s prompts, as the other harnesses run without theirs. This
matches the execution invariant (no sandbox, no policing of tool calls). The
explicit check keeps a future non-`allow-all` mode safe: headless `agy` then
denies tools instead of hanging on a prompt.

### 5.4 Static model list

The catalog lists 13 ids from `agy models` at the time of writing. They will
go stale. The established pattern is discovery (`omp-discovery.mjs`,
`dsh-discovery.mjs`, `discovery.go`). Proposal: land the static list, which
keeps existing conversations resumable, and add `agy models` discovery as a
separate change if maintainers want Antigravity to stay in the catalog.

### 5.5 Instructions in the first prompt

Without a system-prompt flag, Dieter's instructions lead the first prompt of
the conversation inside `<instructions>` and are recorded as applied in the
resume data. After a lost conversation (§4) they are sent again. Compaction
is `agy`'s own and may summarise them; the other harnesses keep instructions
outside the history.

## 6. Verification

- `antigravity-runtime.test.mjs` (10 tests) drives the adapter against a
  stand-in `agy` and needs no network: streaming and conversation id,
  model ids with a level, permission flag, host tools through the proxy, the
  proxy outside a turn, lost conversation, quota failure, abort, compaction,
  unsupported capabilities.
- Manual: agy 1.4.8 with Gemini 3.8 Flash, including a host tool round trip.
- Not covered: a CI job with a real `agy` (needs a signed-in account) and the
  Go suites, which this change does not touch. `just check-changed` and
  `just lint` should be run before merge.

## 7. Open questions for maintainers

1. Is a write into `agy`'s config acceptable (option A), or should host tools
   be opt-in (B)?
2. TCP loopback with a bearer token, or a Unix socket in `DIETER_HOME/runtime`?
3. Static models now and discovery later, or discovery in the same change?
4. Should Antigravity be marked experimental in the catalog and docs until it
   has discovery and a longer track record?
