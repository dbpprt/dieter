function modelSelector(model) {
  if (typeof model?.selector === "string" && model.selector.trim()) return model.selector.trim();
  if (typeof model?.provider === "string" && typeof model?.id === "string") {
    return `${model.provider.trim()}/${model.id.trim()}`;
  }
  return "";
}

export function normalizeOMPDiscovery(modelsDocument, rolesDocument) {
  if (!modelsDocument || !Array.isArray(modelsDocument.models)) {
    throw new Error("OMP model catalog is invalid");
  }
  const models = modelsDocument.models;
  const defaultModel =
    rolesDocument && typeof rolesDocument.default === "string" ? rolesDocument.default.trim() : "";
  const visibleDefault = models.some((model) => {
    const selector = modelSelector(model);
    return (
      selector &&
      (defaultModel === selector ||
        (model.thinking ?? []).some((level) => defaultModel === `${selector}:${level}`))
    );
  });
  return { models, ...(visibleDefault ? { defaultModel } : {}) };
}
