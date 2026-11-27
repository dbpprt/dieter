# Built-in memory index spike

Throwaway code behind [docs/proposals/agent-memory.md](../../../docs/proposals/agent-memory.md).
It prototypes a memory layer inside the Dieter daemon:

- the same observation mapping as the [agentmemory](../agentmemory/README.md)
  and [OpenViking](../openviking/README.md) spikes;
- an SQLite FTS5 index through `modernc.org/sqlite`, the pure-Go driver
  Dieter already uses;
- BM25 recall grouped by card.

There is no extra process, runtime download or model.

This is its own Go module, so the main build and `go test ./...` ignore it.

```sh
# Build (offline is fine; the module cache already has the driver).
GOPROXY=off go build -o /tmp/memory-index .

# Index cards and run the 18 recall cases. Transcripts are cached in -transcripts.
/tmp/memory-index -transcripts /tmp/transcripts -dieter dieter \
  -db /tmp/memory-index.db -out /tmp/eval-builtin.json CARD_ID...

# Answer one query the way a memory_recall host tool would (JSON on stdout).
/tmp/memory-index -db /tmp/memory-index.db -query "Mac stays offline after sleep" -limit 5
```

`../agentmemory/turn.mjs --backend builtin --index-bin /tmp/memory-index
--index-db /tmp/memory-index.db` runs a live harness turn whose `memory_recall`
tool reads this index.
