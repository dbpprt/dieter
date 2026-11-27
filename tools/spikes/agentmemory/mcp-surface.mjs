#!/usr/bin/env node
// Measures the tool surface agentmemory's own MCP server would add to every
// turn if Dieter passed it through (mcpServers), against the two host tools
// turn.mjs defines. Connects to `agentmemory mcp` over stdio in proxy mode.
//
//   AGENTMEMORY_URL=… AGENTMEMORY_SECRET=… node mcp-surface.mjs RUNTIME_DIR AGENTMEMORY_BIN [core|all]

import { join } from "node:path";

const [runtimeDir, bin, toolsMode = "all"] = process.argv.slice(2);
const { Client } = await import(
  join(runtimeDir, "node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js")
);
const { StdioClientTransport } = await import(
  join(runtimeDir, "node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js")
);

const started = Date.now();
const transport = new StdioClientTransport({
  command: bin,
  args: ["mcp"],
  env: { ...process.env, AGENTMEMORY_TOOLS: toolsMode },
  stderr: "ignore",
});
const client = new Client({ name: "dieter-spike", version: "0" });
await client.connect(transport);
const connectedMs = Date.now() - started;
const { tools } = await client.listTools();
const definitions = JSON.stringify(
  tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
);
console.log(
  JSON.stringify({
    toolsMode,
    connectedMs,
    tools: tools.length,
    definitionBytes: definitions.length,
    approxTokens: Math.round(definitions.length / 4),
    names: tools.map((tool) => tool.name),
  }),
);
await client.close();
