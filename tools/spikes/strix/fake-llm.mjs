#!/usr/bin/env node
// Scripted OpenAI-compatible Chat Completions server for the Strix spike.
//
// It lets the real Strix engine run end to end (Docker sandbox, agent graph,
// reporting, run directory, teardown, resume) without a paid model. The script
// is schema-driven: each step names a tool, and the server only calls tools
// the request actually offers, so it survives small upstream schema changes.
//
// Usage: node fake-llm.mjs --port 47811 --log /path/requests.ndjson
//   FAKE_CHILD_SLEEP=120  makes the child agent run `sleep 120` (cancel tests)
//   FAKE_DELAY_MS=300     delays every response (live-projection tests)

import { createServer } from "node:http";
import { appendFileSync } from "node:fs";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    port: { type: "string", default: "47811" },
    log: { type: "string", default: "" },
  },
});
const delayMs = Number(process.env.FAKE_DELAY_MS || 0);
const childSleep = Number(process.env.FAKE_CHILD_SLEEP || 0);

const cvss = {
  attack_vector: "N",
  attack_complexity: "L",
  privileges_required: "N",
  user_interaction: "N",
  scope: "U",
  confidentiality: "H",
  integrity: "H",
  availability: "H",
};

const rootScript = [
  {
    text: "Planning the assessment of the fixture service.",
    tool: "create_todo",
    args: () => ({
      todos: JSON.stringify([
        { title: "Map the HTTP surface", priority: "high" },
        { title: "Test /ping for command injection", priority: "high" },
        { title: "Test /user for IDOR", priority: "medium" },
      ]),
    }),
  },
  {
    text: "Listing the workspace and searching for shell sinks.",
    tool: /^(exec_command|shell|terminal|run_command|bash)/,
    args: (schema) =>
      shellArgs(schema, "ls -la /workspace && grep -rn execSync /workspace || true"),
  },
  {
    text: "Delegating the access-control review to a specialist.",
    tool: "create_agent",
    args: () => ({
      name: "Access control specialist",
      task: "Review /user in app/server.js for IDOR and report back with agent_finish.",
      inherit_context: false,
      skills: [],
    }),
  },
  {
    text: "Waiting for the specialist's report.",
    tool: "wait_for_agents",
    args: () => ({ reason: "Waiting for the access control specialist", timeout_seconds: 300 }),
  },
  {
    text: "Filing the confirmed command injection.",
    tool: "create_vulnerability_report",
    args: () => ({
      title: "OS command injection in /ping host parameter",
      description: "The host query parameter is concatenated into a shell command.",
      impact: "Remote unauthenticated code execution as the service user.",
      target: "/workspace",
      technical_analysis: "server.js passes url.searchParams.get('host') to execSync unescaped.",
      poc_description: "Request /ping?host=127.0.0.1;id and observe id output.",
      poc_script_code: "curl 'http://localhost:8080/ping?host=127.0.0.1;id'",
      remediation_steps: "Use execFile with an argument array and validate the host.",
      evidence: "app/server.js line 15 builds the command by string concatenation.",
      assumptions: "The service is reachable by untrusted clients.",
      counterevidence: "None found.",
      confidence: "high",
      severity_change_conditions: "Lower if the endpoint is only reachable from loopback.",
      fix_effort: "low",
      cvss_breakdown: cvss,
      endpoint: "/ping",
      method: "GET",
      cwe: "CWE-78",
    }),
  },
  {
    text: "Wrapping up.",
    tool: "finish_scan",
    args: () => ({
      executive_summary: "One critical command injection and one IDOR were identified.",
      methodology: "White-box review of the fixture service following OWASP WSTG.",
      technical_analysis: "The /ping handler shells out with untrusted input.",
      recommendations: "Replace shell invocation with execFile; add authorization to /user.",
    }),
  },
];

const childScript = [
  {
    text: "Checking the sandbox identity.",
    tool: /^(exec_command|shell|terminal|run_command|bash)/,
    args: (schema) => shellArgs(schema, childSleep ? `sleep ${childSleep}; id` : "id && uname -m"),
  },
  {
    text: "Reporting back to the root agent.",
    tool: "agent_finish",
    args: () => ({
      result_summary: "/user returns any user record by id without authorization (IDOR).",
      findings: ["IDOR on GET /user?id=N exposes admin flag of every user"],
      success: true,
    }),
  },
];

function shellArgs(schema, command) {
  const props = schema?.properties || {};
  const key = ["command", "cmd", "commands", "input"].find((name) => name in props) || "command";
  const value = props[key]?.type === "array" ? [command] : command;
  const args = { [key]: value };
  for (const required of schema?.required || []) {
    if (required in args) continue;
    const prop = props[required] || {};
    if (prop.type === "boolean") args[required] = false;
    else if (prop.type === "integer" || prop.type === "number") args[required] = 60;
    else args[required] = "";
  }
  return args;
}

