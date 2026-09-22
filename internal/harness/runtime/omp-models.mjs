export function normalizeOMPDiscovery(modelsDocument, rolesDocument) {
  if (!modelsDocument || !Array.isArray(modelsDocument.models) || modelsDocument.models.length === 0) {
    throw new Error('OMP model catalog is empty');
  }
  const defaultModel = rolesDocument && typeof rolesDocument.default === 'string'
    ? rolesDocument.default.trim() : '';
  return { models: modelsDocument.models, ...(defaultModel ? { defaultModel } : {}) };
}
