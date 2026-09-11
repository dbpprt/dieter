import MarkdownIt from 'markdown-it';

const kinds = new Map([
  ['mermaid', 'mermaid'],
  ['vega-lite', 'vega-lite'],
  ['vegalite', 'vega-lite'],
  ['vega', 'vega'],
]);

// All Vega I/O, including image marks and URL-valued signals, goes through this
// loader. Never delegate to Vega's HTTP or filesystem loaders.
export function createOfflineLoader() {
  const reject = async () => {
    throw new Error('External resources are disabled. Use inline data.values.');
  };
  return Object.freeze({load: reject, sanitize: reject, http: reject, file: reject});
}

export function parseChart(source) {
  const spec = JSON.parse(source);
  if (!spec || typeof spec !== 'object' || Array.isArray(spec)) {
    throw new Error('The chart must be a JSON object.');
  }
  // Embed options are host policy, not document content. In particular, embed
  // merges usermeta options after caller options, which could disable AST mode.
  function inspect(value, depth = 0, inlineData = false) {
    if (depth > 100) throw new Error('The chart specification is too deeply nested.');
    if (!value || typeof value !== 'object') return;
    for (const key of Object.keys(value)) {
      if (['__proto__', 'prototype', 'constructor'].includes(key)) {
        throw new Error('Unsupported chart property: ' + key);
      }
      if (!inlineData && (key === 'url' || key === 'href')) {
        throw new Error('External resources and chart links are disabled. Use inline data.values.');
      }
      if (!inlineData && key === 'usermeta') {
        delete value[key];
      } else {
        inspect(value[key], depth + 1, inlineData || key === 'values' || key === 'datasets');
      }
    }
  }
  inspect(spec);
  return spec;
}

function insertDiagramSVG(document, element, svg) {
  // Mermaid also sanitizes in strict mode. Keep this final boundary independent
  // of diagram syntax/configuration and do not install Mermaid click callbacks.
  const template = document.createElement('template');
  template.innerHTML = svg;
  template.content.querySelectorAll('script,foreignObject,iframe,object,embed,image,link,animate,set').forEach(node => node.remove());
  for (const node of template.content.querySelectorAll('*')) {
    for (const attribute of [...node.attributes]) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith('on') || name === 'src' ||
          ((name === 'href' || name === 'xlink:href') && !attribute.value.startsWith('#'))) {
        node.removeAttribute(attribute.name);
      }
    }
  }
  if (!template.content.querySelector('svg')) throw new Error('The diagram did not produce an SVG.');
  element.replaceChildren(template.content);
}

export function createRenderer({document, root, renderMermaid, renderChart}) {
  const markdown = new MarkdownIt({html: false, linkify: true, typographer: false});
  // Image URLs must not cause network or local-file reads. Preserve useful alt
  // text; source HTML is escaped by MarkdownIt rather than inserted into the DOM.
  markdown.renderer.rules.image = (tokens, index, options, env, self) =>
    '<span class="image-alt">' + markdown.utils.escapeHtml(self.renderInlineAsText(tokens[index].children, options, env)) + '</span>';
  const ordinaryFence = markdown.renderer.rules.fence;
  markdown.renderer.rules.fence = (tokens, index, options, env, self) => {
    const token = tokens[index];
    const kind = kinds.get(token.info.trim().split(/\s+/)[0].toLowerCase());
    if (!kind) return ordinaryFence(tokens, index, options, env, self);
    const block = env.blocks.length;
    const original = env.sourceLines.slice(token.map[0], token.map[1]).join('\n');
    env.blocks.push({kind, source: token.content});
    return `<div class="diagram" data-block="${block}" data-kind="${kind}" data-source="${markdown.utils.escapeHtml(original)}" data-state="rendering" aria-label="${kind} diagram"></div>\n`;
  };

  let generation = 0;
  let current;
  // Mermaid's configuration and render queue are global. Serializing prevents
  // themes from interleaving when a newer edit arrives during an older render.
  let mermaidQueue = Promise.resolve();

  function cleanup(state) {
    if (!state) return;
    state.active = false;
    for (const result of state.charts) result.finalize();
    for (const view of state.pendingViews) view.finalize();
    state.charts.clear();
    state.pendingViews.clear();
  }

  function showError(element, block, error) {
    element.replaceChildren();
    element.dataset.state = 'error';
    const message = document.createElement('p');
    message.className = 'diagram-error';
    message.setAttribute('role', 'status');
    message.textContent = `${block.kind}: ${String(error?.message ?? error).slice(0, 500)}`;
    const details = document.createElement('details');
    const summary = document.createElement('summary');
    summary.textContent = 'Show source';
    const pre = document.createElement('pre');
    const code = document.createElement('code');
    code.textContent = block.source;
    pre.append(code);
    details.append(summary, pre);
    element.append(message, details);
  }

  async function render(source, theme = 'light') {
    cleanup(current);
    const state = {id: ++generation, active: true, charts: new Set(), pendingViews: new Set()};
    current = state;
    const isCurrent = () => current === state && state.active;
    const mode = (typeof theme === 'object' ? theme?.mode : theme) === 'dark' ? 'dark' : 'light';
    document.documentElement.dataset.theme = mode;
    root.dataset.generation = String(state.id);
    root.dataset.renderState = 'rendering';
    const env = {blocks: [], sourceLines: String(source ?? '').split('\n')};
    root.innerHTML = markdown.render(String(source ?? ''), env);
    if (!root.childNodes.length) {
      const empty = document.createElement('p');
      empty.className = 'empty-document';
      empty.textContent = 'Empty Markdown document';
      root.append(empty);
    }
    let renderedBlocks = 0;
    let failedBlocks = 0;
    await Promise.all(env.blocks.map(async (block, index) => {
      const element = root.querySelector(`[data-block="${index}"]`);
      try {
        if (block.kind === 'mermaid' && block.source.length > 100_000) {
          throw new Error('Mermaid source exceeds the 100,000 character limit.');
        }
        if (block.kind !== 'mermaid' && new TextEncoder().encode(block.source).byteLength > 1_000_000) {
          throw new Error('Chart source exceeds the 1 MB limit.');
        }
        if (block.kind === 'mermaid') {
          const result = mermaidQueue.then(async () => {
            if (!isCurrent()) return;
            return renderMermaid({id: `dieter-diagram-${state.id}-${index}`, source: block.source, theme: mode, element});
          });
          mermaidQueue = result.catch(() => {});
          const svg = await result;
          if (!isCurrent()) return;
          insertDiagramSVG(document, element, svg);
        } else {
          const spec = parseChart(block.source);
          const result = await renderChart({element, spec, kind: block.kind, theme: mode, isCurrent,
            onView(view) { state.pendingViews.add(view); }});
          state.pendingViews.delete(result.view);
          if (!isCurrent()) {
            result.finalize();
            return;
          }
          state.charts.add(result);
        }
        if (isCurrent()) {
          element.dataset.state = 'rendered';
          renderedBlocks += 1;
        }
      } catch (error) {
        if (isCurrent()) {
          showError(element, block, error);
          failedBlocks += 1;
        }
      }
    }));
    if (isCurrent()) root.dataset.renderState = 'ready';
    return {generation: state.id, stale: !isCurrent(), renderedBlocks, failedBlocks};
  }

  function dispose() {
    cleanup(current);
    current = undefined;
    ++generation;
    root.replaceChildren();
    root.dataset.renderState = 'disposed';
  }

  return Object.freeze({render, dispose});
}
