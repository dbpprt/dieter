"""Spike: run the unmodified pr-agent CLI with DieterHarnessAIHandler as its model.

Usage (inside a venv with `pip install pr-agent`):
  DIETER_REVIEW_RUNTIME=.../internal/harness/runtime \\
  python -I run_pr_agent.py --diff-file=change.diff --json-output=review.json review

Every argument goes to pr-agent's own CLI (pr_agent.cli.run). The only change
is the AI handler: pr_agent.cli constructs PRAgent() with LiteLLM, so we swap
the class it references for one bound to the Dieter handler.
"""

import functools
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pr_agent import cli
from pr_agent.agent.pr_agent import PRAgent

from dieter_handler import DieterHarnessAIHandler

cli.PRAgent = functools.partial(PRAgent, ai_handler=DieterHarnessAIHandler)

if __name__ == "__main__":
    sys.exit(cli.run(sys.argv[1:]))
