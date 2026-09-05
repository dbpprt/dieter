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
