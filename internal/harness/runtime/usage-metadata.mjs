function validUsage(value) {
  return value && typeof value === 'object' ? value : undefined;
}

/**
 * Keep `usage` aligned with the most recent model request so clients can show
 * current context pressure while a multi-step turn is still running. The SDK's
 * final `totalUsage` is cumulative and remains available separately.
 */
export function createMessageMetadataTracker({ createdAt, contextWindowTokens }) {
  let currentUsage;

  return ({ part }) => {
    if (part.type === 'start') return { createdAt };
    if (part.type === 'finish-step') {
      currentUsage = validUsage(part.usage) || currentUsage;
      return currentUsage ? { createdAt, usage: currentUsage, contextWindowTokens } : undefined;
    }
    if (part.type === 'finish') {
      const totalUsage = validUsage(part.totalUsage);
      return {
        createdAt,
        usage: currentUsage || totalUsage,
        ...(totalUsage ? { totalUsage } : {}),
        contextWindowTokens,
      };
    }
    return undefined;
  };
}
