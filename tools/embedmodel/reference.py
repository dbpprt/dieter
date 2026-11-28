# Golden vectors for internal/memory/embed: token ids from Hugging Face
# tokenizers and float32 vectors from the checkpoint's official ONNX export
# (onnxruntime, mean pooling, L2 normalization, 256 tokens).
#
#   uv run --no-project --with numpy --with onnxruntime --with tokenizers \
#     python -I tools/embedmodel/reference.py CHECKPOINT_DIR > internal/memory/embed/testdata/golden.json
import json
import sys

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

TEXTS = [
    "Mac stays disconnected after waking from sleep",
    "Claude keeps returning authentication errors",
    "every CI job failing on a pull request",
    "Root cause: the gateway tunnel's reconnect deadline used the monotonic clock, which pauses while the Mac sleeps.",
    "Café naïve résumé — Ünïcödé façade!",
    "Die Verbindung bricht nach dem Aufwachen ab; äöü ß",
    "TranscriptScrollController jumps when chunks stream in (apps/apple/mac/TranscriptScrollController.swift)",
    "func (s *Service) Search(ctx context.Context, input SearchInput) (SearchResult, error) { return s.index.Search(q) }",
    "go test ./internal/store/memory -run TestRecallEval -count=1",
    "https://github.com/dbpprt/dieter/pull/241#issuecomment-123456",
    "snake_case_identifier and camelCaseIdentifier and SCREAMING_CASE",
    "中文测试 mixed with English and 日本語",
    "emoji 🚀 test ✅ done 🎉",
    "tabs\tand\nnewlines\r\nmixed   spaces",
    "[CLS] literal special tokens [SEP] in [MASK] text [UNK]",
    "brackets [not special] and [CLS",
    "!!! ??? ...",
    "3.14159 1e-12 0x7f 1,000,000",
    "a",
    "",
    "   ",
    "supercalifragilisticexpialidocious" * 4,
    "The rollback failed because the release tag was missing; tag before deploying. " * 30,
]


def main():
    root = sys.argv[1]
    tokenizer = Tokenizer.from_file(f"{root}/tokenizer.json")
    tokenizer.enable_truncation(256)
    tokenizer.no_padding()
    session = ort.InferenceSession(f"{root}/model.onnx", providers=["CPUExecutionProvider"])
    names = [i.name for i in session.get_inputs()]
    cases = []
    for text in TEXTS:
        encoding = tokenizer.encode(text)
        ids = encoding.ids
        feed = {
            "input_ids": np.array([ids], dtype=np.int64),
            "attention_mask": np.ones((1, len(ids)), dtype=np.int64),
        }
        if "token_type_ids" in names:
            feed["token_type_ids"] = np.zeros((1, len(ids)), dtype=np.int64)
        hidden = session.run(None, feed)[0][0]
        if len(ids) == 2:
            vector = np.zeros(hidden.shape[1])
        else:
            vector = hidden.mean(axis=0)
            vector = vector / np.linalg.norm(vector)
        cases.append(
            {"text": text, "ids": ids[1:-1], "vector": [round(float(x), 6) for x in vector]}
        )
    json.dump(
        {
            "model": "sentence-transformers/all-MiniLM-L6-v2",
            "revision": "1110a243fdf4706b3f48f1d95db1a4f5529b4d41",
            "cases": cases,
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")


main()