function pickStep(script, tools, done) {
  const names = new Map(tools.map((tool) => [tool.function?.name, tool.function]));
  for (let index = done; index < script.length; index++) {
    const step = script[index];
    const match = [...names.keys()].find((name) =>
      typeof step.tool === "string" ? name === step.tool : step.tool.test(name || ""),
    );
    if (match) return { step, name: match, schema: names.get(match)?.parameters };
  }
  return undefined;
}

let counter = 0;
function completion(body) {
  const tools = Array.isArray(body.tools) ? body.tools : [];
  const toolNames = tools.map((tool) => tool.function?.name);
  const messages = Array.isArray(body.messages) ? body.messages : [];
  const done = messages.filter((m) => m.role === "assistant" && m.tool_calls?.length).length;
  const role = toolNames.includes("finish_scan")
    ? "root"
    : toolNames.includes("agent_finish")
      ? "child"
      : "auxiliary";
  let text = "OK.";
  let call;
  if (role !== "auxiliary") {
    // Each assistant tool turn is one script step; skipped tools do not count.
    const script = role === "root" ? rootScript : childScript;
    // A resumed run carries the earlier history; past the script, end the
    // turn again with the role's lifecycle tool (finish_scan / agent_finish).
    const pick =
      pickStep(script, tools, Math.min(done, script.length)) ??
      pickStep(script, tools, script.length - 1);
    if (pick) {
      text = pick.step.text;
      call = {
        id: `call_${++counter}_${Date.now().toString(36)}`,
        type: "function",
        function: { name: pick.name, arguments: JSON.stringify(pick.step.args(pick.schema)) },
      };
    } else {
      text = "Nothing left to do.";
    }
  }
  return { role, done, toolNames, text, call };
}

const server = createServer((req, res) => {
  let raw = "";
  req.on("data", (chunk) => (raw += chunk));
  req.on("end", async () => {
    if (req.method === "GET" && req.url.endsWith("/models")) {
      res.setHeader("content-type", "application/json");
      return res.end(
        JSON.stringify({ object: "list", data: [{ id: "fake-model", object: "model" }] }),
      );
    }
    if (req.method !== "POST" || !req.url.endsWith("/chat/completions")) {
      res.statusCode = 404;
      return res.end();
    }
    let body = {};
    try {
      body = JSON.parse(raw || "{}");
    } catch {}
    const result = completion(body);
    if (values.log) {
      const lastTool = [...(body.messages || [])].reverse().find((m) => m.role === "tool");
      appendFileSync(
        values.log,
        JSON.stringify({
          at: new Date().toISOString(),
          stream: body.stream === true,
          role: result.role,
          step: result.done,
          messages: (body.messages || []).length,
          tools: result.toolNames,
          lastToolOutput: lastTool ? String(lastTool.content).slice(0, 400) : undefined,
          firstSystem:
            result.role === "auxiliary"
              ? String(body.messages?.[0]?.content).slice(0, 300)
              : undefined,
          reply: result.call?.function.name || result.text,
        }) + "\n",
      );
    }
    if (delayMs) await new Promise((resolve) => setTimeout(resolve, delayMs));
    const id = `chatcmpl-${++counter}`;
    const created = Math.floor(Date.now() / 1000);
    const usage = { prompt_tokens: 1200, completion_tokens: 80, total_tokens: 1280 };
    const message = { role: "assistant", content: result.text };
    if (result.call) message.tool_calls = [result.call];
    const finish = result.call ? "tool_calls" : "stop";
    if (body.stream !== true) {
      res.setHeader("content-type", "application/json");
      return res.end(
        JSON.stringify({
          id,
          object: "chat.completion",
          created,
          model: body.model,
          choices: [{ index: 0, message, finish_reason: finish }],
          usage,
        }),
      );
    }
    res.setHeader("content-type", "text/event-stream");
    const send = (choices, extra = {}) =>
      res.write(
        `data: ${JSON.stringify({ id, object: "chat.completion.chunk", created, model: body.model, choices, ...extra })}\n\n`,
      );
    send([{ index: 0, delta: { role: "assistant", content: result.text }, finish_reason: null }]);
    if (result.call) {
      send([
        {
          index: 0,
          delta: { tool_calls: [{ index: 0, ...result.call }] },
          finish_reason: null,
        },
      ]);
    }
    send([{ index: 0, delta: {}, finish_reason: finish }]);
    if (body.stream_options?.include_usage) send([], { usage });
    res.end("data: [DONE]\n\n");
  });
});
server.listen(Number(values.port), "127.0.0.1", () => {
  console.log(`fake-llm listening on http://127.0.0.1:${values.port}/v1`);
});
