# Local embeddings for Dieter Memory: results (2026-11-28)

Setup, corpora and how to rerun: [README.md](README.md). Raw numbers:
[results/2026-11-28.json](results/2026-11-28.json). Measured on an Apple M4
(10 cores). Every embedder in the spike was pure Go, checked against Hugging
Face `tokenizers` and onnxruntime: token ids identical, cosine ≥ 0.9999.

**Outcome:** shipped as recommended
([ADR 0008](../../../docs/adr/0008-memory-embeddings.md)): MiniLM-L6 hybrid
recall, int8 weights in the binary, Accelerate on macOS and Go SIMD kernels
elsewhere ([shipped kernels](#shipped-kernels),
[production eval](#production-eval)).

## TL;DR

- **Embeddings help on real history, and only when fused with BM25.** On 141
  real conversations and 41 questions, production BM25 ranks the right
  conversation first for 0.71 of the questions (MRR 0.814). The best hybrid
  reaches 0.93 (MRR 0.953), which is +0.138 MRR (95% CI +0.055 to +0.228).
  It is better on 10 questions and worse on 1 (sign test p = 0.012).
- **The best option is all-MiniLM-L6-v2 on prompts and final answers.** It
  needs 1,407 texts for 141 conversations and 2.1 MB of vectors. Per turn
  that is about 1 s of one core in pure Go. Recall pays about 11–23 ms more
  for the query vector. Its weights can ship as int8 (about 22 MB) with
  identical recall.
- **The cheap option is potion-base-8M on every observation.** It reaches
  hit@1 0.88 and MRR 0.916 (+0.101, CI +0.024 to +0.185). It costs
  practically no CPU (42,643 texts in 0.3 s), but stores a vector per
  observation: 10 MB int8 for this project. The model is 7.5 MB as int8.
  The difference from MiniLM is not significant on 41 questions (p = 0.63).
  MiniLM is better on the paraphrased set B and on vector-only recall.
- **Not worth it:**
  - MiniLM on every observation: no better than prompts and answers, at
    about 30× the CPU (5.7 core-hours for this project).
  - bge-small-en-v1.5: worse than MiniLM and 3–5× slower.
  - potion-retrieval-32M: worse than potion-base-8M.
  - Vectors alone, without BM25: they lose questions BM25 gets right.
- **The synthetic fixture (E1) is saturated.** Vectors alone score hit@1
  0.95–1.00 against BM25's 0.80, and fusion only _lowers_ that to
  0.85–0.90. It can't tell these options apart. The real-history eval is the
  one that matters.

## History corpus: 141 conversations, 41 questions

Hit@k is the share of questions whose conversation is in the top k. The
second MRR column splits set A (18 questions from the earlier spikes) and set
B (23 new, randomly sampled).

| Method                         | Unit   | hit@1 | hit@3 | MRR   | MRR A / B     | Texts  | Embed time (10 cores) | Vectors (f32) |
| ------------------------------ | ------ | ----- | ----- | ----- | ------------- | ------ | --------------------- | ------------- |
| BM25 (production)              | –      | 0.71  | 0.90  | 0.814 | 0.859 / 0.780 | –      | –                     | –             |
| **MiniLM-L6 hybrid**           | text   | 0.93  | 0.98  | 0.953 | 0.920 / 0.978 | 1,407  | 55.6 s                | 2.1 MB        |
| MiniLM-L6 hybrid               | digest | 0.88  | 1.00  | 0.939 | 0.972 / 0.913 | 141    | 11.4 s                | 0.2 MB        |
| MiniLM-L6 hybrid               | obs    | 0.90  | 0.95  | 0.936 | 0.925 / 0.946 | 42,643 | 2,061 s               | 62.5 MB       |
| **potion-base-8M hybrid**      | obs    | 0.88  | 0.93  | 0.916 | 0.898 / 0.929 | 42,643 | 0.3 s                 | 41.6 MB       |
| bge-small hybrid               | digest | 0.88  | 0.95  | 0.923 | 0.935 / 0.913 | 141    | 37.1 s                | 0.2 MB        |
| bge-small hybrid               | text   | 0.88  | 0.93  | 0.912 | 0.951 / 0.882 | 1,407  | 190.8 s               | 2.1 MB        |
| potion-base-8M hybrid          | text   | 0.81  | 0.93  | 0.870 | 0.867 / 0.871 | 1,407  | 0.0 s                 | 1.4 MB        |
| potion-retrieval-32M hybrid    | obs    | 0.76  | 0.93  | 0.845 | 0.870 / 0.824 | 42,643 | 0.3 s                 | 83.3 MB       |
| MiniLM-L6 vector only          | text   | 0.85  | 0.95  | 0.900 | 0.917 / 0.888 | 1,407  | 55.6 s                | 2.1 MB        |
| potion-base-8M vector only     | obs    | 0.73  | 0.90  | 0.823 | 0.876 / 0.781 | 42,643 | 0.3 s                 | 41.6 MB       |
| MiniLM-L6 **int8** hybrid      | text   | 0.93  | 0.98  | 0.953 | 0.920 / 0.978 | 1,407  | 56.1 s                | 2.1 MB        |
| potion-base-8M **int8** hybrid | obs    | 0.88  | 0.93  | 0.916 | 0.898 / 0.929 | 42,643 | 0.3 s                 | 41.6 MB       |

Units:

- _text_: the title, every prompt and every final answer.
- _digest_: one text per conversation (title, brief, final answer).
- _obs_: every observation the production indexer stores.

_int8_ means int8 weights and int8 stored vectors, with float32 compute.

Paired against BM25 (hit@1 better/worse; sign test; MRR change with a 95%
bootstrap CI):

| Hybrid                | hit@1 +/− | p     | ΔMRR [95% CI]           |
| --------------------- | --------- | ----- | ----------------------- |
| MiniLM-L6 / text      | +10 / −1  | 0.012 | +0.138 [+0.055, +0.228] |
| MiniLM-L6 / obs       | +9 / −1   | 0.021 | +0.122 [+0.039, +0.212] |
| MiniLM-L6 / digest    | +9 / −2   | 0.065 | +0.125 [+0.035, +0.217] |
| potion-base-8M / obs  | +8 / −1   | 0.039 | +0.101 [+0.024, +0.185] |
| bge-small / text      | +7 / −0   | 0.016 | +0.098 [+0.032, +0.171] |
| potion-base-8M / text | +7 / −3   | 0.344 | +0.055 [−0.029, +0.139] |

What the vectors fix, from the per-question top 3 in the JSON:

- **Paraphrases without shared words.** "Claude keeps returning
  authentication errors" finds the _claude 401_ conversation:
  - BM25: rank 3.
  - MiniLM hybrid: rank 1.
  - potion hybrid: rank 8.
- **Questions where a louder conversation outranks the right one on a
  common word.** For "every CI job failing on a pull request", BM25 puts
  _Gateway deployment_ first. MiniLM's top 3 never contains that
  conversation, so the right one moves up. "AI code review of pull requests
  built into Dieter" goes from BM25 rank 5 to 1.

The three questions the MiniLM text hybrid misses at rank 1:

- "typing lag and lost characters in the Android chat composer" (rank 15):
  the answer is buried in a large conversation titled _KMP fixes_. BM25
  ranks it 8. MiniLM on the digest unit ranks it 1, because the digest is
  the conversation's opening prompt.
- "notch covers the status badges in the top bar" (rank 2): _Multi Machine
  Support_ comes first.
- "Android inbox rows only refresh after tapping them" (rank 2): _inbox
  redesign_ comes first, and it is arguably related.

## The synthetic fixture (E1, 16 conversations, 20 questions)

| Method                   | hit@1 | MRR   |
| ------------------------ | ----- | ----- |
| BM25 (production)        | 0.80  | 0.885 |
| MiniLM-L6, vector        | 0.95  | 0.975 |
| MiniLM-L6, hybrid        | 0.90  | 0.950 |
| potion-8M, vector        | 0.95  | 0.975 |
| potion-8M, hybrid        | 0.85  | 0.925 |
| bge-small, digest vector | 1.00  | 1.000 |

On a 16-conversation corpus whose questions avoid the conversations' words,
a semantic model is near-perfect. The two questions BM25 places second keep
fusion at rank 2. If embeddings ship, this fixture needs harder distractors
(several conversations per topic) before it can guard regressions.

## Cost inside the daemon

| Model             | Weights (f32 → int8) | Heap after load | Load  | One core: query (9 tok) | 80 tok  | 256 tok       |
| ----------------- | -------------------- | --------------- | ----- | ----------------------- | ------- | ------------- |
| potion-base-8M    | 30 MB → 7.5 MB       | 30 MB           | 31 ms | < 0.01 ms               | 0.02 ms | 0.17 ms (512) |
| all-MiniLM-L6-v2  | 87 MB → 22 MB        | 87 MB           | 76 ms | 23 ms                   | 204 ms  | 737 ms        |
| bge-small-en-v1.5 | 128 MB → 32 MB       | 128 MB          | 45 ms | 48 ms                   | 411 ms  | 3.5 s (512)   |

For comparison, production BM25 on the same corpus takes 6.2 s to index
42,502 observations and answers in 43 ms (p50).

- **MiniLM per turn:** one prompt and one final answer, about 0.3–1 s of
  one core.
- **MiniLM backfill:** this project's 141 conversations take about 9 core
  minutes (56 s on 10 cores). It runs once, at low priority, and BM25
  serves recall in the meantime.
- **Query:** the query vector costs 11 ms on all cores or 23 ms on one.
  Cosine over a project's vectors is negligible at this size (0.3 ms for
  1.4k vectors, 7 ms for 42k).
- **Kernels:** these numbers use plain-Go float32 kernels with no SIMD.
  The next section shows how much faster they get.

## Inference engine

The question is which engine to embed: something fast on macOS and Linux
that keeps the release daemon a `CGO_ENABLED=0` Go binary without many
dependencies. A scratch module (removed after the shipped kernels were built)
ran the same MiniLM encoder with three matmul and attention backends, plus
onnxruntime as the reference ceiling. All runs use one Apple M4 core; all Go
variants produce the scalar vectors (cosine 1.000000).

| Engine                                                    | 9 tok  | 80 tok | 256 tok | Ships                                                      |
| --------------------------------------------------------- | ------ | ------ | ------- | ---------------------------------------------------------- |
| Plain Go, scalar (the eval above)                         | 21 ms  | 187 ms | 686 ms  | nothing                                                    |
| Go 1.27 `simd/archsimd` NEON, first-cut 4×4 kernel        | 4.4 ms | 37 ms  | 184 ms  | nothing (`GOEXPERIMENT=simd`)                              |
| Go + Accelerate `cblas_sgemm` and `vvexpf` through purego | 2.0 ms | 8.1 ms | 29 ms   | nothing (system framework; purego is already a dependency) |
| onnxruntime 1.32, CPU, 1 thread                           | 1.8 ms | 4.7 ms | 14.6 ms | a 20+ MB native library per OS/arch, plus cgo or purego    |

Findings:

- **Accelerate makes the matmul about 15× faster.** After that, `math.Erf`
  (GELU) and `math.Exp` (softmax) took about 60% of the time. Batching the
  exponentials through vForce, with an Abramowitz–Stegun erf (error below
  1.5e-7), got to 29 ms. That is 23× faster than scalar and within 2× of
  onnxruntime. The rest is in scalar GELU, softmax and layer-norm loops,
  which archsimd could vectorize.
- **Go 1.27's SIMD runs on both platforms.** The `GOEXPERIMENT=simd`
  packages support NEON on arm64 and AVX/AVX2/AVX-512 on amd64. The API is
  experimental (outside the Go 1 promise), but the repository pins its Go
  version. The first-cut NEON kernel is 5× faster with no tuning and no
  vectorized GELU or exp. Not measured on Linux yet.
- **With Accelerate, MiniLM costs almost nothing.** A turn (prompt plus
  answer) is about 40 ms of one core, the backfill of 1,407 texts is about
  30 core seconds instead of 9 minutes, and a query vector takes 2 ms.

Rejected:

- **onnxruntime:** it is the fastest, but either cgo or purego bindings
  (onnxruntime-purego, pure-onnx) still mean shipping, signing and updating
  `libonnxruntime` for darwin/arm64, linux/arm64 and linux/amd64. It is
  under 2× faster than Accelerate, at about two texts per turn.
- **llama.cpp/ggml** (for example kelindar/search through purego): fast
  kernels, but it is the same shipped native library, plus a GGUF
  conversion.
- **hugot:** it wraps onnxruntime or GoMLX. Its pure-Go backend is the same
  class as the scalar code here.

Recommended engine:

- **Kernel seam:** keep the encoder in Go, with one small seam:
  `sgemm`, `expf` and GELU.
- **macOS:** Accelerate through purego, the pattern
  `internal/remotedesktop` already uses for system frameworks.
- **Linux:** archsimd kernels (NEON on gx10-class arm64, AVX2 on amd64). Go
  assembly for one sgemm micro-kernel is the alternative if the
  `GOEXPERIMENT` is unwanted.
- **Fallback:** the scalar path stays, and the tests compare every backend
  with it.

### Shipped kernels

`internal/memory/embed`, tuned after the comparison above:

- **Matrix kernel:** a register-blocked Go SIMD kernel. It computes 6 rows ×
  4 vectors (24 accumulators) on NEON and AVX-512, and 6 × 2 on AVX2's 16
  registers. It runs at 35 GMAC/s on an M4 core, 9× plain Go, with results
  identical to scalar. Packing the weights or unrolling k gained at most 5%,
  so neither shipped.
- **Model layout:** the query, key and value projections are fused into one
  product, and the query is pre-scaled.
- **Vector kernels:** exp (Cephes), erf GELU (Abramowitz–Stegun), softmax
  and layer norm use Go SIMD on every platform. Exponentials below e⁻⁶⁴ are
  flushed to 0, so no subnormal products slow x86 down.

Times are BenchmarkEmbed, one core, for a 9-token query, a 66-token answer
and a 256-token text:

| Machine, kernel set                   | 9 tok  | 66 tok | 256 tok |
| ------------------------------------- | ------ | ------ | ------- |
| M4, Accelerate + SIMD (macOS release) | 1.4 ms | 4.0 ms | 17 ms   |
| M4, Go SIMD (NEON)                    | 6.6 ms | 30 ms  | 122 ms  |
| M4, plain Go                          | 34 ms  | 191 ms | 823 ms  |
| Ryzen 9 9950X, Go SIMD (AVX-512)      | 6.8 ms | 30 ms  | 122 ms  |
| Ryzen 9 9950X, Go SIMD (AVX2 only)    | 7.0 ms | 28 ms  | 205 ms  |
| Ryzen 9 9950X, plain Go               | 218 ms | 1.7 s  | 5.6 s   |

- **Accelerate is on a par with onnxruntime.** onnxruntime takes 1.8, 4.7
  and 14.6 ms.
- **Plain Go is slow on x86.** Go compiles that loop poorly there (0.75
  GMAC/s even on random data), which is why release builds and CI use the
  SIMD experiment.
- **Fidelity:** every kernel set keeps a cosine of at least 0.9969 with the
  original float32 model on 23 golden texts
  (`internal/memory/embed/testdata/golden.json`).

### Production eval

The production path is `IndexCard` texts, `PutVectors`, then `Search` with
a query vector. The vector floor is 0.2.

| Corpus             | Keyword: hit@1 / hit@3 / MRR | Hybrid: hit@1 / hit@3 / MRR |
| ------------------ | ---------------------------- | --------------------------- |
| Fixture E1         | 0.80 / 0.95 / 0.885          | 0.90 / 1.00 / 0.950         |
| History, 141 conv. | 0.71 / 0.90 / 0.814          | 0.93 / 0.98 / 0.951         |

Embedding the history's 1,407 texts took 9.6 s on one M4 core (Accelerate).
Hybrid search took 43 ms (p50), most of it BM25.

A live test ran on an isolated enrolled daemon with real Claude Code turns:

- **Before the upgrade:** a turn ran on a `main` build, which indexed it
  without vectors.
- **After the upgrade:** the daemon restarted on this build and embedded that
  conversation in the background.
- **Recall by meaning:** `dieter memory search` found it from a question
  with no shared words.
- **A real turn:** a second turn's `memory_recall` returned it, and that turn
  was embedded inline.

## Recommendation

1. **Ship hybrid recall with all-MiniLM-L6-v2 over prompts and final
   answers.** Keep BM25 exactly as it is and add a vector ranking to the
   same reciprocal-rank fusion. It is the best and most significant result
   on real history, and it costs little CPU per turn. Its vectors are small
   enough to keep in memory per project. It ships under Apache-2.0, so it
   needs a NOTICE entry.
2. **Ship the weights inside the daemon binary as int8 (about 22 MB).** That
   avoids a download at run time, so the memory proposal's "no runtime
   downloads, nothing for Linux daemons or the test kit to provision" still
   holds. The release daemon grows from about 36 MB to about 60 MB. The
   alternative is a first-use download pinned by SHA-256 in the binary; it
   keeps the binary small but adds a network dependency and a failure mode.
3. **Fallback if 24 MB or about 1 s of CPU per turn is too much:**
   potion-base-8M on all observations (7.5 MB, practically free CPU). It
   gives about three quarters of the gain.

### Implementation sketch (as built)

Two things changed from this sketch. Vectors are keyed by (card, message,
part) with a hash of the text, so only changed texts are re-embedded. Saved
memories are embedded too.

- **Package:** `internal/memory/embed` holds the WordPiece tokenizer and
  BERT encoder from this spike. It gets a reference-vector test against
  checked-in fixtures (ids and vectors from `tools/embedmodel/reference.py`)
  and the int8 weights as an embedded asset.
- **Index:**
  - A `vectors` table next to `observations` (card, message, int8 vector,
    scale).
  - The model id goes in `meta`; a mismatch triggers a re-embed (cheap).
  - The indexer embeds new prompt and answer observations on one
    low-priority worker after `IndexCard`.
- **Search:**
  - Each card's score is its best cosine, fused into the existing candidate
    scores with `1/(60+rank)`.
  - Vector-only hits get their best text, clipped, as the snippet.
  - Federated recall needs no change: every daemon fuses locally.
- **Evals:**
  - Add hybrid to `eval_test.go`.
  - Make E1 harder: several conversations per topic, keyword-style queries
    as agents write them.
  - Keep this history eval as a manual tool.
- **Invariants:** it needs no new process and no network. The vectors are
  derived data in the same index under `DIETER_HOME`, and nothing reaches
  the gateway.

## Limits of this eval

- **The questions:**
  - There are 41, all written by me for one English project. Recall shipped
    today, so there are no real agent queries yet.
  - Agents tend to write keyword queries. Those favour BM25 and would
    shrink the gap.
  - Set B was written blind to rankings, from title and first prompt. One
    label was widened afterwards, for all methods alike: two maintenance
    conversations both answer "update all dependencies".
- **Tuning:** fusion is untuned (equal weights, k = 60), on purpose, to avoid
  fitting 41 questions.
- **Transcript previews:** transcripts come from `dieter card transcript`,
  which carries tool _previews_. Production indexes full stored messages,
  so tool observations there are longer, for BM25 and vectors alike.
- **Hardware:** timings come from one M4. Linux daemons (workbench, gx10)
  will differ.
