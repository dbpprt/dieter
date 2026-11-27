# Code reviewer spike (pr-agent on Dieter harnesses)

Throwaway code behind [docs/proposals/code-reviewer.md](../../../docs/proposals/code-reviewer.md).
It runs the unmodified [pr-agent](https://github.com/The-PR-Agent/pr-agent) CLI
(PyPI 0.50.0) with a Dieter harness turn as its model, and a native agentic
review through the same harness turn, against one fixture with planted bugs.

| File                | Purpose                                                                                                                     |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `dieter_handler.py` | pr-agent `BaseAiHandler`: each `chat_completion(system, user)` is one bare `runner.mjs` worker request (like quick titles). |
| `run_pr_agent.py`   | pr-agent's own CLI (`pr_agent.cli.run`) with the handler swapped in; plain-diff mode, `--json-output`.                      |
| `native_review.py`  | One agentic harness turn in the workspace with a pr-agent-derived rubric and a JSON findings schema.                        |
| `make_fixture.sh`   | Scratch clone at `526f3387` (#227) plus `results/2026-11-27/planted-bugs.patch` (three planted bugs), and its diff.         |
| `results/`          | Per run: `calls.jsonl` (timing, frames, tool names, usage; no prompt text) and the `review.json` it produced.               |

## Run it

The spike used `/Volumes/External/pr-agent-spike` because the internal disk is
nearly full. The handler talks to `internal/harness/runtime/runner.mjs`
directly, without a daemon, so it uses the harness's own login: `auth: {}`
for Claude Code (`DIETER_REVIEW_AUTH=login`, the same object provider-account
turns send), and `null` (adapter discovery) otherwise.

```sh
SPIKE=/Volumes/External/pr-agent-spike
uv venv --python 3.13 $SPIKE/venv && VIRTUAL_ENV=$SPIKE/venv uv pip install pr-agent==0.50.0
tools/spikes/review/make_fixture.sh $SPIKE
export DIETER_REVIEW_RUNTIME=$PWD/internal/harness/runtime \
  DIETER_REVIEW_HARNESS=claude-code DIETER_REVIEW_MODEL=opus DIETER_REVIEW_AUTH=login

# pr-agent, diff inlined; add DIETER_REVIEW_WORKSPACE to let the harness read the checkout
DIETER_REVIEW_WORKSPACE=$SPIKE/fixture DIETER_REVIEW_LOG=calls.jsonl \
  $SPIKE/venv/bin/python -I tools/spikes/review/run_pr_agent.py \
  --diff-file=$SPIKE/planted.diff --output=review.md --json-output=review.json review

# native agentic review (agent runs git diff itself; DIETER_REVIEW_INLINE_DIFF inlines it)
DIETER_REVIEW_WORKSPACE=$SPIKE/fixture DIETER_REVIEW_LOG=calls.jsonl \
  $SPIKE/venv/bin/python -I tools/spikes/review/native_review.py 071f756f2d080182df15a3f80205e8e12336d769 review.json
```

## Results (2026-11-27, Claude Code harness, one run each unless noted)

Planted bugs: B1 fatal git errors read as an unborn branch, B2 weakened
overwrite guard (`||` → `&&`), B3 leaked repository lock.

| Run                  | Engine and access                | Model  | Time  | Tool calls | Input tokens (cache read) | Output | Planted found | Other findings                                 |
| -------------------- | -------------------------------- | ------ | ----- | ---------- | ------------------------- | ------ | ------------- | ---------------------------------------------- |
| `prag-sonnet-1`      | pr-agent, empty workspace        | sonnet | 20 s  | n/a        | 47.7k (0)                 | 1.9k   | B3            | merge-commit diff: **false positive**          |
| `prag-sonnet-ws`     | pr-agent, fixture workspace      | sonnet | 22 s  | 0          | 51.0k (12.4k)             | 2.6k   | B3            | unverified regression claim                    |
| `native-sonnet-1`    | native, agent runs `git diff`    | sonnet | 21 s  | 4          | 216k (174k)               | 1.9k   | B3            | merge-commit diff: **false positive**          |
| `prag-opus-1`        | pr-agent, empty workspace        | opus   | 174 s | 1          | 105k (60k)                | 17.7k  | B3, B2 (½)    | unverified "unborn origin lost"                |
| `prag-opus-ws`       | pr-agent, fixture workspace      | opus   | 42 s  | 3          | 224k (177k)               | 3.6k   | B1, B2, B3    | none                                           |
| `native-opus-1`      | native, agent runs `git diff`    | opus   | 192 s | 17         | 902k (828k)               | 17.1k  | B1, B2, B3    | `git show` + `log.showSignature`: **real bug** |
| `native-opus-2`      | same, repeat                     | opus   | 241 s | 24         | 1.43M (1.37M)             | 21.3k  | B1, B2, B3    | same real bug                                  |
| `native-inline-opus` | native, diff inlined + workspace | opus   | 194 s | 15         | 1.03M (964k)              | 17.7k  | B1, B2, B3    | none                                           |

The fixture was unmodified after every run (`git status` showed only the
planted edits). The Codex run (`prag-codex-auth-failure`) stopped at a stale
`~/.codex` login (401); the operator's Dieter-managed Codex login was not
touched, so Codex is unmeasured.

**Verification notes:**

- **Merge-commit finding:** for a clean merge, `git diff M^!` and
  `git show --format= --root M^0` both print nothing. Nothing regressed, so
  the finding is false.
- **Signature finding:** `git -c log.showSignature=true show --format= 526f3387^0`
  prints a gpg line before the patch, and `git diff 526f3387^!` does not.
  `internal/git/exec.go:55` merges stderr into the output, so Changes commit
  patches pick those lines up.

## Gotchas

- **pr-agent's exit code is unreliable.** It exited 0 when every model call
  failed ("Failed to review PR"). Treat a missing or empty `--json-output` as
  the failure signal.
- **Review JSON fields keep YAML block-scalar newlines** (`"relevant_file":
"path\n"`). Trim them.
- **`config.max_model_tokens` defaults to 32000.** pr-agent prunes larger
  diffs to that budget. Raise it for harness models.
- **The handler swap is a monkeypatch of `pr_agent.cli.PRAgent`, not a public
  API.** pr-agent changes daily (0.49 → 0.50 during the spike).
- **The harness uses tools even under pr-agent's pure-text prompt.** Opus ran
  `bash` in an empty workspace. With the checkout, it ran three read-only
  commands, which is what lifted recall from 1–1.5 to 3 of 3.
