import MarkdownIt from 'markdown-it';
import TurndownService from 'turndown';
import {gfm} from 'turndown-plugin-gfm';

const semanticTags = new Set(['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'br', 'hr',
  'strong', 'em', 'del', 'code', 'pre', 'blockquote', 'ul', 'ol', 'li',
  'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'caption', 'a']);
const discardedTags = new Set(['script', 'style', 'iframe', 'object', 'embed', 'svg', 'math',
  'img', 'picture', 'source', 'audio', 'video', 'canvas', 'link', 'meta', 'base',
  'form', 'button', 'input', 'textarea', 'select', 'option', 'template', 'noscript']);
const aliases = {b: 'strong', i: 'em', s: 'del', strike: 'del'};
const htmlNamespace = 'http://www.w3.org/1999/xhtml';

function safeLink(value) {
  try {
    const url = new URL(value);
    return ['https:', 'http:'].includes(url.protocol) ? url.href : null;
  } catch {
    return null;
  }
}

// Parse into inert template contents and construct fresh semantic elements.
// No source element, style, event handler, resource URL or active control is
// ever attached to the document or returned for the native clipboard.
export function sanitizeClipboardHTML(document, html) {
  const input = document.createElement('template');
  input.innerHTML = String(html ?? '');
  const output = document.createElement('div');
  function copy(node, parent) {
    if (node.nodeType === 3) {
      parent.append(document.createTextNode(node.data));
      return;
    }
    if (node.nodeType !== 1 || node.namespaceURI !== htmlNamespace) return;
    const originalTag = node.localName;
    const tag = aliases[originalTag] ?? originalTag;
    if (tag === 'input' && node.getAttribute('type')?.toLowerCase() === 'checkbox') {
      parent.append(document.createTextNode(node.hasAttribute('checked') ? '[x] ' : '[ ] '));
      return;
    }
    if (tag === 'img') {
      parent.append(document.createTextNode(node.getAttribute('alt') ?? ''));
      return;
    }
    if (discardedTags.has(tag)) return;
    if (!semanticTags.has(tag)) {
      for (const child of node.childNodes) copy(child, parent);
      return;
    }
    const element = document.createElement(tag);
    if (tag === 'a') {
      const href = safeLink(node.getAttribute('href') ?? '');
      if (href) element.setAttribute('href', href);
      if (node.hasAttribute('title')) element.setAttribute('title', node.getAttribute('title'));
    }
    if (tag === 'code') {
      const language = [...node.classList].find(value => /^language-[a-z0-9_+.-]+$/i.test(value));
      if (language) element.setAttribute('class', language);
    }
    if (tag === 'ol' && /^\d{1,9}$/.test(node.getAttribute('start') ?? '')) {
      element.setAttribute('start', node.getAttribute('start'));
    }
    if (tag === 'td' || tag === 'th') {
      for (const attribute of ['colspan', 'rowspan']) {
        const value = node.getAttribute(attribute);
        if (/^[1-9]\d{0,2}$/.test(value ?? '')) element.setAttribute(attribute, value);
      }
      const align = node.getAttribute('align');
      if (['left', 'center', 'right'].includes(align)) element.setAttribute('align', align);
    }
    for (const child of node.childNodes) copy(child, element);
    parent.append(element);
  }
  for (const child of input.content.childNodes) copy(child, output);
  return output.innerHTML;
}

const markdown = new MarkdownIt({html: false, linkify: true, typographer: false});
markdown.renderer.rules.image = (tokens, index, options, env, renderer) =>
  markdown.utils.escapeHtml(renderer.renderInlineAsText(tokens[index].children, options, env));

function plainText(document, html) {
  const template = document.createElement('template');
  template.innerHTML = html;
  function text(node) {
    if (node.nodeType === 3) return node.data;
    if (node.nodeType !== 1 && node.nodeType !== 11) return '';
    const tag = node.localName;
    if (tag === 'br') return '\n';
    if (tag === 'hr') return '\n\n';
    if (tag === 'pre') return '\n\n' + node.textContent + '\n\n';
    if (tag === 'tr') return [...node.children].map(cell => text(cell).trim()).join('\t') + '\n';
    const contents = [...node.childNodes].map(text).join('');
    if (tag === 'li') {
      const parent = node.parentElement;
      const marker = parent?.localName === 'ol'
        ? `${Number(parent.getAttribute('start') ?? 1) + [...parent.children].indexOf(node)}. ` : '- ';
      return marker + contents.trim() + '\n';
    }
    if (['p', 'blockquote', 'ul', 'ol', 'table', 'caption', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'].includes(tag)) {
      return '\n\n' + contents + '\n\n';
    }
    return contents;
  }
  return text(template.content).replace(/\n[\t ]*\n(?:[\t ]*\n)+/g, '\n\n').replace(/^\n+|\n+$/g, '');
}

// Supply selected Markdown from the editor/preview serializer, or the complete
// source when no selection exists. Rich HTML always derives from that source,
// so Mermaid/Vega fences copy as code instead of rendered SVG or preview UI.
export function buildClipboardPayload({document, markdown: source}) {
  const value = String(source ?? '');
  const html = sanitizeClipboardHTML(document, markdown.render(value));
  return {type: 'contextMenu', markdown: value, html, text: plainText(document, html)};
}

// The preview annotates each .diagram with data-source containing its complete
// original fenced block. An intersection with any part of a diagram copies the
// entire block. Returning null lets the caller fall back to the complete source.
export function selectionMarkdown({document, root, source}) {
  const selection = document.defaultView?.getSelection();
  if (!selection || selection.isCollapsed || !selection.rangeCount) return null;
  const range = selection.getRangeAt(0);
  if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) return null;
  const wholeRoot = document.createRange();
  wholeRoot.selectNodeContents(root);
  if (typeof source === 'string' && range.compareBoundaryPoints(0, wholeRoot) <= 0 &&
      range.compareBoundaryPoints(2, wholeRoot) >= 0) return source;
  for (const diagram of root.querySelectorAll('.diagram')) {
    if (range.intersectsNode(diagram) && !diagram.hasAttribute('data-source')) return null;
  }

  const container = document.createElement('div');
  container.append(range.cloneContents());
  // cloneContents omits common ancestors. Recreate them so a substring selected
  // inside strong/em/a/code/headings retains its formatting and list context.
  let ancestor = range.commonAncestorContainer.nodeType === 1
    ? range.commonAncestorContainer : range.commonAncestorContainer.parentElement;
  while (ancestor && ancestor !== root) {
    const wrapper = ancestor.cloneNode(false);
    wrapper.append(...container.childNodes);
    container.append(wrapper);
    ancestor = ancestor.parentElement;
  }
  for (const diagram of container.querySelectorAll('.diagram[data-source]')) {
    const code = document.createElement('pre');
    code.setAttribute('data-dieter-source', diagram.getAttribute('data-source'));
    code.textContent = diagram.getAttribute('data-source');
    diagram.replaceWith(code);
  }
  container.querySelectorAll('script,style,svg,math,iframe,object,embed,button,select,textarea,img').forEach(node => node.remove());
  // A partial selection may omit the heading row. Give that fragment an empty
  // header so GFM conversion keeps the selected cells as a Markdown table.
  for (const table of container.querySelectorAll('table')) {
    if (!table.rows.length) { table.remove(); continue; }
    const first = table.rows[0];
    if (first.parentElement.localName !== 'thead' && ![...first.cells].every(cell => cell.localName === 'th')) {
      const header = document.createElement('thead');
      const row = document.createElement('tr');
      for (const _ of first.cells) row.append(document.createElement('th'));
      header.append(row);
      table.prepend(header);
    }
  }
  const converter = new TurndownService({headingStyle: 'atx', codeBlockStyle: 'fenced',
    bulletListMarker: '-', emDelimiter: '*', strongDelimiter: '**', hr: '---'});
  converter.use(gfm);
  converter.addRule('dieterDiagramSource', {
    filter: node => node.nodeName === 'PRE' && node.hasAttribute('data-dieter-source'),
    replacement: (_content, node) => '\n\n' + node.getAttribute('data-dieter-source') + '\n\n',
  });
  converter.addRule('doubleStrikethrough', {filter: ['del', 's', 'strike'], replacement: content => `~~${content}~~`});
  const value = converter.turndown(container);
  return value || null;
}
