import assert from 'node:assert/strict';
import test from 'node:test';
import {JSDOM} from 'jsdom';
import {createOfflineLoader, createRenderer, parseChart} from '../src/renderer.js';

function fixture(overrides = {}) {
  const {window} = new JSDOM('<main id="preview"></main>');
  const document = window.document;
  const root = document.querySelector('main');
  const renderer = createRenderer({document, root,
    renderMermaid: async () => '<svg><text>Diagram</text></svg>',
    renderChart: async () => ({view: {}, finalize() {}}),
    ...overrides,
  });
  return {window, document, root, renderer};
}

const fence = (kind, source) => '```' + kind + '\n' + source + '\n```\n';
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
};

test('Markdown preserves tables, fenced code and links while escaping executable HTML and image URLs', async () => {
  const {renderer, root} = fixture();
  await renderer.render('# Heading\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n[Docs](https://example.com)\n\n![Local image](file:///etc/passwd)\n\n![Remote](https://example.com/pixel)\n\n<script>window.evil = true</script>\n\n[Bad](javascript:alert(1))\n\n' + fence('js', '<script>evil()</script>'));
  assert.equal(root.querySelector('h1').textContent, 'Heading');
  assert.equal(root.querySelectorAll('td').length, 2);
  assert.equal(root.querySelector('a').href, 'https://example.com/');
  assert.equal(root.querySelectorAll('script,img,iframe').length, 0);
  assert.equal(root.querySelector('code.language-js').textContent, '<script>evil()</script>\n');
  assert.equal(root.querySelector('a[href^="javascript:"]'), null);
  assert.equal(root.dataset.renderState, 'ready');
});

test('mixed diagrams isolate JSON and Mermaid errors and normalize fence aliases', async () => {
  const calls = [];
  const {renderer, root} = fixture({
    renderMermaid: async ({source}) => {
      if (source.includes('broken')) throw new Error('<img src=x onerror=evil()>');
      return '<svg><text>Good</text></svg>';
    },
    renderChart: async ({kind, element}) => {
      calls.push(kind);
      element.innerHTML = '<svg><text>Chart</text></svg>';
      return {view: {}, finalize() {}};
    },
  });
  const result = await renderer.render(fence('mermaid', 'graph TD; A-->B') + fence('vegalite', '{}') + fence('vega', 'oops') + fence('mermaid', 'broken') + '\nStill visible');
  assert.deepEqual(calls, ['vega-lite']);
  assert.equal(result.renderedBlocks, 2);
  assert.equal(result.failedBlocks, 2);
  assert.equal(root.querySelectorAll('[data-state="rendered"] svg').length, 2);
  assert.equal(root.querySelectorAll('[data-state="error"]').length, 2);
  assert.equal(root.querySelector('img'), null);
  assert.match(root.textContent, /Still visible/);
});

test('chart input cannot override trusted embed options, read URLs or exploit object keys', async () => {
  assert.deepEqual(parseChart('{"usermeta":{"embedOptions":{"ast":false,"actions":true}},"data":{"values":[{"x":1}]}}'), {data: {values: [{x: 1}]}});
  assert.deepEqual(parseChart('{"data":{"values":[{"url":"https://example.com","href":"plain text"}]}}'), {data: {values: [{url: 'https://example.com', href: 'plain text'}]}});
  for (const source of ['"https://example.com/spec.json"', '[]', 'null', '{"data":{"url":"file:///etc/passwd"}}', '{"marks":[{"encode":{"enter":{"href":{"value":"https://example.com"}}}}]}', '{"__proto__":{"polluted":true}}']) {
    assert.throws(() => parseChart(source));
  }
  const loader = createOfflineLoader();
  for (const method of ['load', 'sanitize', 'http', 'file']) {
    for (const url of ['https://example.com/data', 'file:///etc/passwd', 'data:text/plain,secret', 'dieter-markdown://preview/app.js']) {
      await assert.rejects(loader[method](url), /External resources are disabled/);
    }
  }
});

