# agentmemory spike

Throwaway code behind [docs/proposals/agentmemory.md](../../../docs/proposals/agentmemory.md).
It runs a real, isolated [agentmemory](https://github.com/rohitg00/agentmemory)
0.9.33 server and exercises it the way a Dieter-native integration would: the
daemon captures finished turns from Dieter's own transcripts, and agents
recall through Dieter host tools.

| File              | Purpose                                                                                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `probe.mjs`       | REST contract: auth, session start/end, capture with event ids (duplicate replay), remember, smart-search, project isolation, `/context`, latency.            |
| `replay.mjs`      | Prototype capture sink: reads finished cards with `dieter card transcript` (any harness) and maps UI message parts onto observations. One card = one session. |
| `eval.mjs`        | Recall quality: 18 paraphrased problem statements, expected card, hit@k/MRR by session.                                                                       |
| `turn.mjs`        | One real harness turn through the runner's adapters and `HarnessAgent`, with `memory_recall`/`memory_save` host tools backed by agentmemory.                  |
| `mcp-surface.mjs` | Lists the tools agentmemory's own MCP server would add to every turn (passthrough alternative).                                                               |
| `results/`        | `2026-11-27.json`: aggregate, redacted outcome (no transcript content).                                                                                       |

## Run it

Never point these scripts at an operator's agentmemory or Dieter daemon
writes: they create sessions and memories. Reads of Dieter transcripts go
through the CLI. Keep the server's `HOME` isolated: agentmemory writes
`~/.agentmemory` regardless of `--data-dir`.

```sh
SPIKE=/tmp/am-spike
mkdir -p $SPIKE/pkg $SPIKE/home/.agentmemory $SPIKE/data
(cd $SPIKE/pkg && npm install --no-audit --no-fund --omit=optional @agentmemory/agentmemory@0.9.33)
# Full install (local embeddings): drop --omit=optional (957 MB instead of 98 MB).
umask 077; openssl rand -hex 24 > $SPIKE/secret
printf 'AGENTMEMORY_SECRET=%s\nIII_TELEMETRY_ENABLED=false\n' "$(cat $SPIKE/secret)" > $SPIKE/home/.agentmemory/.env

# REST port N derives viewer N+2 and engine N+46023: keep N below 19512.
# The CLI starts a detached iii Worker Compose daemon and exits; stop it with
# the same HOME and `agentmemory stop --port N`.
cd $SPIKE && HOME=$SPIKE/home CI=1 MAX_OBS_PER_SESSION=0 \
  $SPIKE/pkg/node_modules/.bin/agentmemory --port 13111 --data-dir $SPIKE/data
# Add EMBEDDING_PROVIDER=local (full install) for hybrid recall.

export AGENTMEMORY_URL=http://127.0.0.1:13111 AGENTMEMORY_SECRET_FILE=$SPIKE/secret
node probe.mjs --out $SPIKE/probe.json
DIETER=dieter node replay.mjs --project dieter --cwd "$PWD" --out $SPIKE/replay.json CARD_ID...
node eval.mjs --label bm25 --out $SPIKE/eval.json

# A live turn in an empty project, without this card's Dieter environment.
mkdir -p $SPIKE/turn/project $SPIKE/turn/root && git -C $SPIKE/turn/project init -q
env -u DIETER_TURN_TOKEN -u DIETER_CARD_ID -u DIETER_HOME node turn.mjs \
  --runtime "$PWD/internal/harness/runtime" --harness claude-code --model sonnet \
  --project $SPIKE/turn/project --root $SPIKE/turn/root --out $SPIKE/turn.ndjson \
  --prompt "Dieter stays offline for minutes after my MacBook wakes from sleep. What causes it, and what was done about it?"

HOME=$SPIKE/home AGENTMEMORY_SECRET=$(cat $SPIKE/secret) \
  node mcp-surface.mjs "$PWD/internal/harness/runtime" $SPIKE/pkg/node_modules/.bin/agentmemory
```

`eval.mjs`'s expected cards are this repository's cards on the spike machine;
change them for another dataset. `turn.mjs` uses the default provider login of
the selected harness. Do not use it to refresh a stale login.
