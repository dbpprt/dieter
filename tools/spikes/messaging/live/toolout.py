"""toolout.py PAYLOAD.json [TAIL]: decode `dieter card tool-output` base64 input/output."""

import base64, json, sys

d = json.load(open(sys.argv[1]))
tail = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
for key in ("inputJson", "outputJson"):
    raw = base64.b64decode(d.get(key, "") or b"").decode("utf-8", "replace")
    try:
        value = json.loads(raw)
        if isinstance(value, dict) and isinstance(value.get("output"), str):
            print(f"== {key} exitCode={value.get('exitCode')}\n" + value["output"][-tail:])
            continue
        raw = json.dumps(value, indent=1)
    except Exception:
        pass
    print(f"== {key}\n" + raw[-tail:])
