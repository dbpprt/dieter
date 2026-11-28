# Local embeddings for agent memory recall

The spike behind [ADR 0008](../../../docs/adr/0008-memory-embeddings.md). It
answered two questions: how much do local embeddings add to agent memory's
keyword recall (SQLite FTS5 BM25), and what would they cost inside the
daemon? Results, the model and engine choice: [RESULTS.md](RESULTS.md); raw
numbers: [results/](results/).

The spike's exploratory code (four embedders, the kernel benchmarks) became
`internal/memory/embed` and is otherwise gone. What stays is the eval, now
running recall exactly as the daemon does:

- `main.go` indexes conversations into the production index
  (`internal/store/memory`), embeds the texts indexing returns with the
  production encoder (`internal/memory/embed`), and scores keyword-only
  against hybrid recall (`Index.Search` with and without a query vector).
  - **fixture:** `tests/fixtures/memory/recall.json` (eval E1: 16
    conversations, 20 questions; also asserted by
    `internal/store/memory/eval_test.go`).
  - **history:** real conversations read read-only with
    `dieter card transcript`. There are 41 questions: set A has the 18 from
    the earlier spikes; set B has 23 written from randomly sampled
    conversations before any ranking.

```sh
mise exec -- go build -o /tmp/memory-eval ./tools/spikes/memory-embeddings

# Fixture only:
/tmp/memory-eval

# Real history (transcripts are cached in DIR):
/tmp/memory-eval -cards cards.txt -transcripts DIR -dieter dieter \
  -exclude THIS_CARD -out results.json
```

Run it with a clean environment (`env -u DIETER_HOME -u DIETER_TURN_TOKEN -u
DIETER_CARD_ID`). It never writes to a Dieter home: the index lives in a
temporary directory, and the CLI is only used to read transcripts.
