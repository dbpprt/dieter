// Loopback stand-in for the Anthropic Messages API and the ChatGPT Codex
// Responses backend. It records which credential and model every request
// carries, so the probe can prove how OMP routes the main and advisor roles
// without a real account. Token values are never written: only their scheme,
// a short prefix, length and a SHA-256 fingerprint.
//
//   node fake-upstream.mjs <port> <log.jsonl>
import { createHash } from "node:crypto";
import { appendFileSync } from "node:fs";
import { createServer } from "node:http";
import { gunzipSync, zstdDecompressSync, brotliDecompressSync } from "node:zlib";

const port = Number(process.argv[2]);
const logPath = process.argv[3];
if (!port || !logPath) throw new Error("usage: fake-upstream.mjs <port> <log.jsonl>");

function fingerprint(value) {
  if (!value) return undefined;
  const [scheme, ...rest] = value.split(" ");
  const token = rest.length ? rest.join(" ") : scheme;
  return {
    scheme: rest.length ? scheme : "raw",
    prefix: token.slice(0, 14),
    length: token.length,
    sha256: createHash("sha256").update(token).digest("hex").slice(0, 12),
  };
}

function decode(buffer, encoding) {
  if (!buffer.length) return "";
  try {
    if (encoding === "gzip") return gunzipSync(buffer).toString("utf8");
    if (encoding === "zstd") return zstdDecompressSync(buffer).toString("utf8");
    if (encoding === "br") return brotliDecompressSync(buffer).toString("utf8");
  } catch (error) {
    return `<undecodable ${encoding}: ${error.message}>`;
  }
  return buffer.toString("utf8");
}

function sse(response, events) {
  response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  for (const [event, data] of events)
    response.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  response.end();
}

function anthropicStream(response, model, text) {
  sse(response, [
    [
      "message_start",
      {
        type: "message_start",
        message: {
          id: "msg_fake",
          type: "message",
          role: "assistant",
          model,
          content: [],
          stop_reason: null,
          stop_sequence: null,
          usage: { input_tokens: 12, output_tokens: 1 },
        },
      },
    ],
    [
      "content_block_start",
      { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    ],
    [
      "content_block_delta",
      { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
    ],
    ["content_block_stop", { type: "content_block_stop", index: 0 }],
    [
      "message_delta",
      {
        type: "message_delta",
        delta: { stop_reason: "end_turn", stop_sequence: null },
        usage: { output_tokens: 4 },
      },
    ],
    ["message_stop", { type: "message_stop" }],
  ]);
}

function codexStream(response, model, text) {
  const item = {
    id: "msg_fake",
    type: "message",
    role: "assistant",
    status: "completed",
    content: [{ type: "output_text", text, annotations: [] }],
  };
  const usage = {
    input_tokens: 12,
    output_tokens: 4,
    total_tokens: 16,
    input_tokens_details: { cached_tokens: 0 },
    output_tokens_details: { reasoning_tokens: 0 },
  };
  sse(response, [
    [
      "response.created",
      {
        type: "response.created",
        response: { id: "resp_fake", object: "response", status: "in_progress", model, output: [] },
      },
    ],
    [
      "response.output_item.added",
      {
        type: "response.output_item.added",
        output_index: 0,
        item: { ...item, status: "in_progress", content: [] },
      },
    ],
    [
      "response.content_part.added",
      {
        type: "response.content_part.added",
        item_id: "msg_fake",
        output_index: 0,
        content_index: 0,
        part: { type: "output_text", text: "", annotations: [] },
      },
    ],
    [
      "response.output_text.delta",
      {
        type: "response.output_text.delta",
        item_id: "msg_fake",
        output_index: 0,
        content_index: 0,
        delta: text,
      },
    ],
    [
      "response.output_text.done",
      {
        type: "response.output_text.done",
        item_id: "msg_fake",
        output_index: 0,
        content_index: 0,
        text,
      },
    ],
    [
      "response.content_part.done",
      {
        type: "response.content_part.done",
        item_id: "msg_fake",
        output_index: 0,
        content_index: 0,
        part: item.content[0],
      },
    ],
    ["response.output_item.done", { type: "response.output_item.done", output_index: 0, item }],
    [
      "response.completed",
      {
        type: "response.completed",
        response: {
          id: "resp_fake",
          object: "response",
          status: "completed",
          model,
          output: [item],
          usage,
        },
      },
    ],
  ]);
}

createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    const raw = decode(Buffer.concat(chunks), request.headers["content-encoding"]);
    let body;
    try {
      body = raw ? JSON.parse(raw) : undefined;
    } catch {
      body = undefined;
    }
    const url = new URL(request.url, "http://loopback");
    const isAnthropic = url.pathname.endsWith("/v1/messages");
    const isCodex = url.pathname.endsWith("/codex/responses");
    const system = JSON.stringify(body?.system ?? body?.instructions ?? "");
    const role = /advisor/i.test(system) ? "advisor" : "main";
    const record = {
      at: new Date().toISOString(),
      method: request.method,
      path: url.pathname,
      upstream: isAnthropic ? "anthropic" : isCodex ? "codex" : "other",
      role: isAnthropic || isCodex ? role : undefined,
      model: body?.model,
      stream: body?.stream,
      effort: body?.reasoning?.effort ?? body?.output_config?.effort ?? body?.thinking?.type,
      authorization: fingerprint(request.headers.authorization),
      xApiKey: fingerprint(request.headers["x-api-key"]),
      systemHead: system.slice(0, 160),
      chatgptAccountId: request.headers["chatgpt-account-id"],
      anthropicBeta: request.headers["anthropic-beta"],
      userAgent: request.headers["user-agent"],
      xApp: request.headers["x-app"],
      originator: request.headers.originator,
    };
    appendFileSync(logPath, `${JSON.stringify(record)}\n`);
    // FAKE_UPSTREAM_BODIES=<dir> keeps each request body (no credentials) for
    // working out what an auxiliary request was for.
    if (process.env.FAKE_UPSTREAM_BODIES && raw) {
      appendFileSync(
        `${process.env.FAKE_UPSTREAM_BODIES}/bodies.jsonl`,
        `${JSON.stringify({ path: url.pathname, body: body ?? raw })}\n`,
      );
    }
    // FAKE_UPSTREAM_REJECT lists token fingerprints that answer 401, standing
    // in for an access token that expired in the middle of a turn.
    const rejected = (process.env.FAKE_UPSTREAM_REJECT ?? "").split(",").filter(Boolean);
    if (
      (isAnthropic || isCodex) &&
      request.method === "POST" &&
      rejected.includes(record.authorization?.sha256)
    ) {
      response.writeHead(401, { "content-type": "application/json" });
      return response.end(
        JSON.stringify(
          isAnthropic
            ? {
                type: "error",
                error: { type: "authentication_error", message: "OAuth token has expired." },
              }
            : {
                error: {
                  message: "Provided authentication token is expired.",
                  code: "token_expired",
                },
              },
        ),
      );
    }
    if (isAnthropic && request.method === "POST") {
      return anthropicStream(
        response,
        body?.model ?? "claude",
        `ANTHROPIC-${role.toUpperCase()}-OK`,
      );
    }
    if (isCodex && request.method === "POST") {
      return codexStream(response, body?.model ?? "gpt", `CODEX-${role.toUpperCase()}-OK`);
    }
    response.writeHead(404, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: { type: "not_found", message: "fake upstream" } }));
  });
}).listen(port, "127.0.0.1", () => process.stderr.write(`fake upstream on 127.0.0.1:${port}\n`));
