// Isolated stdio MCP used by the real OMP/GLM integration test.
import readline from "node:readline";
import { appendFileSync } from "node:fs";
const [challenge, logPath] = process.argv.slice(2);
const input = readline.createInterface({ input: process.stdin });
input.on("line", (line) => {
  const request = JSON.parse(line);
  if (request.id == null) return;
  let result;
  if (request.method === "initialize")
    result = {
      protocolVersion: request.params.protocolVersion,
      capabilities: { tools: {} },
      serverInfo: { name: "dieter-rpc-fixture", version: "1.0.0" },
    };
  else if (request.method === "tools/list")
    result = {
      tools: [
        {
          name: "challenge",
          description:
            "Return the native RPC integration test challenge. Call this tool when asked for the challenge.",
          inputSchema: { type: "object", properties: {}, additionalProperties: false },
        },
      ],
    };
  else if (request.method === "tools/call") {
    appendFileSync(logPath, JSON.stringify({ name: request.params.name }) + "\n");
    result = { content: [{ type: "text", text: challenge }] };
  } else if (request.method === "ping") result = {};
  else {
    process.stdout.write(
      JSON.stringify({
        jsonrpc: "2.0",
        id: request.id,
        error: { code: -32601, message: "Unsupported fixture method" },
      }) + "\n",
    );
    return;
  }
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }) + "\n");
});
