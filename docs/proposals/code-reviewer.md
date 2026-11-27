# Proposal: a code reviewer for agent conversations (pr-agent spike)

Status: implemented, 2026-11-27 (decisions in section 7, implementation in
section 8) · scope: engine,
harness runtime, API and CLI, replicated settings, Kotlin core, Mac and Compose
UI · spike code and evidence: [tools/spikes/review](../../tools/spikes/review/README.md)

## TL;DR

The request: integrate the open-source
[pr-agent](https://github.com/The-PR-Agent/pr-agent) into Dieter.

- **One global setting** picks the reviewer's harness and model.
- **A toggle on a new task** enables the reviewer. It is offered to the
  working agent as a function, with instructions.
- **The review runs on a Dieter-managed harness.**
- **Its findings show up in the chat.**

The spike ran the **unmodified pr-agent 0.50.0 CLI with a Dieter harness turn
as its model**. A small `BaseAiHandler` sends each model call through
`internal/harness/runtime/runner.mjs`, the same worker that runs card turns.
The spike also ran a native agentic review through the same worker, on one
fixture: a real Dieter commit (#227, a 998-line diff) with three planted bugs.

| Configuration (Claude Code harness)           | Time      | Planted bugs found | Other findings                    |
| --------------------------------------------- | --------- | ------------------ | --------------------------------- |
| pr-agent, diff only, Sonnet                   | 20 s      | 1 of 3             | 1 false positive                  |
| pr-agent, diff only, Opus                     | 174 s     | 1.5 of 3           | 1 unverified                      |
| **pr-agent prompt + read the checkout, Opus** | **42 s**  | **3 of 3**         | none                              |
| native agentic review, Opus (2 runs)          | 192–241 s | 3 of 3             | **a real, shipped Dieter bug** ×2 |
| any configuration on Sonnet                   | 20–22 s   | 1 of 3             | false or unverified claims        |

What the numbers say:

1. **Giving the reviewer the checkout matters most.** The same Opus prompt went
   from 1.5 to 3 of 3 once it could run read-only commands to confirm what the
   diff implies.
2. **The model matters next.** Sonnet found one of three bugs in every setup
   and invented a plausible but false regression.
3. **Prompt framing sets cost and depth.**
   - pr-agent's single-pass prompt with the diff inlined: 42 s, 3 tool calls,
     224k input tokens.
   - A "verify every finding" prompt: 3–4 min, 15–24 tool calls, 0.9–1.4M input
     tokens (mostly cache reads). It also found a real latent bug in shipped
     code: `git show` honours `log.showSignature`, and `internal/git/exec.go`
     merges stderr into the patch.
4. **pr-agent's value is its review contract, not its runtime.** The contract
   is the rubric, the diff format, the finding schema and the config knobs.
   - Embedding pr-agent adds a third runtime to Dieter: Python 3.12+ and a
     237 MB venv.
   - pr-agent changes daily (0.49 → 0.50 during the spike), and the handler
     swap the spike used is a monkeypatch, not a public API.
   - Its exit code was 0 when every model call failed.

**Recommendation.** Build a native **reviewer** in the daemon that adopts
pr-agent's contract (MIT, attributed): its rubric, its finding shape and its
knobs. It runs a Dieter harness turn read-only on a disposable snapshot of the
card's workspace and offers two depths:

- **Quick** (default): the pr-agent-style single pass. pr-agent's own prompt
  took 42 s on Opus.
- **Thorough**: every finding verified, 3–4 min.

The reviewer reaches the agent as a `request_code_review` host tool with a CLI
fallback. Findings are stored as a typed `data-code-review` message part that
every client renders as a findings card. They are also returned to the agent as
the tool result.

**If you want pr-agent itself in the loop** (section 5, alternative B), the
spike shows the integration seam works: it ships as a managed, pinned Python
runtime, and its model calls go back over a pipe to the daemon. Everything
else in the design stays the same.

**Effort.** Phase 1 (engine, tool, CLI, setting) is about 2 weeks; Phase 2
(client UI) about 1.5 weeks.

## 1. What pr-agent is (verified in source, 2026-11-27, `4d993c2`, PyPI 0.50.0)

| Aspect     | Facts                                                                                                                                                                                                                                                                                                                           |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Project    | `The-PR-Agent/pr-agent`, **MIT** (no longer AGPL). Community-maintained "legacy project of Qodo", sponsored by Qodo. Very active: several commits a day, minor releases weekly.                                                                                                                                                 |
| Runtime    | Python ≥ 3.12, about 190 packages (LiteLLM, Dynaconf, FastAPI, tiktoken, OpenTelemetry, …). `uv pip install pr-agent` takes 7.7 s warm and makes a 237 MB venv.                                                                                                                                                                 |
| Commands   | `review` (it now absorbs `improve`), `describe`, `ask`, `generate_labels`, `update_changelog`, `add_docs`, `doctor`. Dispatch: `pr_agent/agent/pr_agent.py` → `pr_agent/commands/*`.                                                                                                                                            |
| Targets    | Hosted PRs (GitHub, GitLab, Bitbucket, Azure DevOps, Gitea, Gerrit, CodeCommit), the local git provider, and **plain-diff mode**: `--diff-file=PATH` or `--stdin`, with `--output` (Markdown) and `--json-output` (structured review).                                                                                          |
| Model seam | `BaseAiHandler.chat_completion(model, system, user, temperature) -> (text, finish_reason)` (`pr_agent/algo/ai_handlers/base_ai_handler.py`). `PRAgent(ai_handler=…)` accepts any handler; the default is LiteLLM with API keys.                                                                                                 |
| Review     | One prompt (`pr_agent/settings/pr_reviewer_prompts.toml`, Jinja2) with the diff rendered as `__new hunk__`/`__old hunk__` blocks with line numbers, token-budgeted (`config.max_model_tokens`, default 32000) and chunked for large PRs. The model answers YAML matching a Pydantic-described `Review` schema.                  |
| Output     | `key_issues_to_review[]` (`relevant_file`, `issue_header`, `issue_content`, `start_line`, `end_line`), `estimated_effort_to_review_[1-5]`, `relevant_tests`, `security_concerns`, plus optional score, TODO scan, risk, merge recommendation, failure modes and priority files. `Finding` model in `pr_agent/algo/findings.py`. |
| Knobs      | `num_max_findings` (6), `extra_instructions`, `min_finding_confidence`, `require_*` toggles, `enable_risk_checks` with `sensitive_paths` globs (deterministic), ignore globs for generated code and lock files, persistent finding state so a re-review keeps earlier wording instead of re-raising.                            |

Two other harness-native options came up:

- **Codex** has a native review mode: app-server `review/start` with
  `ReviewTarget::BaseBranch | UncommittedChanges | Commit | Custom`. It returns
  structured findings (`title`, `body`, `priority`, `confidence_score`,
  `code_location`) and an overall verdict. These strings are in the bundled
  codex-cli 0.164.0.
- **Claude Code** has `/review` and `/security-review` prompts, but no
  structured output.

## 2. The spike

### 2.1 How a Dieter harness answers pr-agent

`tools/spikes/review/dieter_handler.py` implements `BaseAiHandler`. Each
`chat_completion` writes one worker request to `node runner.mjs`:

- `prompt` = pr-agent's user prompt and `instructions` = its system prompt;
- a fresh `sessionId` and `runtimeRoot`;
- `projectPath` = an empty directory, or the checkout for the "+ workspace"
  runs;
- `auth: {}` for Claude Code, the object provider-account turns send.

That is exactly how quick-task titles call a harness
(`internal/engine/conversation_creation.go`, `generateQuickTaskTitle`). The
handler collects `text-delta` chunks and records timing, frames, tool calls and
usage. `run_pr_agent.py` runs pr-agent's own CLI with the handler swapped in.
pr-agent then did its normal work unchanged (diff parsing, budget, prompt,
YAML parse, JSON output) and wrote `review.json`.

`native_review.py` is the comparison. It runs one agentic turn in the checkout
with a pr-agent-derived rubric: bugs, security and performance problems only,
a concrete trigger scenario for each, and at most N findings. It asks for a
JSON schema close to pr-agent's (`file`, `start_line`, `end_line`,
`severity`, `confidence`, `title`, `body`, `suggestion`) and tells the agent
to confirm each finding in the code before reporting it.

### 2.2 Fixture

`make_fixture.sh` clones the repository (`--shared`) at `526f3387` ("Support
the full worktree lifecycle in empty repositories", #227) and plants three
bugs as uncommitted edits. The change under review is everything since base
`071f756f`, which is what a card's worktree diff would show.

| Bug | Edit                                                                            | Consequence                                                                                                      |
| --- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| B1  | `internal/git/unborn.go`: `command.ExitCode == 1` → `!= 0`                      | A fatal `rev-parse` error (128) reads as an empty repository, so an orphan worktree gets an empty base for good. |
| B2  | `internal/git/operations/manager.go` `checkInitialCheckout`: `\|\|` → `&&`      | The first merge into an unborn base can delete an ignored directory or follow a symlink ancestor.                |
| B3  | `internal/git/workspace/manager.go` `Ensure`: `defer release()` → `_ = release` | The repository lock leaks, so later provisioning and merges block.                                               |

### 2.3 Results

All runs used the Claude Code harness on the operator's own Claude login, one
run each except `native-opus` (two). The full table, with token breakdowns, is
in the [spike README](../../tools/spikes/review/README.md#results-2026-11-27-claude-code-harness-one-run-each-unless-noted).

- **Recall.**
  - Every configuration found B3.
  - Only Opus with read access to the checkout found B1 and B2 reliably: all
    four such runs found 3 of 3.
  - Opus with the diff alone found 1.5 (it described B2's symptom but blamed
    the original design).
  - Sonnet found 1 of 3 in all three setups. Under pr-agent's prompt it made
    no tool calls, even with the checkout available.
- **Precision.**
  - Sonnet twice reported the same false "merge-commit diff regression".
    Verified false: for a clean merge, the old `git diff M^!` and the new
    `git show … M^0` are both empty.
  - The thorough native Opus reviewer twice reported a **real bug in shipped
    code**. `git show` honours `log.showSignature`: `git -c
log.showSignature=true show --format= 526f3387^0` prints a gpg line, and
    `git diff 526f3387^!` does not. Dieter's git runner merges stderr into
    the output (`internal/git/exec.go:55`), so Changes commit patches pick up
    signature lines for users with that setting. Worth its own fix.
- **Cost and latency.**
  - pr-agent's single-pass prompt: 42 s and 224k input tokens on Opus, about
    20 s on Sonnet.
  - Verification-heavy native prompt: 190–240 s and 0.9–1.4M input tokens on
    Opus, 92–96 % of them cache reads.
  - Inlining the diff into the native prompt did not make it faster
    (194 s, 15 tool calls). Framing decides depth.
- **Read-only.** The reviewer edited nothing in any run (fixture `git status`
  unchanged), but only by instruction. The worker always runs with
  `permissionMode: "allow-all"`.
- **Codex: unmeasured.** The local `~/.codex` login was stale (401). The
  operator's Dieter-managed Codex login was deliberately not used.

### 2.4 pr-agent integration findings

- **The handler seam works and is small.** A handler only needs
  `chat_completion`. A fallback model just calls it again.
- **Its exit code is unreliable.** pr-agent exited 0 with "Failed to review
  PR" when every model call failed. A missing or empty `--json-output` is the
  only dependable failure signal.
- **JSON fields keep YAML block-scalar newlines** (`"relevant_file":
"internal/…/manager.go\n"`), and `usage` is empty unless the handler reports
  it.
- **The default 32k-token budget prunes large diffs.** Harness models need
  `config.max_model_tokens` raised.
- **Plain-diff mode reads no repository config.** Dieter would pass every knob
  as host config.
- **There is no supported embedding API.** The spike swapped
  `pr_agent.cli.PRAgent`. A production integration would need its own
  entrypoint that mirrors `cli.run` (about 60 lines) and would have to follow
  upstream changes to it.

## 3. Product shape

- **Global setting: Settings › Reviewer.** It holds:
  - the harness, model, effort and provider account the reviewer uses;
  - the depth (quick or thorough), the maximum findings (6) and the minimum
    confidence;
  - extra instructions, for example "we care about lock ordering";
  - ignore globs.

  It is one account-wide record, so every machine and client sees the same
  reviewer (the invariant: portable settings replicate). When the configured
  harness or account is unavailable on the card's machine, the review fails
  with that reason; it never falls back to another harness.

- **Task toggle: "Reviewer"** in the new-task sheet, the standalone chat start
  and schedules, next to vault and mail access. Unlike those it can be switched
  later from the conversation header, and it takes effect at the next turn. The
  conversation header shows a badge.
- **For the agent.** When the toggle is on, every turn gets a
  `request_code_review` tool and a short instruction: finish a change, request
  a review, fix what it agrees with, and state what it rejects and why.
  Harnesses that load host tools on demand get the CLI fallback
  `dieter card review CARD --wait`, as with `present_content`.
- **In the chat.** A findings card appears where the agent called the tool:
  - while it runs: "Reviewing changes · Opus · 0:38";
  - when done: "4 findings · 2 high", each with severity, `file:line`, a title,
    the body and an optional suggestion;
  - tapping `file:line` opens that file's diff in the Changes pane.

  A failed or cancelled review says so. Re-reviews show "2 resolved · 1 still
  open · 1 new".

- **Human-triggered (recommended):** a "Review changes" button in the Changes
  pane runs the same review on demand. Its findings card joins the transcript
  and reaches the agent as context with the next message.

## 4. Design (alternative A, recommended)

### 4.1 Review run (daemon)

New package `internal/engine/reviewer`, used by the engine (tool path) and the
API (CLI and button path).

1. **Resolve the workspace and base.** Use `changeset.Resolve` for the card's
   worktree or shared checkout.
   - Worktree cards: the base is `CurrentBaseSHA`, then `BaseSHA`, merge-based
     with HEAD. Strix uses the same order (`internal/engine/strix.go`
     `strixTurn.apply`).
   - Project-mode cards: there is no base SHA, so the change is the working
     tree against HEAD (uncommitted work). A setting can widen this to the
     merge base with the project's base branch.
2. **Snapshot without touching the card.**
   - Capture the working tree with a temporary index file under
     `DIETER_HOME/runtime/reviews/<id>`: `GIT_INDEX_FILE=… git add -A`, then
     `write-tree`, then `commit-tree -p HEAD`. This includes untracked files
     and leaves no ref behind.
   - Then run `git worktree add --detach DIETER_HOME/runtime/reviews/<id>/tree
<snapshot>`, the same mechanism card worktrees use.
   - The reviewer runs there, so even a misbehaving reviewer cannot touch the
     agent's tree, index or HEAD. It is removed with `git worktree remove
--force` when the review ends.
   - Very large checkouts can later use the APFS clone views from the
     agent-workspaces spike.
3. **Render the change.**
   - `git diff <base> <snapshot>` with renames, after dropping ignore globs
     (pr-agent's lists for lock files and generated code are the default).
   - Render it in pr-agent's hunk format with new-side line numbers, so
     findings cite real lines.
   - Inline it up to a budget (default 60k tokens). Over budget, inline the
     file list and stats and let the reviewer page through `git diff` itself;
     the measured native path shows that works.
   - Add pr-agent's deterministic risk notes for sensitive paths such as CI
     workflows, lock files, migrations and Dockerfiles.
4. **Run one harness turn.**
   - Resolve the selection from the reviewer setting: `Catalog.ResolveSelection`,
     then `Accounts.ResolveTurn` on the card's owner daemon, with the same
     sign-in refusal as card turns.
   - Build a bare `harness.Request` like quick titles: a fresh `SessionID`, its
     own `RuntimeRoot`, `ProjectPath` = the snapshot, no host tools, no steer.
   - Prompt: the rubric from pr-agent's `pr_reviewer_prompts.toml`, adapted and
     attributed. Depth `quick` = answer in one pass and use the checkout only to
     settle doubts. Depth `thorough` = confirm every finding.
   - The previous round's findings, and the agent's replies to them, go in as
     pr-agent's "previous findings" context, so a re-review classifies them as
     resolved, still open or new instead of rewording them.
   - Answer format: one JSON object (section 4.4).
5. **Parse and validate.**
   - Strip the fence and decode the JSON.
   - Drop findings whose file is not in the change.
   - Clamp line ranges to the new file.
   - Apply `min_confidence` and `max_findings`.
   - Keep the reviewer's raw text when decoding fails, as a failed review with
     the text attached.
6. **Record.**
   - A `ReviewRun` record (owner-local, `DIETER_HOME`, atomic writes):
     selection, base, snapshot SHA, timing, usage, status, findings.
   - The `data-code-review` part in the conversation.
   - Usage counted in the card's token usage and the provider account's
     usage.

**Bounds:**

- one running review per conversation;
- a timeout of 10 min (quick) or 20 min (thorough);
- findings ≤ 20, body ≤ 4 KiB each, raw text ≤ 64 KiB.

Cancelling the card's turn cancels its review; deleting the card removes its
snapshots.

### 4.2 Agent surface (harness runtime)

- **A request flag.** `harness.Request` gets `CodeReviewEnabled` and
  `ReviewCommand` (the CLI fallback).
- **A runtime bridge.** `internal/harness/runtime/code-review.mjs` copies
  `background-processes.mjs`:
  - a `request_code_review` tool with input `{ focus?: string }`;
  - a `code-review` frame on stdout, answered by a `code-review-result` line
    on stdin;
  - instructions appended like `backgroundProcessInstructions`.
- **The bridge must not block the daemon's read loop.** Today
  `replyProcessCall` answers synchronously with 30 s (daemon) and 35 s
  (worker) timeouts. The daemon handles `code-review` frames on a goroutine,
  inside `beginTurnHostWork` so the liveness watchdog doesn't blame the
  worker, and replies when the review ends.
- **Per-harness timeouts.**
  - **Claude:** SDK MCP tool calls are bounded only by `MCP_TOOL_TIMEOUT` or
    the server `timeout` option, "effectively unbounded by default"
    (`claude-agent-sdk` `sdk.d.ts`).
  - **Codex dynamic tools and ACP MCP:** neither bridge sets a timeout. Phase 1
    must measure both with a 5-min tool.
  - **If any harness caps it:** after N minutes the tool returns
    `{status: "running", reviewId}`, and a second tool
    `wait_for_code_review(reviewId)` resumes waiting.
- **Tool result.** A compact text list (id, severity, `file:line`, title,
  body, suggestion), capped at about 8k characters. The client UI uses the
  data part, not this result: clients only receive a 160-character preview of
  tool output.
- **Instruction** (appended in `prompt.ResolveForWorkspace` like
  `VaultInstructions`): "This conversation has a code reviewer. When a change
  is complete, before you report it done, call `request_code_review` (or run
  `dieter card review CARD --wait`). Fix the findings you agree with; for the
  rest, say why. After substantial fixes, request one more review. Do not
  request more than three per task." The round cap is a setting.

### 4.3 Protocol, settings and CLI

| Item           | Change                                                                                                                                                                                                                                                                                                                                                           |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Per-card flag  | `bool code_review = …` on `Card` (next free 50), `CreateConversationRequest` (28), `DraftAgentSettings` (6), `ScheduleDraft` (44) and `Schedule`, and client `CreationIntent` (17). Owner-local like `vault_access`. Unlike it, editable after creation via `UpdateCardRequest`.                                                                                 |
| Global setting | A KV record in a new namespace `reviewer-settings`, key `default`. Daemon-written with compare-and-set like `provider-account-defaults`, validated on write and ingest. The value holds harness, model, effort, account ID, depth, limits, instructions and globs.                                                                                               |
| RPCs           | `SettingsService.GetReviewerSettings` / `UpdateReviewerSettings`. `CardService.ReviewChanges` (start; `wait` streams to completion) and `GetCodeReview(review_id)`. Local, direct-TLS and relay coverage, per the CLI parity rule.                                                                                                                               |
| CLI            | `dieter reviewer show`, `dieter reviewer update --harness H --model M [--effort E] [--account A] [--depth quick\|thorough] …`, `dieter card review CARD [--wait] [--focus TEXT] [--json]`, `dieter card create … --reviewer`.                                                                                                                                    |
| Transcript     | A `data-code-review` message part (`data_json` ships in full to clients) with `{reviewId, status, harness, model, depth, baseSha, snapshotSha, startedAt, finishedAt, findings[], summary, security, round, resolved[]}`. It is appended to the turn's response message at the tool call, as `AppendPeerNotice` does, and updated in place from running to done. |
| Client core    | `TimelineStepKind.CODE_REVIEW` plus a typed `CodeReview` slice model in `client.proto`, mapped in `SliceMappers.kt`. The core owns severity ordering, round diffing (resolved, open, new) and the Changes deep link.                                                                                                                                             |

### 4.4 Finding schema

pr-agent's `Finding`, extended with a stable ID and severity:

```json
{
  "id": "f1",
  "file": "internal/git/workspace/manager.go",
  "startLine": 178,
  "endLine": 184,
  "severity": "high",
  "confidence": 9,
  "title": "Repository lock is never released",
  "body": "…trigger scenario and consequence…",
  "suggestion": "Restore `defer release()`.",
  "status": "new"
}
```

`status` is `new | open | resolved` relative to the previous round.

### 4.5 Clients

- **Mac:** a `CodeReviewCard` in `MessageParts.swift` `TimelineStepView`,
  next to `SubagentTimelineGroup`.
  - Collapsed: the counts and the highest severity.
  - Expanded: the findings, each with a link that opens the Changes pane at
    the file.
  - A toggle in `NewConversationSheet` and `StandaloneChatStartView`.
  - A Settings page in `DieterSettingsView` (harness and model pickers from the
    Agents page data).
  - A "Review changes" button in the Changes pane.
- **Compose:** the same card in `mobile/conversation/Timeline.kt` and the
  toggle in `CreationScreen.kt`. Compose has no settings page for prompts or
  agents today, so the reviewer setting starts as a single sheet.

All rules stay in the Kotlin core; the apps only draw.

### 4.6 Safety and threat model

- **The reviewer is a normal harness turn.** It runs as the daemon user
  without a sandbox, on a disposable snapshot. That protects the agent's work
  from accidents, not from a hostile reviewer, which is the same trust as any
  card turn.
- **No host tools, no steering, no vault, no mail.** The reviewer cannot
  present content, start processes or message other agents.
- **Untrusted input.** The diff and the code were written by an agent and are
  untrusted. The rubric tells the reviewer to treat them as data.
- **Findings never approve anything.** They go to the working agent and the
  user, never into an automatic merge or lane move.
- **Credentials stay with provider accounts.** No API keys are introduced.
  This is the reason pr-agent's LiteLLM path is unusable for Claude: Dieter
  must not hold Claude tokens.

## 5. Alternative B: pr-agent as the review engine

The changes are confined to step 3–5 of section 4.1. Everything else (snapshot,
setting, tool, part, UI) is shared.

- **Install.** Dieter fetches a pinned, SHA-256-verified `uv` binary, as
  Bun and Strix are fetched (`downloadPinned`). It then installs
  `pr-agent==0.50.0` from a hash-locked requirements file generated at build
  time into `DIETER_HOME/runtime/pr-agent/<version>`. uv supplies Python 3.13.
  That is about 300 MB with Python, and about 8 s warm or 30–60 s cold.
- **Bridge.** Dieter ships `dieter_review.py`: an entrypoint that mirrors
  `pr_agent.cli.run` with `PRAgent(ai_handler=DieterBridgeHandler)`.
  - The handler does not start harnesses itself. It writes
    `{type:"model-call", system, user}` on an inherited pipe and waits for the
    daemon's reply.
  - The daemon runs the harness turn as in section 4.1 step 4, with accounts
    and the pinned runtime, in the snapshot.
- **Configuration.** The daemon writes a host config TOML from the reviewer
  setting: `num_max_findings`, `extra_instructions`, ignore globs,
  `max_model_tokens`, `require_*`. It runs `--diff-file --json-output review`,
  trims the YAML artifacts, and treats missing JSON as failure.
- **Gains:** upstream's diff processing, chunking, risk checks and finding
  state, and later `describe` (PR descriptions), `ask` and labels.
- **Costs:**
  - a Python runtime on every daemon host, Linux included;
  - following a fast-moving internal API;
  - a second process tree per review;
  - weaker failure signals;
  - no `thorough` depth, because pr-agent asks for one pass.

## 6. Phases

1. **Phase 1, about 2 weeks.**
   - Build: `internal/engine/reviewer` (snapshot, render, run, parse, record),
     the runtime bridge with an async daemon handler, the per-card flag, the
     `reviewer-settings` record, the RPCs (including the `ReviewChanges` RPC
     behind the Changes-pane button), the CLI and `card review --wait`, the
     instruction text, and re-review diffing (resolved, still open, new) in
     the engine.
   - Tests: the generic data-part fallback rendering, operation tests, e2e over
     local, direct-TLS and relay routes, and a timeout measurement per harness.
   - Live check: the fixture above on Claude and Codex accounts.
2. **Phase 2, about 1.5 weeks.** Core `CODE_REVIEW` step and slice, the Mac
   and Compose cards (showing the re-review state), the toggles, Settings ›
   Reviewer, the Changes-pane button, docs, and Maestro and Mac flows.
3. **Later.**
   - The Codex `review/start` engine when the reviewer harness is Codex.
   - Optional auto-review when a turn ends before the card moves to Review.
   - Reviewing a GitHub PR by URL.
   - Alternative B, if wanted.

## 7. Decisions (2026-11-27)

1. **Engine: A.** Build the native reviewer with pr-agent's contract: its
   rubric, hunk format, finding shape and knobs, MIT-attributed. pr-agent's
   Python runtime is not embedded.
2. **Depth: quick by default, thorough as an option.**
3. **Setting scope: one shared, account-wide record**, the `reviewer-settings`
   KV record (section 4.3).
4. **Phase 1 includes** the human "Review changes" button in the Changes pane
   and re-review diffing (resolved, still open, new). Auto-review when a turn
   ends stays in "Later".
5. **The `git show` / `log.showSignature` bug** is a separate Todo card:
   `c_47c1cfd6a13bfa688b0bb804`, "Keep gpg signature lines out of Changes
   commit patches".

Following decision 4, section 6 puts re-review diffing and the RPC behind the
button in Phase 1. The button itself is client UI and ships with Phase 2.

## 8. Implementation (2026-11-27)

Alternative A was built as designed; deviations are noted.

- **API.** `dieter.v1.ReviewService` (`api/proto/dieter/v1/reviews.proto`):
  `GetReviewerSettings`, `UpdateReviewerSettings`, `SetCardCodeReview`,
  `StartCodeReview` (returns at once; poll `GetCodeReview`), `GetCodeReview`,
  `ListCodeReviews`. `code_review` on `Card` (50), `CreateConversationRequest`
  (28), `Schedule` (45) and `ScheduleDraft` (44). Handler:
  `internal/api/reviews.go`; agent turns may start and read only their own
  conversation's reviews and are refused the setting and the switch.
- **Setting.** KV namespace `reviewer-settings`, key `default`
  (`internal/replication/schema/reviewer.go`, validated on write and ingest;
  the public KV API refuses it). Store accessor with compare-and-set:
  `internal/store/kv/reviewer.go`. Defaults until saved: Claude Code, opus,
  quick, 6 findings, 3 rounds. Saving needs the machine's replica identity, as
  provider accounts do.
- **Switch.** `model.Card.CodeReview` is owner-local like vault and mail
  access, set at creation and switchable with `kanban.SetCodeReview`.
- **Reviewer.** `internal/engine/reviewer`: snapshot (temporary index,
  `commit-tree`, detached worktree under `DIETER_HOME/runtime/reviews/<id>`,
  hooks and LFS off, removed afterwards), merge base, diff with new-side line
  numbers and a 200 KiB inline budget, default and user ignore globs,
  sensitive-path notes, the rubric (two depths), strict answer parsing and
  validation, round comparison, the agent's tool text. The rubric and ignore
  lists are adapted from PR-Agent (MIT, `LICENSE-pr-agent.txt`).
- **Engine.** `internal/engine/code_review.go`: admission (one running review
  per conversation, released as soon as the final form is known), the bare
  reviewer harness turn (accounts, usage recorded on the account), the
  `data-code-review` part (appended once, replaced in place by review ID;
  user reviews get their own assistant message `msg_review_<id>`), timeouts
  (10 / 20 min), shutdown cancellation, and the prompt prefix that hands user
  reviews to the agent with its next message.
- **Harness.** `harness.Request.CodeReviewEnabled/ReviewCommand/CodeReview/
CodeReviewMaxRounds`; `code-review` frames are answered on their own
  goroutine (`internal/harness/code_review.go`), never in the read loop. The
  runtime's `code-review.mjs` holds the bridge (one review in flight, 25 min
  timeout), the `request_code_review` tool (it forwards the SDK tool call ID,
  so a review names the transcript call it answers), the instructions with the
  CLI fallback and round limit, and the mock harness behaviour (a mock
  reviewer and a mock agent that calls the tool) used by tests.
- **CLI.** `dieter reviewer show|update`, `dieter card|chat review [--wait]`,
  `reviews`, `reviewer CARD on|off`, `--code-review` on card, chat and
  schedule commands. Reference regenerated; skill updated.
- **Docs.** User guide `site/content/docs/code-review.md`; third-party notice.
- **Tests.** Reviewer package (snapshot isolation, unborn repositories, merge
  base, rendering, globs, parsing, rounds), schema and store, engine (end to
  end through the real `runner.mjs` mock harness for both the user and the
  agent path, admission, failures, cancellation, prompt context), harness
  (async reply), API permissions, CLI operations, runtime bridge and tool, and
  a CLI end-to-end test over local, direct-TLS and relay routes.
