function selectValues(option) {
  if (!option || option.type !== 'select' || !Array.isArray(option.options)) return [];
  return option.options.flatMap(candidate => (
    candidate && Array.isArray(candidate.options)
      ? candidate.options.map(value => ({ ...value, provider: candidate.group, providerName: candidate.name }))
      : [candidate]
  ));
}

// DSH deliberately treats session configuration values as opaque ACP strings.
// Its model option currently encodes [provider, model]; decoding that stable
// DSH contract gives Dieter a readable selector while preserving the exact
// value for session/set_config_option.
export function parseDSHModelOptions(configOptions) {
  const option = Array.isArray(configOptions)
    ? configOptions.find(candidate => candidate?.id === 'model')
    : undefined;
  if (!option) throw new Error('DSH did not advertise the standard ACP model option');

  const models = [];
  const seen = new Set();
  for (const candidate of selectValues(option)) {
    if (
      !candidate || typeof candidate.value !== 'string'
      || typeof candidate.name !== 'string' || !candidate.name.trim()
    ) continue;
    let route;
    try {
      route = JSON.parse(candidate.value);
    } catch {
      continue;
    }
    if (
      !Array.isArray(route) || route.length !== 2
      || route.some(value => typeof value !== 'string' || !value.trim())
    ) continue;
    const [provider, model] = route;
    const id = `${provider}/${model}`;
    if (seen.has(id)) continue;
    seen.add(id);
    const providerName = typeof candidate.providerName === 'string' && candidate.providerName.trim()
      ? candidate.providerName.trim()
      : provider;
    models.push({
      id,
      name: `${candidate.name.trim()} · ${providerName}`,
      runtimeModel: candidate.value,
      current: candidate.value === option.currentValue,
    });
  }
  if (!models.length) throw new Error('DSH advertised no usable ACP model values');
  return models.sort((left, right) => Number(right.current) - Number(left.current));
}
