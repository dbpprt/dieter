export const ompACPModelMapping = Object.freeze({
  type: 'session-config-option',
  path: 'model',
});

// OMP's CLI accepts every selector reported by `omp models`, while its ACP
// model config option exposes only the user's small model-cycling list. Launch
// new bridges with the selected CLI model so Dieter's full discovered catalog
// remains executable. Retain the previous config-option implementation solely
// to restore lifecycle state created before this change.
export const ompImplementations = Object.freeze([
  Object.freeze({ packageVersion: '18.2.9', modelStrategy: 'launch-argument' }),
  Object.freeze({ packageVersion: '18.1.10', modelStrategy: 'session-config-option' }),
]);
export const ompPackageVersions = Object.freeze(ompImplementations.map(item => item.packageVersion));
export const ompPackageVersion = ompImplementations[0].packageVersion;

export const ompStreamTimeoutSeconds = 30 * 60;

export function ompRuntimeConfig() {
  return `providers:\n  streamFirstEventTimeoutSeconds: ${ompStreamTimeoutSeconds}\n  streamIdleTimeoutSeconds: ${ompStreamTimeoutSeconds}\n`;
}

export function codexConfig(request) {
  const fastMode = request.options?.fast_mode === 'true';
  return {
    service_tier: fastMode ? 'fast' : 'default',
    features: { fast_mode: true },
  };
}

export function ompACPArgs(request, hookPath, configPath, modelStrategy = 'session-config-option') {
  return [
    'acp',
    ...(configPath ? ['--config', configPath] : []),
    '--hook', hookPath,
    ...(request.effort ? [`--thinking=${request.effort}`] : []),
    ...(request.options?.advisor === 'true' ? ['--advisor'] : []),
    ...(modelStrategy === 'launch-argument' && request.model ? [`--model=${request.model}`] : []),
  ];
}

export const dshPackageVersion = '0.1.2-rc.1';

export function dshACPArgs(...extra) {
  return ['--profile', 'acp', ...extra];
}
