import assert from 'node:assert/strict';
import test from 'node:test';
import {JSDOM} from 'jsdom';
import MarkdownIt from 'markdown-it';
import {createDiagramSurface, diagramMarkdown} from '../src/diagram-surface.js';
import {createMarkdownDocument} from '../src/document-controller.js';

test('diagram-only fences cannot inject Markdown or extra diagrams and preserve their source body', () => {
  const source = 'flowchart LR\nA --> B\n```\n# Injected Markdown\n````mermaid\nC --> D\n';
  const {kind, markdown} = diagramMarkdown(' Mermaid ', source);
  assert.equal(kind, 'mermaid');
  const tokens = new MarkdownIt().parse(markdown, {});
  assert.equal(tokens.length, 1);
  assert.equal(tokens[0].type, 'fence');
  assert.equal(tokens[0].content, source);
  assert.equal(diagramMarkdown('vegalite', '{}').kind, 'vega-lite');
  assert.throws(() => diagramMarkdown('html', '<script>bad()</script>'), /Unsupported/);
});

test('inline diagram sizing is ready-only, deduplicated and immune to superseded/disposed callbacks', () => {
  const {window} = new JSDOM('<main><div>Diagram</div></main>');
  const root = window.document.querySelector('main');
  let height = 180.2;
  root.getBoundingClientRect = () => ({width: 420, height});
  const messages = [];
  let observer;
  window.ResizeObserver = class {
    constructor(callback) { this.callback = callback; observer = this; }
    observe() { this.connected = true; }
    disconnect() { this.connected = false; }
  };
  const surface = createDiagramSurface({document: window.document, root, postMessage: message => messages.push(message)});
  try {
    const first = {blockID: 'first', kind: 'mermaid'};
    const latest = {blockID: 'latest', kind: 'vega-lite'};
    surface.prepare(first); observer.callback();
    assert.deepEqual(messages, []);
    surface.prepare(latest);
    surface.rendered(first);
    assert.deepEqual(messages, []);
    surface.rendered(latest); observer.callback();
    assert.deepEqual(messages, [{type: 'diagramSize', blockID: 'latest', height: 181}]);
    height = 260; observer.callback();
    assert.deepEqual(messages.at(-1), {type: 'diagramSize', blockID: 'latest', height: 260});
    assert.equal(root.firstElementChild.hasAttribute('inert'), true);
    surface.clear(); height = 300; observer.callback();
    assert.equal(messages.length, 2);
    assert.equal(root.hasAttribute('role'), false);
    surface.prepare(first); surface.dispose(); surface.rendered(first); observer.callback();
    assert.equal(messages.length, 2);
    assert.equal(observer.connected, false);
  } finally { surface.dispose(); window.close(); }
});

test('diagram activation supports mouse and keyboard, including failed/loading diagrams, and stops outside diagram mode', () => {
  const {window} = new JSDOM('<main><p>Invalid diagram source</p></main>');
  const root = window.document.querySelector('main');
  const messages = [];
  const surface = createDiagramSurface({document: window.document, root, postMessage: message => messages.push(message)});
  try {
    surface.prepare({blockID: 'error-block', kind: 'mermaid'});
    assert.equal(root.tabIndex, 0);
    assert.equal(root.getAttribute('role'), 'button');
    assert.match(root.getAttribute('aria-label'), /Activate to edit source/);
    root.dispatchEvent(new window.MouseEvent('click', {bubbles: true, button: 0}));
    root.dispatchEvent(new window.KeyboardEvent('keydown', {key: 'Enter'}));
    root.dispatchEvent(new window.KeyboardEvent('keydown', {key: ' '}));
    root.dispatchEvent(new window.KeyboardEvent('keydown', {key: 'ArrowDown'}));
    root.dispatchEvent(new window.KeyboardEvent('keydown', {key: 'Enter', repeat: true}));
    assert.deepEqual(messages, Array(3).fill({type: 'diagramActivate', blockID: 'error-block'}));
    surface.clear(); root.click();
    assert.equal(messages.length, 3);
    surface.dispose(); root.click();
    assert.equal(messages.length, 3);
  } finally { surface.dispose(); window.close(); }
});

test('diagram controller awaits rendering, caches unchanged requests and restores ordinary preview behavior', async () => {
  const {window} = new JSDOM('<main></main>');
  const root = window.document.querySelector('main');
  root.getBoundingClientRect = () => ({width: 420, height: 180});
  let width = 420;
  Object.defineProperty(window.document.documentElement, 'clientWidth', {get: () => width});
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const calls = [];
  const messages = [];
  const controller = createMarkdownDocument({document: window.document, root, postMessage: message => messages.push(message),
    preview: {
      async render(source) {
        calls.push(source); root.innerHTML = '<div class="diagram">Rendered</div>';
        await gate;
        return {generation: calls.length, renderedBlocks: 1, failedBlocks: 0};
      }, dispose() { root.replaceChildren(); },
    },
  });
  try {
    const pending = controller.renderDiagram('mermaid', 'flowchart LR\nA --> B', 'light', 'block-1');
    assert.equal(messages.length, 0);
    release();
    const result = await pending;
    assert.equal(result.height, 180); assert.equal(result.width, 420);
    assert.equal(result.stale, false);
    assert.equal(messages.at(-1).type, 'diagramSize');
    await controller.renderDiagram('mermaid', 'flowchart LR\nA --> B', 'light', 'block-1');
    assert.equal(calls.length, 1);
    width = 320;
    await controller.renderDiagram('mermaid', 'flowchart LR\nA --> B', 'light', 'block-1');
    assert.equal(calls.length, 2, 'A different snapshot width waits for a fresh layout');
    await controller.render('# Ordinary Markdown', 'dark');
    assert.equal(root.dataset.mode, 'preview');
    assert.equal(root.hasAttribute('role'), false);
    assert.equal(window.document.documentElement.dataset.surface, undefined);
    const count = messages.length;
    root.click(); assert.equal(messages.length, count);
  } finally { release(); await controller.dispose(); window.close(); }
});
