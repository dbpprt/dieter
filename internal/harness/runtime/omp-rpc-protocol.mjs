// OMP 18.4.4's negotiated v2 JSONL transport. Reject broken/oversized frames
// before allocating their declared payload; never silently truncate RPC data.
export const rpcLineLimit = 1024 * 1024;
export const rpcPayloadLimit = 64 * 1024 * 1024;
const chunkBytes = 256 * 1024;

export async function* jsonLines(stream, limit = rpcLineLimit) {
  let chunks = [],
    bytes = 0;
  for await (const incoming of stream) {
    const buffer = Buffer.from(incoming);
    let start = 0;
    for (let end = buffer.indexOf(10); end !== -1; end = buffer.indexOf(10, start)) {
      const part = buffer.subarray(start, end);
      bytes += part.length;
      if (bytes + 1 > limit) throw new Error("OMP RPC line exceeds transport limit");
      chunks.push(part);
      const line = Buffer.concat(chunks).toString("utf8");
      chunks = [];
      bytes = 0;
      start = end + 1;
      if (line.trim()) yield JSON.parse(line);
    }
    const tail = buffer.subarray(start);
    bytes += tail.length;
    if (bytes + 1 > limit) throw new Error("OMP RPC line exceeds transport limit");
    if (tail.length) chunks.push(tail);
  }
  if (bytes) throw new Error("OMP RPC stream ended inside a frame");
}

export class RPCDecoder {
  pending;
  push(frame) {
    if (!frame || typeof frame !== "object" || Array.isArray(frame))
      throw new Error("Invalid OMP RPC frame");
    if (frame.type !== "rpc_chunk") {
      if (this.pending) throw new Error("OMP RPC chunk sequence interrupted");
      return frame;
    }
    const { chunkId, index, count, byteLength, data } = frame;
    if (
      typeof chunkId !== "string" ||
      !chunkId ||
      chunkId.length > 128 ||
      !Number.isSafeInteger(index) ||
      !Number.isSafeInteger(count) ||
      !Number.isSafeInteger(byteLength) ||
      index < 0 ||
      count < 2 ||
      count > rpcPayloadLimit / chunkBytes ||
      index >= count ||
      byteLength < rpcLineLimit ||
      byteLength > rpcPayloadLimit ||
      typeof data !== "string" ||
      data.length > Math.ceil(chunkBytes / 3) * 4 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data)
    ) {
      throw new Error("Invalid OMP RPC chunk metadata");
    }
    const chunk = Buffer.from(data, "base64");
    if (!chunk.length || chunk.length > chunkBytes || chunk.toString("base64") !== data)
      throw new Error("Invalid OMP RPC chunk data");
    if (!this.pending) {
      if (index !== 0) throw new Error("OMP RPC chunk sequence must start at zero");
      this.pending = { chunkId, count, byteLength, next: 0, bytes: 0, chunks: [] };
    }
    const pending = this.pending;
    if (
      chunkId !== pending.chunkId ||
      count !== pending.count ||
      byteLength !== pending.byteLength ||
      index !== pending.next++
    ) {
      throw new Error("OMP RPC chunk sequence mismatch");
    }
    pending.bytes += chunk.length;
    if (pending.bytes > byteLength) throw new Error("OMP RPC chunks exceed declared length");
    pending.chunks.push(chunk);
    if (pending.next < count) return;
    if (pending.bytes !== byteLength) throw new Error("OMP RPC chunk length mismatch");
    this.pending = undefined;
    const value = JSON.parse(
      new TextDecoder("utf8", { fatal: true }).decode(Buffer.concat(pending.chunks)),
    );
    if (!value || typeof value !== "object" || Array.isArray(value) || value.type === "rpc_chunk")
      throw new Error("Invalid reassembled OMP RPC frame");
    return value;
  }
  end() {
    if (this.pending) throw new Error("Incomplete OMP RPC chunk sequence");
  }
}

export async function writeJSON(stream, value, limit = rpcPayloadLimit + 1024) {
  const line = JSON.stringify(value) + "\n";
  if (Buffer.byteLength(line) > limit) throw new Error("OMP RPC command exceeds transport limit");
  await new Promise((resolve, reject) =>
    stream.write(line, (error) => (error ? reject(error) : resolve())),
  );
}
