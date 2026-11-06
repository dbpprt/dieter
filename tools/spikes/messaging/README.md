# Agent messaging spike

Spike code for [docs/proposals/agent-messaging.md](../../../docs/proposals/agent-messaging.md).
It is evidence, not product code: nothing in the main module imports it.

`driver.mjs` builds a `HarnessAgent` the way
[`runner.mjs`](../../../internal/harness/runtime/runner.mjs) does: same
adapters (`createLocalClaudeCode`, `createLocalCodex`), same local sandbox,
`permissionMode: "allow-all"`, and a host tool (`board_read`) passed like
`present_content`. It then injects board notices with
`session.experimental_steerTurn` and records every stream part, every steer
request and its outcome, and per-request token usage.

| Scenario       | What it measures                                                                 |
| -------------- | -------------------------------------------------------------------------------- |
| `steer-mid`    | Header-only notice after the first tool result; the body must be pulled          |
| `steer-inline` | Same task; the body is inside the notice                                         |
| `steer-burst`  | Three inline notices back to back (coalescing)                                   |
| `steer-long`   | Notice while a 25 s shell command runs (does it wait for the tool?)              |
| `steer-late`   | Notice while the final answer streams, then one after the `finish` part (race)   |
| `wake`         | Turn 1 builds context; the session stops like a Dieter worker; turn 2 resumes it |

## Spike v2: push and pull (`atrium.mjs`)

`atrium.mjs` runs one or two agents against a shared checkout and an
in-process channel board on loopback HTTP:

- Host tools `channel_post`, `channel_inbox` and `channel_check`.
- `hook.mjs` as a `PreToolUse`/`PostToolUse` hook command:
  - **Claude:** a user `settings.json` in a per-agent `CLAUDE_CONFIG_DIR`.
  - **Codex:** `codexConfig.hooks` with a trusted hash.
- Automatic claims from writes, deny plus heads-up on conflict, release at
  turn end, and steer or wake for waiters.

| Scenario                   | What it measures                                                                               |
| -------------------------- | ---------------------------------------------------------------------------------------------- |
| `probe`                    | Which hooks fire through Dieter's adapters, tool names, whether `deny` is honoured             |
| `pull-check`               | Agent told to call `channel_check` first; Z holds `src/module3.js` and releases it after 20 s  |
| `pull-hook`                | Same, without the instruction; hooks enforce the claim                                         |
| `push-hook` / `push-steer` | A task-relevant post arrives mid-turn through `PostToolUse` context or through steer           |
| `pair`                     | Agents A and B with overlapping files and commits (`--a`, `--b`); `--no-board` is the baseline |

```sh
mise exec -- node atrium.mjs --scenario pair --a claude-code --b codex --out results/atrium/pair-claude-codex.jsonl
mise exec -- node atrium.mjs --scenario pair --a claude-code --b codex --no-board --out results/atrium/pair-baseline-claude-codex.jsonl
node atrium-report.mjs results/atrium/*.jsonl
```

Each run keeps `git-log.txt` (with `-p`) and `git-status.txt` next to the
transcripts, to verify commit attribution.

## Running

```sh
cd tools/spikes/messaging
mise exec -- node driver.mjs --harness claude-code --scenario steer-mid --out results/claude-steer-mid.jsonl
mise exec -- node driver.mjs --harness codex --scenario wake --out results/codex-wake.jsonl
node analyze.mjs results/*.jsonl
```

The harness runtime's `node_modules` must be installed (`just setup`).
Defaults: `claude-sonnet-5-5` and effort `low` for Claude; for Codex, the
operator's `~/.codex/config.toml` model with effort `low`. Override with `--model`.

## Credentials and isolation

Parent mode creates one temporary root and runs the scenario in a child with
a scrubbed environment (no `DIETER_*`, `CLAUDE_CODE_*` or `ANTHROPIC_*`,
and `HOME` pointing into the temporary root). It removes the root afterwards.

- **Claude:** only the access token, from the keychain item
  `Claude Code-credentials`, passed as `CLAUDE_CODE_OAUTH_TOKEN` with a
  fresh `CLAUDE_CONFIG_DIR`. The refresh token is never read out.
- **Codex:** a temporary `CODEX_HOME` with a copy of `~/.codex/auth.json`
  whose refresh token is replaced. It refuses tokens with less than 2 hours left.

The run copies the harness transcripts (`*.jsonl.transcripts/`) out before it
deletes the root. They show where an injected message landed in the model's
context. `auth.json` is never copied. The operator's daemon, `DIETER_HOME`,
`~/.claude` and `~/.codex` are not touched.

## Results (2026-10-24)

- `results/*.jsonl` holds v1, one JSONL per run plus transcripts. Each
  cell is one run, except Claude `steer-mid`, which ran twice with the same
  outcome.
- `results/atrium/` holds v2, and `live/results/` the live runs on an isolated
  daemon (`live/*.sh`, including `verify1-after-fixes` with the product build).
- Raw harness transcripts, per-run `git-log.txt` and logs are kept out of the
  repository at `/Volumes/External/dieter-spike/messaging-2026-10-24/` under the
  same relative paths. `analyze.mjs` and `atrium-report.mjs` read Codex request
  counts from the transcripts: copy them back next to the JSONL files first.
- The findings are in the proposal: §3.2–3.4 for v1, §3.6 for v2.
