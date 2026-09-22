const maxDiagnosticLength = 4096;

function stringDetail(value) {
  if (typeof value !== 'string' || !value.trim()) return undefined;
  const trimmed = value.trim();
  return trimmed.length <= maxDiagnosticLength
    ? trimmed
    : `${trimmed.slice(0, maxDiagnosticLength - 3)}...`;
}

function providerDetail(error) {
  const seen = new Set();
  let current = error;
  for (let depth = 0; depth < 5 && current != null && !seen.has(current); depth += 1) {
    if ((typeof current === 'object' || typeof current === 'function')) seen.add(current);
    const detail = stringDetail(current?.data?.details) ?? stringDetail(current?.data?.message);
    if (detail) return detail;
    current = current?.cause;
  }
  return undefined;
}

// ACP's RequestError uses the JSON-RPC message as Error.message and keeps the
// actionable provider text under data.details. Preserve that bounded string in
// worker diagnostics without serializing arbitrary error data or credentials.
export function harnessDiagnosticErrorMessage(error) {
  const message = stringDetail(error?.message) ?? stringDetail(error) ?? 'Unknown harness error';
  const detail = providerDetail(error);
  return detail && !message.includes(detail) ? `${message}: ${detail}` : message;
}
