import assert from 'node:assert/strict';
import test from 'node:test';
import {JSDOM} from 'jsdom';
import {createMarkdownDocument} from '../src/document-controller.js';

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise, resolve};
}

function fixture() {
  const {window} = new JSDOM('<main></main><aside>Outside</aside>');
  const document = window.document;
  const root = document.querySelector('main');
  const messages = [];
  const calls = [];
  let disposals = 0;
  const controller = createMarkdownDocument({document, root, postMessage: value => messages.push(value),
    preview: {
      async render(source, theme) {
        calls.push({source, theme});
        const paragraph = document.createElement('p'); paragraph.textContent = source;
        root.replaceChildren(paragraph); root.dataset.renderState = 'ready';
        return {generation: calls.length, renderedBlocks: 2, failedBlocks: 1};
      },
      dispose() { disposals++; root.replaceChildren(); },
    },
  });
  function contextMenu(target = root) {
    const event = new window.MouseEvent('contextmenu', {bubbles: true, cancelable: true});
    target.dispatchEvent(event);
    return event;
  }
  return {window, document, root, messages, calls, controller, contextMenu, disposals: () => disposals,
    async close() { await controller.dispose(); window.close(); }};
}

test('native editing compatibility arguments only render preview, preserving result fields', async () => {
  const state = fixture();
  try {
    const result = await state.controller.render('Original source', 'dark', true, 12);
    assert.deepEqual(result, {generation: 1, renderedBlocks: 2, failedBlocks: 1, stale: false});
    assert.equal(state.root.dataset.mode, 'preview');
    assert.equal(state.document.documentElement.dataset.theme, 'dark');
    assert.equal(state.root.querySelector('[contenteditable]'), null);
    assert.deepEqual(state.messages, [], 'Rendering never sends native edit callbacks');
    await state.controller.render('Latest native edit', 'invalid', false, 13);
    assert.deepEqual(state.calls.at(-1), {source: 'Latest native edit', theme: 'light'});
    state.contextMenu();
    assert.equal(state.messages.at(-1).markdown, 'Latest native edit');
  } finally { await state.close(); }
});

test('context menus send selected or complete Markdown with static rich HTML and readable text', async () => {
  const state = fixture();
  const {controller, document, root, messages, contextMenu} = state;
  try {
    assert.equal(contextMenu().defaultPrevented, false, 'No document has been applied');
    await controller.render('# Report\n\n**Full body**', 'light', false, 1);
    assert.equal(contextMenu().defaultPrevented, true);
    assert.deepEqual(Object.keys(messages[0]).sort(), ['html', 'markdown', 'text', 'type']);
    assert.equal(messages[0].type, 'contextMenu');
    assert.equal(messages[0].markdown, '# Report\n\n**Full body**');
    assert.match(messages[0].html, /<h1>Report<\/h1>/);
    assert.match(messages[0].html, /<strong>Full body<\/strong>/);
    assert.equal(messages[0].text, 'Report\n\nFull body');
    root.innerHTML = '<p>Before <strong>selected words</strong> after</p>';
    const selected = root.querySelector('strong').firstChild;
    const range = document.createRange();
    range.setStart(selected, 0); range.setEnd(selected, 8);
    document.defaultView.getSelection().addRange(range);
    contextMenu(selected.parentElement);
    assert.equal(messages.at(-1).markdown, '**selected**');
    assert.equal(messages.at(-1).text, 'selected');
    assert.match(messages.at(-1).html, /<strong>selected<\/strong>/);
    const count = messages.length;
    assert.equal(contextMenu(document.querySelector('aside')).defaultPrevented, false);
    assert.equal(messages.length, count);
  } finally { await state.close(); }
});

test('disposal removes clipboard events and rejects future renders exactly once', async () => {
  const state = fixture();
  try {
    await state.controller.render('Source');
    await state.controller.dispose();
    await state.controller.dispose();
    assert.equal(state.disposals(), 1);
    assert.equal(state.root.dataset.mode, 'disposed');
    assert.equal(state.root.childElementCount, 0);
    assert.equal(state.contextMenu().defaultPrevented, false);
    assert.deepEqual(state.messages, []);
    assert.equal((await state.controller.render('Ignored')).stale, true);
    assert.equal(state.calls.length, 1);
  } finally { await state.close(); }
});

test('newer preview and disposal invalidate a pending slow diagram without waiting for it', async () => {
  const {window} = new JSDOM('<main></main>');
  const root = window.document.querySelector('main');
  const slow = deferred();
  const calls = [];
  let disposals = 0;
  const controller = createMarkdownDocument({document: window.document, root, postMessage() {},
    preview: {
      async render(source) {
        calls.push(source);
        if (source === 'Slow') await slow.promise;
        return {renderedBlocks: 0, failedBlocks: 0};
      }, dispose() { disposals++; },
    },
  });
  try {
    const old = controller.render('Slow');
    const latest = await controller.render('Latest');
    assert.deepEqual(calls, ['Slow', 'Latest']);
    assert.equal(latest.stale, false);
    await controller.dispose();
    assert.equal(disposals, 1);
    slow.resolve();
    assert.equal((await old).stale, true);
    assert.equal(root.dataset.mode, 'disposed');
  } finally { slow.resolve(); await controller.dispose(); window.close(); }
});
