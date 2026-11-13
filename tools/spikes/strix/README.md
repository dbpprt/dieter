# Strix harness spike

Throwaway code behind [docs/proposals/strix-integration.md](../../../docs/proposals/strix-integration.md).
It runs the real Strix engine end to end against a scripted model, the way a
Dieter `strix` harness worker would.

| File            | Purpose                                                                                                    |
| --------------- | ---------------------------------------------------------------------------------------------------------- |
| `fake-llm.mjs`  | Schema-driven OpenAI-compatible Chat Completions server: todo, shell, child agent, finding, `finish_scan`. |
| `run-strix.sh`  | Starts Strix headless with an isolated `HOME`, cwd outside the checkout, telemetry and update check off.   |
| `projector.mjs` | Tails a Strix run directory and emits AI SDK UI chunks plus `subagents`/`task-plan` capability envelopes.  |
| `worker.mjs`    | One Dieter turn: fresh scan or `--resume`, frames to NDJSON, optional SIGINT after N seconds.              |
| `replay.mjs`    | Replays finished run directories through the projector and checks the transcript invariants.               |

## Run it

The spike used `/Volumes/External/strix-spike` (`SPIKE_ROOT`) because the
internal disk was nearly full.

```sh
SPIKE=/Volumes/External/strix-spike
# 1. A Docker engine. Colima ignores COLIMA_HOME passed through some launchers;
#    export it in the same shell. Restore your docker context afterwards.
COLIMA_HOME=$SPIKE/colima colima start strix-spike --foreground --cpus 4 --memory 6 \
  --disk 40 --vm-type vz --mount $SPIKE:w --runtime docker
docker context use default
export DOCKER_HOST=unix://$SPIKE/colima/strix-spike/docker.sock
docker pull ghcr.io/usestrix/strix-sandbox:1.4.1

# 2. Strix 1.7.1 (binary; sha256 of the macos-arm64 archive below).
curl -sSLO https://github.com/usestrix/strix/releases/download/v1.7.1/strix-1.7.1-macos-arm64.tar.gz
shasum -a 256 strix-1.7.1-macos-arm64.tar.gz
# 147814905c41a7d5f511faa326472bddc31f21602486190a5bfb76e7b20aa692
mkdir -p $SPIKE/bin && tar -xzf strix-1.7.1-macos-arm64.tar.gz -C $SPIKE/bin

# 3. The scripted model (FAKE_DELAY_MS / FAKE_CHILD_SLEEP optional).
node fake-llm.mjs --port 47811 --log $SPIKE/fake-llm-requests.ndjson

# 4. Turns. A second call with the same --session resumes the run.
node worker.mjs --session s1 --project /path/to/target --prompt "White-box review" \
  --budget 1 --out $SPIKE/evidence/s1-turn1.ndjson
node worker.mjs --session s1 --project /path/to/target --prompt "Re-check /user" \
  --budget 1 --out $SPIKE/evidence/s1-turn2.ndjson
node worker.mjs --session s2 --project /path/to/target --interrupt-after 12 \
  --budget 1 --out $SPIKE/evidence/s2-interrupt.ndjson

# 5. Check the projection of every run.
node replay.mjs $SPIKE/state/s*
```

`STRIX_BIN` selects another Strix build, for example a wheel installed with
`uv tool install 'strix-agent @ https://github.com/usestrix/strix/releases/download/v1.7.1/strix_agent-1.7.1-py3-none-macosx_11_0_arm64.whl'`
(PyPI only has 1.7.0).

A real model replaces the fake one with `STRIX_LLM`, `LLM_API_KEY` and, if
needed, `LLM_API_BASE`. Only scan targets you are
authorized to test.