test('Mermaid insertion independently removes active SVG content and external references', async () => {
  const {renderer, root} = fixture({renderMermaid: async () => '<svg onload="evil()"><script>evil()</script><foreignObject><div>HTML</div></foreignObject><image href="https://example.com/image"/><a href="javascript:evil()"><text onclick="evil()">Safe</text></a><use href="#shape"/></svg>'});
  await renderer.render(fence('mermaid', 'graph TD; A-->B'));
  assert.equal(root.querySelector('script,foreignObject,image,[onload],[onclick],[href^="javascript:"]'), null);
  assert.equal(root.querySelector('use').getAttribute('href'), '#shape');
});

test('a slow previous Mermaid render cannot overwrite a newer document or readiness', async () => {
  const first = deferred();
  let started;
  const start = new Promise(resolve => { started = resolve; });
  const {renderer, root} = fixture({renderMermaid: async () => { started(); return first.promise; }});
  const previous = renderer.render(fence('mermaid', 'old'));
  await start;
  const latest = await renderer.render('# Latest unsaved edit', 'dark');
  first.resolve('<svg><text>Old</text></svg>');
  assert.equal((await previous).stale, true);
  assert.equal(latest.stale, false);
  assert.equal(root.textContent.trim(), 'Latest unsaved edit');
  assert.equal(root.dataset.renderState, 'ready');
  assert.equal(root.ownerDocument.documentElement.dataset.theme, 'dark');
});

test('replacement and disposal finalize both pending and completed charts', async () => {
  const pending = deferred();
  let pendingFinalizations = 0;
  let completedFinalizations = 0;
  const pendingView = {finalize() { pendingFinalizations++; }};
  let started;
  const start = new Promise(resolve => { started = resolve; });
  let calls = 0;
  const {renderer, root} = fixture({renderChart: async ({onView}) => {
    if (++calls === 1) {
      onView(pendingView);
      started();
      return pending.promise;
    }
    return {view: {}, finalize() { completedFinalizations++; }};
  }});
  const old = renderer.render(fence('vega-lite', '{}'));
  await start;
  await renderer.render(fence('vega-lite', '{}'));
  assert.equal(pendingFinalizations, 1);
  pending.resolve({view: pendingView, finalize: () => pendingView.finalize()});
  assert.equal((await old).stale, true);
  assert.equal(pendingFinalizations, 2);
  renderer.dispose();
  assert.equal(completedFinalizations, 1);
  assert.equal(root.dataset.renderState, 'disposed');
  assert.equal(root.childElementCount, 0);
});

test('large inline-data charts have a separate bounded limit from Mermaid source', async () => {
  const calls = [];
  const {renderer, root} = fixture({renderChart: async ({spec}) => {
    calls.push(spec.data.values.length);
    return {view: {}, finalize() {}};
  }});
  const values = Array.from({length: 1200}, (_, index) => ({index, note: 'Sample '.repeat(14)}));
  const chart = JSON.stringify({data: {values}, mark: 'point'});
  assert.ok(chart.length > 100_000 && chart.length < 1_000_000);
  const valid = await renderer.render(fence('vega-lite', chart));
  assert.equal(valid.renderedBlocks, 1);
  assert.equal(valid.failedBlocks, 0);
  assert.deepEqual(calls, [1200]);
  const oversized = JSON.stringify({data: {values: [{note: 'é'.repeat(510_000)}]}});
  assert.ok(oversized.length < 1_000_000, 'The chart limit accounts for UTF-8 bytes');
  const invalid = await renderer.render(fence('vega', oversized) + fence('mermaid', 'A'.repeat(100_001)) + '\nOther content remains visible');
  assert.equal(invalid.renderedBlocks, 0);
  assert.equal(invalid.failedBlocks, 2);
  assert.match(root.textContent, /Chart source exceeds the 1 MB limit/);
  assert.match(root.textContent, /Mermaid source exceeds the 100,000 character limit/);
  assert.match(root.textContent, /Other content remains visible/);
  assert.deepEqual(calls, [1200], 'Oversized input never reaches a chart renderer');
  renderer.dispose();
});
