const zeroUsage = () => ({
  inputTokens: { total: 0, noCache: 0, cacheRead: 0, cacheWrite: 0 },
  outputTokens: { total: 0, text: 0 },
});

/**
 * Keep terminal harness streams valid when a runtime deliberately leaves a
 * provider-executed process running after the model has finished its turn.
 * The synthetic result only closes the transcript item; it never stops or
 * otherwise interacts with the underlying process.
 */
export function createTerminalStepReconciler(emit) {
  const pendingProviderTools = new Map();
  let stepOpen = false;
  let finished = false;

  return event => {
    if (finished) return;

    if (event.type === 'tool-call') {
      stepOpen = true;
      if (event.providerExecuted === true) {
        pendingProviderTools.set(event.toolCallId, event);
      }
    } else if (event.type === 'tool-result') {
      stepOpen = true;
      pendingProviderTools.delete(event.toolCallId);
    } else if (event.type === 'finish-step') {
      stepOpen = false;
    } else if (!['stream-start', 'finish', 'error'].includes(event.type)) {
      stepOpen = true;
    }

    if (event.type !== 'finish') {
      emit(event);
      return;
    }

    for (const toolCall of pendingProviderTools.values()) {
      emit({
        type: 'tool-result',
        toolCallId: toolCall.toolCallId,
        toolName: toolCall.toolName,
        result: {
          status: 'running',
          detached: true,
          output: 'The external process was left running after the agent turn completed.',
        },
        harnessMetadata: { board: { detachedProcess: true } },
      });
      stepOpen = true;
    }
    pendingProviderTools.clear();

    if (stepOpen) {
      emit({
        type: 'finish-step',
        finishReason: event.finishReason,
        usage: zeroUsage(),
        harnessMetadata: { board: { reconciledTerminalStep: true } },
      });
    }
    emit(event);
    finished = true;
  };
}
