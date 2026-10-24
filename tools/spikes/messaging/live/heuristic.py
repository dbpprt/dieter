"""heuristic.py TOOLS_DIR...: replay a Python copy of internal/engine/channels_text.go's
Bash write heuristic (mutatingCommand) on dumped tool inputs (diagnostic only)."""

import base64, glob, json, re, sys

mutating = re.compile(
    r"(^|[;&|(\s])(sed\s+-i|perl\s+-[a-z]*i|tee\b|mv\s|cp\s|rm\s|truncate\b|touch\s|git\s+(add|rm|mv|checkout|restore|apply))|>>?\s*[^\s&|>]"
)
files = re.compile(r"src/module\d\.js")
for d in sys.argv[1:]:
    for f in sorted(glob.glob(d + "/*.json"), key=lambda p: int(p.rsplit("/", 1)[1].split(".")[0])):
        cmd = json.loads(base64.b64decode(json.load(open(f))["inputJson"])).get("command", "")
        writes = "write_text" in cmd or "sed -i" in cmd or ">>" in cmd
        m = mutating.search(cmd)
        print(
            f"{f.split('/')[-3]}/{f.split('/')[-2]}/{f.split('/')[-1]:7} writes_file={str(writes):5} heuristic={'match ' + repr(m.group(0).strip()) if m else 'no-match':28} paths={sorted(set(files.findall(cmd)))}"
        )
