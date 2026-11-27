# OpenViking spike

Throwaway code behind [docs/proposals/agent-memory.md](../../../docs/proposals/agent-memory.md).
It runs a real, isolated [OpenViking](https://github.com/volcengine/OpenViking)
0.5.6 server without a model provider (built-in local embedding, no VLM). It
exercises OpenViking the way a Dieter-native integration would, using the same
cards and recall cases as the [agentmemory spike](../agentmemory/README.md).

| File         | Purpose                                                                                                                                             |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `probe.mjs`  | Session path (create, batch messages, commit, background task) and resource path (write, `find`, `search`, `grep`), with status codes and latency.  |
| `replay.mjs` | Replays cards as resource files, one per observation (the agentmemory mapping) under `viking://resources/dieter/cards/<card>/`; caches transcripts. |
| `eval.mjs`   | The same 18 recall cases, scored by the card in each hit's URI.                                                                                     |

## Run it

```sh
SPIKE=/tmp/ov-spike
mkdir -p $SPIKE/home $SPIKE/data
uv venv --python 3.12 $SPIKE/venv
VIRTUAL_ENV=$SPIKE/venv uv pip install 'openviking[local-embed]==0.5.6'   # builds llama-cpp-python (cmake, ~1 min)
cat > $SPIKE/ov.conf <<EOF
{
  "embedding": { "dense": { "provider": "local", "model": "bge-small-zh-v1.5-f16",
                            "cache_dir": "$SPIKE/home/.cache/openviking/models" } },
  "storage": { "workspace": "$SPIKE/data" },
  "server": { "host": "127.0.0.1", "port": 11933, "auth_mode": "dev", "cors_origins": [] },
  "telemetry": { "enabled": false }
}
EOF
# Runs in the foreground; the first start downloads the 46 MB GGUF model from Hugging Face.
HOME=$SPIKE/home $SPIKE/venv/bin/openviking-server --config $SPIKE/ov.conf

export OPENVIKING_URL=http://127.0.0.1:11933
node probe.mjs --out $SPIKE/probe.json
DIETER=dieter node replay.mjs --cache $SPIKE/transcripts --out $SPIKE/replay.json CARD_ID...
node eval.mjs --mode find --label openviking-keyless --out $SPIKE/eval.json
```

`auth_mode: dev` is for a loopback-only spike. A real deployment uses
`api_key` with a user key; the root key cannot read or write memories.
