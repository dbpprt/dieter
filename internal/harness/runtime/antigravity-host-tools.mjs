#!/usr/bin/env node
// MCP server (stdio, newline-delimited JSON-RPC) that the Antigravity CLI launches: it offers the
// host tools of the Dieter turn that runs this agy process (present_content, the background process
// tools) and forwards each call to the harness runtime (antigravity-runtime.mjs), which serves them
// at DIETER_AGY_TOOLS_URL (Bearer DIETER_AGY_TOOLS_TOKEN) in agy's environment. Registered once by
// the add-on's bridge: `agy mcp add dieter /usr/local/bin/node /opt/dieter-runtime/antigravity-host-tools.mjs`.
// Started by agy outside a Dieter turn (no URL in the environment) it offers no tools.
import readline from "node:readline";

const base = (process.env.DIETER_AGY_TOOLS_URL || "").replace(/\/+$/, "");
const token = process.env.DIETER_AGY_TOOLS_TOKEN || "";
const PROTOCOL_VERSIONS = new Set(["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]);

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
const reply = (id, result) => send({ jsonrpc: "2.0", id, result });
const replyError = (id, code, message) => send({ jsonrpc: "2.0", id, error: { code, message } });

async function host(path, init) {
  if (!base) throw new Error("no Dieter turn is running (DIETER_AGY_TOOLS_URL is not set)");
  const response = await fetch(`${base}${path}`, {
    ...init,
    headers: { ...init?.headers, authorization: `Bearer ${token}` },
  });
  if (!response.ok) throw new Error(`Dieter host tools: HTTP ${response.status} for ${path}`);
  return response.json();
}

async function listTools() {
  if (!base) return [];
  const { tools } = await host("/tools");
  return (Array.isArray(tools) ? tools : []).map((t) => ({
    name: t.name,
    description: t.description || "",
    inputSchema:
      t.inputSchema && typeof t.inputSchema === "object" ? t.inputSchema : { type: "object" },
  }));
}

async function callTool(params) {
  const { output, isError } = await host("/call", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ name: params?.name, arguments: params?.arguments ?? {} }),
  });
  return { content: [{ type: "text", text: String(output ?? "") }], isError: isError === true };
}

async function handle(message) {
  const { id, method, params } = message;
  const isRequest = id !== undefined && id !== null;
  try {
    switch (method) {
      case "initialize": {
        const requested = params?.protocolVersion;
        return reply(id, {
          protocolVersion: PROTOCOL_VERSIONS.has(requested) ? requested : "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "dieter", version: "1" },
        });
      }
      case "ping":
        return reply(id, {});
      case "tools/list":
        return reply(id, { tools: await listTools() });
      case "tools/call":
        return reply(id, await callTool(params));
      default:
        if (isRequest) replyError(id, -32601, `method not found: ${method}`);
        return; // notifications (initialized, roots/list_changed, …) need no answer
    }
  } catch (error) {
    if (!isRequest) return;
    if (method === "tools/call")
      return reply(id, {
        content: [{ type: "text", text: String(error?.message || error) }],
        isError: true,
      });
    replyError(id, -32000, String(error?.message || error));
  }
}

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on("line", (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return replyError(null, -32700, "parse error");
  }
  if (!message || typeof message !== "object" || typeof message.method !== "string") return;
  void handle(message); // requests are independent; a long host tool call must not hold up a ping
});
lines.on("close", () => process.exit(0));
