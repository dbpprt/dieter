"""Spike: a native agentic review through the same Dieter harness turn.

Instead of pr-agent's single prompt with the whole diff inlined, the harness
gets the workspace itself (read-only by instruction) and pr-agent's review
rubric, runs `git diff BASE` on its own, may read surrounding code, and
returns findings as one JSON object. Compare with run_pr_agent.py.

Usage:
  DIETER_REVIEW_RUNTIME=... DIETER_REVIEW_HARNESS=claude-code DIETER_REVIEW_MODEL=sonnet \\
  DIETER_REVIEW_AUTH=login DIETER_REVIEW_WORKSPACE=/path/to/worktree \\
  python -I native_review.py BASE_SHA OUT.json

Set DIETER_REVIEW_INLINE_DIFF=change.diff to put the diff in the prompt
(pr-agent's approach) instead of letting the agent run git diff itself.
"""

import asyncio
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dieter_handler import DieterHarnessAIHandler

SYSTEM = """You are Dieter's code reviewer. You review a change another agent made; you never edit it.
Do not modify, create or delete files, do not commit, and do not run builds or tests that write
outside a temporary directory. Read-only git and file commands are fine.

Review only the change itself: bugs, security problems and significant performance problems that
the change introduces. Each finding must name a concrete problem with a realistic trigger
scenario; read the surrounding code to confirm it before you report it. Skip style, naming,
missing comments and speculative concerns. An empty list is a good answer when nothing is wrong.
Report at most {max_findings} findings, most severe first.

Answer with exactly one JSON object in a ```json fence and nothing after it:
{{
  "summary": "one or two sentences on what the change does",
  "findings": [
    {{
      "file": "repo-relative path",
      "start_line": 0,
      "end_line": 0,
      "severity": "high | medium | low",
      "confidence": 0,
      "title": "short header, at most 8 words",
      "body": "the problem, its trigger scenario and its consequence",
      "suggestion": "optional: the fix, in prose or a short code snippet"
    }}
  ],
  "security_concerns": "No, or a short description"
}}
confidence is 0-10. Lines refer to the new version of the file."""

USER = """Review the change in the current directory: everything that differs from base commit
{base}, committed or not. Start with `git diff {base} --stat`, then `git diff {base}`, and read
whatever else you need. Untracked files belong to the change too (`git status --short`).
{extra}"""


def parse(text):
    match = re.findall(r"```json\s*(\{.*?\})\s*```", text, re.DOTALL)
    return json.loads(match[-1] if match else text)


INLINE = """Review the change in the current directory: everything that differs from base commit
{base}, committed or not. The full diff is below; read surrounding code in the workspace whenever
you need to confirm a finding.
{extra}
<diff>
{diff}
</diff>"""


async def main(base, out, extra=""):
    handler = DieterHarnessAIHandler()
    diff_file = os.environ.get("DIETER_REVIEW_INLINE_DIFF")
    if diff_file:
        with open(diff_file, encoding="utf-8") as fh:  # noqa: ASYNC230
            user = INLINE.format(base=base, extra=extra, diff=fh.read())
    else:
        user = USER.format(base=base, extra=extra)
    text, _ = await handler.chat_completion("", SYSTEM.format(max_findings=8), user)
    try:
        review = parse(text)
    except ValueError:
        review = {"unparsed": text}
    with open(out, "w", encoding="utf-8") as fh:  # noqa: ASYNC230
        json.dump(review, fh, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2], " ".join(sys.argv[3:])))
