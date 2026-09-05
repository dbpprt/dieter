export const ompACPModelMapping = Object.freeze({
  type: 'session-config-option',
  path: 'model',
});

export function ompACPArgs(request, hookPath) {
  return [
    'acp',
    '--hook', hookPath,
    ...(request.effort ? [`--thinking=${request.effort}`] : []),
    ...(request.options?.advisor === 'true' ? ['--advisor'] : []),
  ];
}

export const dshPackageVersion = '0.1.2-rc.1';

export function dshACPArgs(...extra) {
  return ['--profile', 'acp', ...extra];
}
