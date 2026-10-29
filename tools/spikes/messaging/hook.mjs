// Hook command for Claude Code and Codex: forwards the hook input on stdin to
// the spike board and prints the board's hook output (empty means "no
// opinion", which costs the model nothing).
//
// Usage: node hook.mjs AGENT_ID BOARD_URL
const [agent, url] = process.argv.slice(2);
let input = "";
for await (const chunk of process.stdin) input += chunk;
try {
  const res = await fetch(`${url}/hook`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      agent,
      input: input ? JSON.parse(input) : {},
      spawnMs: Math.round(performance.now()), // process start → request
    }),
    signal: AbortSignal.timeout(8000),
  });
  const out = await res.text();
  if (out) process.stdout.write(out);
} catch (error) {
  // A board outage must never block the agent: print nothing, exit 0.
  process.stderr.write(`spike hook: ${error?.message ?? error}\n`);
}
