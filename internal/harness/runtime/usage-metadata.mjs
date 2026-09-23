function validUsage(value) {
  return value && typeof value === 'object' ? value : undefined;
}

/**
 * Keep `usage` aligned with the most recent model request so clients can show
 * current context pressure while a multi-step turn is still running. The SDK's
 * final `totalUsage` is cumulative and remains available separately.
 */
export function createMessageMetadataTracker({ createdAt, contextWindowTokens, reportModelId = false }) {
  let currentUsage;
  let modelId;

  const metadata = () => ({
    createdAt,
    ...(currentUsage ? { usage: currentUsage } : {}),
    ...(contextWindowTokens ? { contextWindowTokens } : {}),
    ...(modelId ? { modelId } : {}),
  });

  return ({ part }) => {
    if (part.type === 'start') return { createdAt };
    if (part.type === 'finish-step') {
      currentUsage = validUsage(part.usage) || currentUsage;
      // Claude's bridge reports the selected model in its init event, which
      // the harness carries through the finished step's response. An alias
      // (opus/sonnet) is not evidence of a particular model version.
      const reported = part.response?.modelId;
      if (reportModelId && typeof reported === 'string') {
        modelId = /^claude-[a-z0-9-]+-\d+(?:-\d+)+$/.test(reported) ? reported : undefined;
      }
      return currentUsage || modelId ? metadata() : undefined;
    }
    if (part.type === 'finish') {
      const totalUsage = validUsage(part.totalUsage);
      return {
        ...metadata(),
        usage: currentUsage || totalUsage,
        ...(totalUsage ? { totalUsage } : {}),
      };
    }
    return undefined;
  };
}
