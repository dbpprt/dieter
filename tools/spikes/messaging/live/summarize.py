"""summarize.py TRANSCRIPT.json: one line per message part (role, id, part
type, tool name/input/output excerpt, peer notices, text)."""

import json, sys


def clip(value, n=260):
    s = value if isinstance(value, str) else json.dumps(value)
    s = s.replace("\n", "\\n")
    return s if len(s) <= n else s[:n] + "…"


d = json.load(open(sys.argv[1]))
conv = d.get("conversation", d)
print("status:", conv.get("status"), "messages:", len(conv.get("messages", [])))
for m in conv.get("messages", []):
    meta = m.get("metadata") or {}
    print(f"--- {m.get('role')} {m.get('id')} {clip(meta, 200) if meta else ''}")
    for p in m.get("parts", []):
        t = p.get("type", "")
        if t == "text":
            print("  text:", clip(p.get("text", ""), 600))
        elif t == "reasoning":
            print("  reasoning:", clip(p.get("text", ""), 200))
        elif t.startswith("tool-") or t == "dynamic-tool":
            name = p.get("toolName") or t[5:]
            print(
                f"  tool {name} [{p.get('state')}] id={p.get('toolCallId')} in={clip(p.get('input') if p.get('input') is not None else p.get('inputPreview'), 300)} out={clip(p.get('output') if p.get('output') is not None else (p.get('outputPreview') or p.get('errorText')), 300)}"
            )
        elif t.startswith("data-"):
            print(f"  {t}:", clip(p.get("data"), 700))
        elif t in ("step-start",):
            continue
        else:
            print(f"  {t}:", clip(p, 200))
