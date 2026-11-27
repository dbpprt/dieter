"""Spike: a pr-agent AI handler that answers every model call with one Dieter
harness turn, run through Dieter's own worker (internal/harness/runtime/runner.mjs).

pr-agent normally calls LiteLLM with an API key. Dieter has no API keys for
Claude (provider policy) and manages its harness logins itself, so the
reviewer has to use a Dieter-managed harness turn as its "model". Each
chat_completion(system, user) becomes one bare worker request, like
quick-task titles in internal/engine/conversation_creation.go: a fresh
session, an empty workspace, no host tools.

Environment:
  DIETER_REVIEW_RUNTIME   directory holding runner.mjs (required)
  DIETER_REVIEW_HARNESS   catalog harness id: codex | claude-code | ...  (default codex)
  DIETER_REVIEW_ADAPTER   runtime adapter (default: the harness id)
  DIETER_REVIEW_MODEL     runtime model id (default: harness default)
  DIETER_REVIEW_EFFORT    effort (optional)
  DIETER_REVIEW_WORKSPACE workspace the harness may read (default: a fresh empty dir)
  DIETER_REVIEW_LOG       JSONL file that records one line per model call
  DIETER_REVIEW_AUTH      "login" sends auth {} (Claude Code uses its own login, as
                          provider-account turns do); unset sends null (adapter discovery)
"""

from __future__ import annotations

import asyncio
import json
import os
import secrets
import shutil
import tempfile
import time

from pr_agent.algo.ai_handlers.base_ai_handler import BaseAiHandler


class DieterHarnessAIHandler(BaseAiHandler):
    def __init__(self):
        self.runtime = os.environ["DIETER_REVIEW_RUNTIME"]
        self.harness = os.environ.get("DIETER_REVIEW_HARNESS", "codex")
        self.adapter = os.environ.get("DIETER_REVIEW_ADAPTER", self.harness)
        self.model = os.environ.get("DIETER_REVIEW_MODEL", "")
        self.effort = os.environ.get("DIETER_REVIEW_EFFORT", "")
        self.workspace = os.environ.get("DIETER_REVIEW_WORKSPACE", "")
        self.log_path = os.environ.get("DIETER_REVIEW_LOG", "")
        self.auth = {} if os.environ.get("DIETER_REVIEW_AUTH") == "login" else None

    @property
    def deployment_id(self):
        return None

    async def chat_completion(
        self,
        model: str,
        system: str,
        user: str,
        temperature: float = 0.2,
        img_path: str | None = None,
    ):
        root = tempfile.mkdtemp(prefix="dieter-review-")
        workspace = self.workspace or os.path.join(root, "workspace")
        os.makedirs(workspace, exist_ok=True)
        session = "review_" + secrets.token_hex(8)
        request = {
            "harness": self.harness,
            "adapter": self.adapter,
            "prompt": user,
            "instructions": system,
            "sessionId": session,
            "responseMessageId": "msg_" + secrets.token_hex(8),
            "projectPath": workspace,
            "runtimeRoot": os.path.join(root, "runtime"),
            "auth": self.auth,
        }
        if self.model:
            request["model"] = self.model
        if self.effort:
            request["effort"] = self.effort
        started = time.monotonic()
        env = {
            key: os.environ[key]
            for key in ("HOME", "PATH", "TMPDIR", "USER", "LANG")
            if key in os.environ
        }
        process = await asyncio.create_subprocess_exec(
            "node",
            os.path.join(self.runtime, "runner.mjs"),
            "--board-worker-token=spike",
            cwd=self.runtime,
            env=env,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=64 * 1024 * 1024,
        )
        process.stdin.write((json.dumps(request) + "\n").encode())
        await process.stdin.drain()
        process.stdin.close()
        text, errors, frames, metadata, tools = [], [], {}, {}, []
        first_token = None
        async for raw in process.stdout:
            try:
                frame = json.loads(raw)
            except ValueError:
                continue
            kind = frame.get("type")
            frames[kind] = frames.get(kind, 0) + 1
            if kind == "error":
                errors.append(frame.get("error"))
            if kind != "chunk":
                continue
            chunk = frame.get("chunk") or {}
            if chunk.get("type") == "tool-input-available":
                tools.append(chunk.get("toolName"))
            if chunk.get("type") == "text-delta":
                if first_token is None:
                    first_token = time.monotonic() - started
                text.append(chunk.get("delta", ""))
            if chunk.get("messageMetadata"):
                metadata = chunk["messageMetadata"]
        stderr = (await process.stderr.read()).decode(errors="replace")
        code = await process.wait()
        elapsed = time.monotonic() - started
        shutil.rmtree(root, ignore_errors=True)
        response = "".join(text)
        if self.log_path:
            with open(self.log_path, "a", encoding="utf-8") as fh:  # noqa: ASYNC230 (spike log)
                fh.write(
                    json.dumps(
                        {
                            "harness": self.harness,
                            "model": self.model or "(default)",
                            "seconds": round(elapsed, 1),
                            "first_token_seconds": round(first_token, 1) if first_token else None,
                            "system_chars": len(system),
                            "user_chars": len(user),
                            "response_chars": len(response),
                            "frames": frames,
                            "tools": tools,
                            "exit": code,
                            "errors": errors,
                            "usage": metadata.get("totalUsage") or metadata.get("usage"),
                            "stderr_tail": stderr[-400:] if code else "",
                        }
                    )
                    + "\n"
                )
        if code != 0 or errors or not response.strip():
            raise RuntimeError(
                f"Dieter harness turn failed (exit {code}): {errors or stderr[-400:]}"
            )
        return response, "stop"
