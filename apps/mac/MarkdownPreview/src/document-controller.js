import {buildClipboardPayload, selectionMarkdown} from './clipboard.js';
import {createPreviewScroll} from './scroll-sync.js';
import {createDiagramSurface, diagramDimensions, diagramMarkdown} from './diagram-surface.js';

// Editing belongs to the native Markdown editor. This surface only renders its
// current source and supplies explicit, sanitized clipboard representations.
export function createMarkdownDocument({document, root, preview, postMessage}) {
  let disposed = false;
  let nextID = 0;
  let desired = null;
  const scroll = createPreviewScroll({document, root, postMessage: payload => {
    if (desired?.mode === 'preview') postMessage(payload);
  }});
  const diagram = createDiagramSurface({document, root, postMessage});

  function contextMenu(event) {
    if (disposed || !desired || !root.contains(event.target)) return;
    event.preventDefault();
    const selected = selectionMarkdown({document, root, source: desired.source});
    postMessage(buildClipboardPayload({document, markdown: selected ?? desired.source}));
  }
  root.addEventListener('contextmenu', contextMenu);

  async function render(source, theme = 'light', _editing = false, _revision = 0) {
    if (disposed) return {stale: true};
    const request = {id: ++nextID, mode: 'preview', source: String(source ?? ''), theme: theme === 'dark' ? 'dark' : 'light'};
    desired = request;
    diagram.clear();
    scroll.prepareForRender();
    document.documentElement.dataset.theme = request.theme;
    root.dataset.mode = 'preview';
    // Start immediately: the renderer invalidates superseded diagrams so a
    // newer source never waits behind an older Mermaid render.
    const rendering = preview.render(request.source, request.theme);
    scroll.preservePosition();
    const result = await rendering;
    if (!disposed && desired === request) scroll.preservePosition();
    return {...result, stale: result.stale === true || disposed || desired !== request};
  }

  async function renderDiagram(kind, source, theme = 'light', blockID = '') {
    if (disposed) return {stale: true};
    const fenced = diagramMarkdown(kind, source);
    const request = {id: nextID + 1, mode: 'diagram', kind: fenced.kind, source: fenced.markdown,
      theme: theme === 'dark' ? 'dark' : 'light', blockID: typeof blockID === 'string' ? blockID.slice(0, 128) : '',
      viewportWidth: document.documentElement.clientWidth};
    if (desired?.mode === 'diagram' && desired.source === request.source && desired.theme === request.theme
        && desired.blockID === request.blockID && desired.viewportWidth === request.viewportWidth) return desired.rendering;
    nextID++;
    desired = request;
    diagram.prepare(request);
    scroll.setScrollProgress(0);
    request.rendering = preview.render(request.source, request.theme).then(result => {
      const stale = result.stale === true || disposed || desired !== request;
      if (!stale) diagram.rendered(request);
      return {...result, stale, ...(!stale ? diagramDimensions(root) : {}),
        error: !stale && result.failedBlocks > 0 ? root.querySelector('.diagram-error')?.textContent?.slice(0, 500) ?? null : null};
    });
    return request.rendering;
  }

  async function dispose() {
    if (disposed) return;
    disposed = true;
    desired = null;
    root.removeEventListener('contextmenu', contextMenu);
    diagram.dispose();
    scroll.dispose();
    preview.dispose();
    root.dataset.mode = 'disposed';
  }
  return Object.freeze({render, renderDiagram, dispose, setScrollProgress: scroll.setScrollProgress});
}
