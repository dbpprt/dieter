# all-MiniLM-L6-v2, int8

The text encoder of agent memory recall (`internal/memory/embed`), embedded
in the daemon binary.

- **Source:**
  [sentence-transformers/all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2),
  revision `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`.
  - `model.safetensors` SHA-256
    `53aa51172d142c89d9012cce15ae4d6cc0ca6895895114379cacb4fab128d9db`.
  - `tokenizer.json` SHA-256
    `be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037`.
- **License:** Apache-2.0 ([LICENSE](LICENSE)), by the sentence-transformers
  authors; the base model is Microsoft's MiniLM.
- **Changes made by Dieter:** the weights were converted by
  `go run ./tools/embedmodel -src CHECKPOINT`.
  - The linear weights and the word embeddings were quantized to symmetric
    int8, with one float32 scale per row.
  - Biases, layer norms, position and token type embeddings are unchanged
    float32.
  - The tokenizer's vocabulary is kept as `vocab.txt`, one token per line.
- **Fidelity:** vectors keep a cosine of at least 0.996 with the original
  float32 model (internal/memory/embed/testdata/golden.json). Recall on real
  history is identical (tools/spikes/memory-embeddings/RESULTS.md).

| File                | SHA-256                                                            |
| ------------------- | ------------------------------------------------------------------ |
| `model.safetensors` | `7e2ced94d18a9671e72fc56dcd0be5869aca2a18295a2ab12b5c3f3b1bdf88e1` |
| `vocab.txt`         | `07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3` |
