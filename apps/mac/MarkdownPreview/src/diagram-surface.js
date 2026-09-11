const kinds = new Map([['mermaid', 'mermaid'], ['vega-lite', 'vega-lite'], ['vegalite', 'vega-lite'], ['vega', 'vega']]);

export function diagramMarkdown(kind, source) {
  const normalized = kinds.get(String(kind ?? '').trim().toLowerCase());
  if (!normalized) throw new TypeError('Unsupported diagram type.');
  const body = String(source ?? '');
  // A source string containing Markdown fences must remain a single code
  // block; it can never add ordinary Markdown or another diagram to this view.
  let length = 3;
  for (const match of body.matchAll(/`+/g)) length = Math.max(length, match[0].length + 1);
  const fence = '`'.repeat(length);
  return {kind: normalized, markdown: `${fence}${normalized}\n${body}${body.endsWith('\n') ? '' : '\n'}${fence}\n`};
}

export function diagramDimensions(root) {
  const bounds = root.getBoundingClientRect();
  return Object.fromEntries(['width', 'height'].map(key => [key,
    Number.isFinite(bounds[key]) ? Math.max(0, Math.ceil(bounds[key])) : 0]));
}

export function createDiagramSurface({document, root, postMessage}) {
  const window = document.defaultView;
  let current = null;
  let ready = false;
  let disposed = false;
  let lastHeight = null;
  let observer = null;

  function reportSize() {
    if (disposed || !current || !ready) return;
    const {height} = diagramDimensions(root);
    if (height <= 0 || height === lastHeight) return;
    lastHeight = height;
    postMessage({type: 'diagramSize', blockID: current.blockID, height});
  }
  function activate(event) {
    if (disposed || !current || !root.contains(event.target)) return;
    if (event.type === 'keydown') {
      if (event.target !== root || event.repeat || !['Enter', ' '].includes(event.key)) return;
    } else if (event.button !== 0) return;
    event.preventDefault();
    postMessage({type: 'diagramActivate', blockID: current.blockID});
  }
  root.addEventListener('click', activate);
  root.addEventListener('keydown', activate);

  function prepare(request) {
    current = request;
    ready = false;
    lastHeight = null;
    document.documentElement.dataset.surface = 'diagram';
    root.dataset.mode = 'diagram';
    root.tabIndex = 0;
    root.setAttribute('role', 'button');
    root.setAttribute('aria-label', `${request.kind === 'mermaid' ? 'Mermaid' : 'Vega'} diagram. Activate to edit source.`);
    if (!observer && window.ResizeObserver) observer = new window.ResizeObserver(reportSize);
    observer?.observe(root);
  }
  function rendered(request) {
    if (disposed || current !== request) return;
    ready = true;
    // The entire inline diagram is one edit affordance. Embedded chart inputs
    // cannot steal focus from the source-opening action in this mode.
    for (const child of root.children) {
      child.setAttribute('inert', '');
      child.setAttribute('aria-hidden', 'true');
    }
    reportSize();
  }
  function clear() {
    current = null;
    ready = false;
    lastHeight = null;
    observer?.disconnect();
    delete document.documentElement.dataset.surface;
    root.removeAttribute('tabindex');
    root.removeAttribute('role');
    root.removeAttribute('aria-label');
  }
  function dispose() {
    if (disposed) return;
    disposed = true;
    clear();
    root.removeEventListener('click', activate);
    root.removeEventListener('keydown', activate);
  }
  return Object.freeze({prepare, rendered, clear, dispose});
}
