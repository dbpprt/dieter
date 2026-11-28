# ADR 0008: Local embeddings for agent memory recall

- Status: accepted, implemented 2026-11
- Extends: [ADR 0007](0007-agent-memory.md)
- Evidence:
  [tools/spikes/memory-embeddings/RESULTS.md](../../tools/spikes/memory-embeddings/RESULTS.md)
  (model choice, engine choice, real-history eval)

## Context

Agent memory recall (ADR 0007) was keyword search: SQLite FTS5 BM25 over
observations and digests. Questions phrased differently from the
conversation that answers them missed. "Claude keeps returning
authentication errors" did not find the conversation titled "claude 401".

ADR 0007 kept the rule that memory runs inside Dieter: no extra process, no
model key, nothing leaves the machines. The release daemon is also a
`CGO_ENABLED=0` Go binary for darwin/arm64, linux/arm64 and linux/amd64.

A spike measured four local embedders (Model2Vec potion-base-8M and
potion-retrieval-32M, all-MiniLM-L6-v2, bge-small-en-v1.5) against BM25.
It used three units of text and 141 real conversations with 41 questions.
It then measured inference engines.

## Decision

- **Hybrid recall.** BM25 stays as it is. Each conversation's title, prompts
  and final answers are embedded with all-MiniLM-L6-v2 (384 dimensions,
  mean pooling, 256 tokens). Recall fuses the BM25 ranking with the
  conversations ranked by their best cosine, by reciprocal rank (k = 60),
  as BM25 already fuses observations and digests. Matches below cosine 0.2
  are dropped. A file filter keeps recall to keywords. Saved memories are
  embedded and fused the same way.
- **In process, in the binary.** The model's weights ship inside the
  `dieter` binary as int8 (`internal/memory/embed/minilm`, 23 MB, Apache-2.0;
  provenance in its README). They are loaded on first use (about 60 MB) and
  released after five idle minutes. There is no download and no other
  process.
- **Engine.** A small Go encoder (`internal/memory/embed`) with three kernel
  sets that compute the same function:
  - Apple's Accelerate `cblas_sgemm` through purego on macOS, keeping
    `CGO_ENABLED=0`.
  - Go's portable SIMD (`GOEXPERIMENT=simd`: NEON on arm64, AVX/AVX2/AVX-512
    on amd64) for the matrix kernel elsewhere and for the vector kernels
    everywhere.
  - Plain Go when built without the experiment.

  Release builds, CI and `mise` set `GOEXPERIMENT=simd`. CI also tests the
  plain-Go fallback. Golden vectors from the original float32 checkpoint
  (onnxruntime) guard every kernel set.

- **Storage.** Vectors are derived data in the same machine-local index
  (`vectors`, `memory_vectors`), stored as int8 with a scale. They follow
  their observations through incremental indexing, forgetting and eviction.
  The model ID is recorded; a different model discards the vectors, and
  reconciliation re-embeds every conversation. Conversations indexed before
  embeddings are reindexed in full once.

## Consequences

- **Recall** on real history goes from hit@1 0.71 and MRR 0.814 to 0.93 and
  0.951. Eval E1 goes from hit@1 0.80 to 0.90 and is now asserted for
  hybrid recall too.
- **Binary size:** the `dieter` binary grows by about 24 MB. The gateway is
  unchanged. The repository carries the 23 MB asset, the one named exception
  to the 5 MiB file limit (`LARGE_ASSETS` in `fastlane/helpers/format.rb`).
  A new model version adds another copy to the history.
- **CPU, measured on one core.**
  - Encoding takes about 4 ms per answer on an M4 with Accelerate, and about
    30 ms with Go SIMD (M4 NEON, Ryzen 9950X AVX2/AVX-512).
  - A turn adds two or three texts.
  - The one-time backfill of 1,400 texts takes about 10 s (Accelerate).
  - A query vector costs 1–7 ms.
- **The Go SIMD API is experimental** and outside the Go 1 compatibility
  promise. The repository pins its Go version, and the plain-Go fallback
  keeps any build working.
- **Tool calls and outputs are not embedded.** Embedding every observation
  was about thirty times the CPU for no better recall; keywords cover them.
