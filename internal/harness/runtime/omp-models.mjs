const ompVisibleModels = Object.freeze([
  Object.freeze({ selector: 'tailscale/glm-5.3-flash-exl3', name: 'GLM-5.3 Flash EXL3 · Tailscale', contextWindow: 1_000_000, thinking: ['low', 'high', 'max'] }),
  Object.freeze({ selector: 'openai-codex/gpt-6-luna', name: 'GPT-6 Luna · Codex', contextWindow: 272_000, thinking: ['low', 'medium', 'high', 'xhigh', 'max'] }),
  Object.freeze({ selector: 'openai-codex/gpt-6-sol', name: 'GPT-6 Sol · Codex', contextWindow: 272_000, thinking: ['low', 'medium', 'high', 'xhigh', 'max'] }),
  Object.freeze({ selector: 'openai-codex/gpt-6-astra', name: 'GPT-6 Astra · Codex', contextWindow: 272_000, thinking: ['low', 'medium', 'high', 'xhigh', 'max'] }),
]);
export const ompVisibleModelSelectors = Object.freeze(ompVisibleModels.map(model => model.selector));

function modelSelector(model) {
  if (typeof model?.selector === 'string' && model.selector.trim()) return model.selector.trim();
  if (typeof model?.provider === 'string' && typeof model?.id === 'string') {
    return `${model.provider.trim()}/${model.id.trim()}`;
  }
  return '';
}

export function normalizeOMPDiscovery(modelsDocument, rolesDocument) {
  if (!modelsDocument || !Array.isArray(modelsDocument.models) || modelsDocument.models.length === 0) {
    throw new Error('OMP model catalog is empty');
  }
  const bySelector = new Map(modelsDocument.models.map(model => [modelSelector(model), model]));
  const models = ompVisibleModels.map(model => bySelector.get(model.selector) ?? { ...model });
  const defaultModel = rolesDocument && typeof rolesDocument.default === 'string'
    ? rolesDocument.default.trim() : '';
  const visibleDefault = ompVisibleModelSelectors.some(selector => (
    defaultModel === selector || defaultModel.startsWith(`${selector}:`)
  ));
  return { models, ...(visibleDefault ? { defaultModel } : {}) };
}
