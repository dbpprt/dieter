import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {JSDOM} from 'jsdom';

const resources = new URL('../../Sources/DieterMac/Resources/MarkdownPreview/', import.meta.url);
const fence = (kind, source) => '```' + kind + '\n' + source + '\n```\n';
async function waitFor(window, predicate, message) {
  const deadline = Date.now() + 1000;
  while (!predicate() && Date.now() < deadline) {
    await new Promise(resolve => window.setTimeout(resolve, 5));
  }
  assert.ok(predicate(), message);
}

test('offline shell forbids inline scripts, evaluation and resource requests', async () => {
  const html = await readFile(new URL('index.html', resources), 'utf8');
  const {window} = new JSDOM(html);
  const document = window.document;
  assert.deepEqual([...document.scripts].map(script => script.getAttribute('src')), ['app.js']);
  assert.equal(document.scripts[0].textContent, '');
  const csp = document.querySelector('meta[http-equiv="Content-Security-Policy"]').content;
  assert.match(csp, /script-src 'self';/);
  assert.doesNotMatch(csp, /unsafe-eval/);
  for (const directive of ['connect-src', 'img-src', 'font-src', 'media-src', 'frame-src', 'worker-src', 'object-src']) {
    assert.ok(csp.includes(`${directive} 'none'`));
  }
  window.close();
});

test('the real bundled Mermaid and Vega render SVGs with dynamic Function and I/O disabled', {timeout: 30_000}, async () => {
  const html = await readFile(new URL('index.html', resources), 'utf8');
  const bundle = await readFile(new URL('app.js', resources), 'utf8');
  const {window} = new JSDOM(html, {runScripts: 'outside-only', pretendToBeVisual: true, url: 'https://preview.invalid/'});
  let networkAttempts = 0;
  const noNetwork = () => { networkAttempts++; throw new Error('Unexpected resource request'); };
  window.fetch = noNetwork;
  window.XMLHttpRequest = noNetwork;
  window.WebSocket = noNetwork;
  window.structuredClone = structuredClone;
  window.TextEncoder = TextEncoder;
  window.Function = function() { throw new Error('Dynamic JavaScript evaluation is disabled'); };
  // jsdom has no layout engine or canvas implementation. Supply only text
  // measurements; rendering and parsing still use the production libraries.
  window.HTMLCanvasElement.prototype.getContext = () => ({measureText: text => ({width: String(text).length * 7})});
  window.SVGElement.prototype.getBBox = function() { return {x: 0, y: 0, width: Math.max(40, this.textContent.length * 7), height: 24}; };
  window.SVGElement.prototype.getComputedTextLength = function() { return this.textContent.length * 7; };
  window.eval(bundle);
  try {
    const source = '# Live preview\n\n' +
      fence('mermaid', '%%{init: {"securityLevel":"loose","flowchart":{"htmlLabels":true}}}%%\nflowchart LR\n  A[Source] --> B[Preview]') +
      fence('vega-lite', JSON.stringify({data: {values: [{category: 'A', count: 2}, {category: 'B', count: 4}]}, params: [{name: 'minimum', value: 3, bind: {input: 'range', min: 0, max: 5, step: 1}}], transform: [{filter: 'datum.count >= minimum'}], mark: 'bar', encoding: {x: {field: 'category', type: 'nominal'}, y: {field: 'count', type: 'quantitative'}}})) +
      fence('vega', JSON.stringify({width: 100, height: 40, data: [{name: 'points', values: [{x: 10}, {x: 30}]}], marks: [{type: 'symbol', from: {data: 'points'}, encode: {enter: {x: {field: 'x'}, y: {value: 20}, size: {value: 50}}}}]})) +
      fence('mermaid', 'this is not a diagram') +
      fence('vega-lite', '{broken JSON') +
      fence('vega-lite', JSON.stringify({data: {url: 'https://example.com/private'}, mark: 'bar'}));
    const result = await window.dieterMarkdown.render(source, 'light');
    const root = window.document.querySelector('#preview');
    assert.equal(result.renderedBlocks, 3, root.textContent);
    assert.equal(result.failedBlocks, 3, root.textContent);
    assert.equal(root.querySelectorAll('[data-state="rendered"] svg').length, 3);
    const diagram = root.querySelector('[data-kind="mermaid"][data-state="rendered"]');
    assert.match(diagram.textContent, /Source/);
    assert.match(diagram.textContent, /Preview/);
    assert.equal(diagram.querySelector('foreignObject'), null);
    const chart = root.querySelector('[data-kind="vega-lite"][data-state="rendered"]');
    assert.equal(chart.querySelectorAll('g.mark-rect.role-mark path').length, 1);
    const input = chart.querySelector('input[type="range"]');
    assert.ok(input, 'The parameter is bound to a native HTML range input');
    input.value = '1';
    input.dispatchEvent(new window.Event('input', {bubbles: true}));
    await waitFor(window, () => chart.querySelectorAll('g.mark-rect.role-mark path').length === 2, 'The interpreter updates the chart after a parameter change');
    assert.equal(root.dataset.renderState, 'ready');
    assert.equal(networkAttempts, 0);
    await window.dieterMarkdown.render('# Latest unsaved text', 'dark');
    assert.equal(root.textContent.trim(), 'Latest unsaved text');
    assert.equal(window.document.documentElement.dataset.theme, 'dark');
    window.dieterMarkdown.dispose();
    assert.equal(root.childElementCount, 0);
  } finally {
    window.close();
  }
});

test('all bundled charts fit shrinking panes while reflowing numeric widths and preserving source semantics', {timeout: 30_000}, async () => {
  const html = await readFile(new URL('index.html', resources), 'utf8');
  const bundle = await readFile(new URL('app.js', resources), 'utf8');
  const {window} = new JSDOM(html, {runScripts: 'outside-only', pretendToBeVisual: true, url: 'https://preview.invalid/'});
  window.structuredClone = structuredClone;
  window.TextEncoder = TextEncoder;
  window.Function = function() { throw new Error('Dynamic JavaScript evaluation is disabled'); };
  window.HTMLCanvasElement.prototype.getContext = () => ({measureText: text => ({width: String(text).length * 7})});
  let paneWidth = 640;
  Object.defineProperty(window.HTMLElement.prototype, 'clientWidth', {get() { return this.classList.contains('chart-container') ? paneWidth : 0; }});
  const observers = [];
  window.ResizeObserver = class {
    constructor(callback) { this.callback = callback; this.disconnected = false; observers.push(this); }
    observe(element) { this.element = element; }
    disconnect() { this.disconnected = true; }
  };
  window.eval(bundle);
  const unit = {data: {values: [{category: 'A', count: 2}, {category: 'B', count: 4}]}, mark: 'bar', encoding: {x: {field: 'category', type: 'nominal'}, y: {field: 'count', type: 'quantitative'}}};
  const root = window.document.querySelector('#preview');
  const render = async (spec, kind = 'vega-lite') => {
    const result = await window.dieterMarkdown.render(fence(kind, JSON.stringify(spec)));
    assert.equal(result.renderedBlocks, 1, root.textContent);
    assert.equal(result.failedBlocks, 0, root.textContent);
    return root.querySelector('svg');
  };
  const shownWidth = svg => parseFloat(svg.style.width);
  const chartObservers = () => observers.filter(observer => observer.element.classList.contains('chart-container'));
  const resize = async (svg, width) => {
    paneWidth = width;
    observers.at(-1).callback();
    await waitFor(window, () => shownWidth(svg) <= width, 'The complete SVG fits the changed pane');
  };
  try {
    const svg = await render(unit);
    assert.equal(shownWidth(svg), 640);
    assert.ok(Number(svg.getAttribute('height')) >= 260 && Number(svg.getAttribute('height')) < 330);
    assert.equal(chartObservers().length, 1);
    assert.equal(observers.filter(observer => observer.element === root).length, 1, 'Document scroll preservation has its own observer');
    paneWidth = 820; chartObservers()[0].callback();
    await waitFor(window, () => shownWidth(svg) === 820, 'The SVG follows the changed pane width');
    const fixed = await render({...unit, width: 360, height: 180});
    assert.equal(chartObservers()[0].disconnected, true);
    assert.equal(chartObservers().length, 2, 'Numeric widths now observe and reflow with their pane');
    assert.ok(shownWidth(fixed) <= 360, 'Small authored charts are not stretched');
    assert.match(fixed.querySelector('g.role-frame > g > path.background').getAttribute('d'), /v180/);
    await resize(fixed, 240);
    assert.equal(Number(fixed.getAttribute('width')), 240, 'Numeric width is a preview-only maximum');
    const stepped = await render({...unit, width: {step: 80}, height: 120});
    assert.match(stepped.querySelector('g.role-frame > g > path.background').getAttribute('d'), /h160v120/);
    const intrinsicStepWidth = Number(stepped.getAttribute('width'));
    await resize(stepped, 100);
    assert.ok(Math.abs(shownWidth(stepped) - 100) < 0.001);
    assert.equal(Number(stepped.getAttribute('width')), intrinsicStepWidth, 'Step geometry stays intrinsic while the complete SVG scales');
    paneWidth = 820; observers.at(-1).callback();
    await waitFor(window, () => shownWidth(stepped) > 100, 'Step SVG grows back to its intrinsic size');
    assert.ok(shownWidth(stepped) < 300, 'Step SVG is never stretched to fill a wide pane');
    const configured = await render({...unit, config: {view: {discreteWidth: {step: 80}, continuousHeight: 120}}});
    assert.match(configured.querySelector('g.role-frame > g > path.background').getAttribute('d'), /h160v120/);
    const composition = await render({hconcat: [unit, unit]});
    assert.ok(Number(composition.getAttribute('width')) < 400, 'Composition keeps its category-based child widths');
    assert.ok(Number(composition.getAttribute('height')) >= 300, 'Composition keeps its own child height');
    await resize(composition, 100);
    assert.ok(Math.abs(shownWidth(composition) - 100) < 0.001);
    const raw = await render({width: 720, height: 200, marks: [{type: 'rect', encode: {enter: {x: {value: 0}, y: {value: 0}, width: {value: 720}, height: {value: 200}, fill: {value: 'steelblue'}}}}]}, 'vega');
    assert.ok(shownWidth(raw) <= 100);
    assert.ok(Number(raw.getAttribute('width')) >= 720);
    paneWidth = 800;
    const title = 'All terms in this deliberately long confidence interval comparison title remain visible';
    const subtitle = 'This explanatory subtitle is substantially longer than the narrow preview pane and must never be clipped';
    const authored = {width: 720, height: 280, background: 'white', title: {text: title, subtitle}, config: {title: {anchor: 'start', fontSize: 16, subtitleFontSize: 12}},
      data: {values: [{group: 'A', estimate: 0.8, upper: 0.95}, {group: 'B', estimate: 0.65, upper: 0.9}]},
      encoding: {y: {field: 'group', type: 'nominal'}}, layer: [
        {mark: 'bar', encoding: {x: {field: 'estimate', type: 'quantitative'}}},
        {mark: 'rule', encoding: {x: {field: 'estimate', type: 'quantitative'}, x2: {field: 'upper'}}},
        {mark: {type: 'text', align: 'left', dx: 6}, encoding: {x: {field: 'upper', type: 'quantitative'}, text: {field: 'estimate'}}},
      ]};
    const original = JSON.stringify(authored);
    const layered = await render(authored);
    const plotWidth = () => Number(layered.querySelector('g.role-frame > g > path.background').getAttribute('d').match(/h([\d.]+)/)[1]);
    assert.ok(plotWidth() > 200);
    const widePlot = plotWidth();
    await resize(layered, 260);
    assert.ok(plotWidth() > 40 && plotWidth() < widePlot, 'Fixed-width layered bars, rules and labels reflow in a narrow pane');
    assert.ok(shownWidth(layered) <= 260);
    assert.match(layered.querySelector('g.role-frame > g > path.background').getAttribute('d'), /v280/);
    const titleWords = [...layered.querySelectorAll('.role-title-text tspan')].map(node => node.textContent).join(' ');
    const subtitleWords = [...layered.querySelectorAll('.role-title-subtitle tspan')].map(node => node.textContent).join(' ');
    assert.equal(titleWords, title);
    assert.equal(subtitleWords, subtitle);
    assert.equal(layered.style.backgroundColor, 'white');
    paneWidth = 800; observers.at(-1).callback();
    await waitFor(window, () => plotWidth() > 200, 'The layered plot expands again');
    assert.ok(shownWidth(layered) <= 720, 'Authored width remains a maximum on expansion');
    assert.equal(JSON.stringify(authored), original, 'Preview layout never rewrites the authored specification');
    const records = Array.from({length: 1000}, (_, index) => ({x: index, y: index % 10, description: 'Synthetic inline record with sufficient text to exceed the former chart limit. '.repeat(2)}));
    const large = {data: {values: records}, mark: 'point', encoding: {x: {field: 'x', type: 'quantitative'}, y: {field: 'y', type: 'quantitative'}}};
    assert.ok(JSON.stringify(large).length > 100_000);
    await render(large);
    window.dieterMarkdown.dispose();
    assert.ok(observers.every(observer => observer.disconnected));
  } finally {
    window.close();
  }
});

test('bundled native-source preview returns safe selected and full clipboard payloads', {timeout: 30_000}, async () => {
  const html = await readFile(new URL('index.html', resources), 'utf8');
  const bundle = await readFile(new URL('app.js', resources), 'utf8');
  const {window} = new JSDOM(html, {runScripts: 'outside-only', pretendToBeVisual: true, url: 'https://preview.invalid/'});
  window.Function = function() { throw new Error('Dynamic JavaScript evaluation is disabled'); };
  window.structuredClone = structuredClone;
  window.TextEncoder = TextEncoder;
  window.HTMLCanvasElement.prototype.getContext = () => ({measureText: text => ({width: String(text).length * 7})});
  const messages = [];
  window.webkit = {messageHandlers: {markdown: {postMessage: payload => messages.push(payload)}}};
  window.eval(bundle);
  try {
    const source = '# Report\n\n**File A** and other text.\n';
    const result = await window.dieterMarkdown.render(source, 'light', true, 4);
    assert.equal(result.stale, false);
    const root = window.document.querySelector('#preview');
    assert.equal(root.dataset.mode, 'preview');
    assert.equal(root.dataset.renderState, 'ready');
    assert.equal(root.querySelector('[contenteditable], .ProseMirror, .rich-toolbar'), null);
    assert.equal(messages.length, 0, 'The preview never sends edit callbacks');
    const range = window.document.createRange();
    range.selectNodeContents(root.querySelector('strong'));
    window.getSelection().removeAllRanges();
    window.getSelection().addRange(range);
    root.querySelector('strong').dispatchEvent(new window.MouseEvent('contextmenu', {bubbles: true, cancelable: true}));
    assert.equal(messages.at(-1).type, 'contextMenu');
    assert.equal(messages.at(-1).markdown, '**File A**');
    assert.match(messages.at(-1).html, /<strong>File A<\/strong>/);
    assert.equal(messages.at(-1).text, 'File A');
    window.getSelection().removeAllRanges();
    const edited = source + '\nUpdated in the native editor.\n';
    await window.dieterMarkdown.render(edited, 'dark', false, 5);
    root.dispatchEvent(new window.MouseEvent('contextmenu', {bubbles: true, cancelable: true}));
    assert.equal(messages.at(-1).markdown, edited);
    assert.match(messages.at(-1).text, /Updated in the native editor/);
    assert.equal(messages.every(message => message.type === 'contextMenu'), true);
    const scrolling = window.document.documentElement;
    Object.defineProperty(scrolling, 'scrollHeight', {get: () => 2000});
    Object.defineProperty(scrolling, 'clientHeight', {get: () => 400});
    const position = window.dieterMarkdown.setScrollProgress(0.4, 'native-bundle-check');
    assert.equal(position.applied, true);
    assert.equal(scrolling.scrollTop, 640);
    window.dispatchEvent(new window.Event('scroll'));
    await new Promise(resolve => window.requestAnimationFrame(resolve));
    assert.equal(messages.some(message => message.type === 'scroll'), false, 'Peer scroll must not echo');
    window.document.dispatchEvent(new window.WheelEvent('wheel'));
    scrolling.scrollTop = 800;
    window.dispatchEvent(new window.Event('scroll'));
    await new Promise(resolve => window.requestAnimationFrame(resolve));
    assert.equal(messages.at(-1).type, 'scroll');
    assert.equal(messages.at(-1).progress, 0.5);
    await window.dieterMarkdown.dispose();
    assert.equal(root.childElementCount, 0);
  } finally { window.close(); }
});

test('bundled diagram-only API renders complete SVGs without page padding and keeps errors editable', {timeout: 30_000}, async () => {
  const html = await readFile(new URL('index.html', resources), 'utf8');
  const bundle = await readFile(new URL('app.js', resources), 'utf8');
  const css = await readFile(new URL('app.css', resources), 'utf8');
  const {window} = new JSDOM(html, {runScripts: 'outside-only', pretendToBeVisual: true, url: 'https://preview.invalid/'});
  // jsdom does not fetch the linked stylesheet. Install the exact bundled CSS
  // to verify layout rules instead of relying on browser-default styles.
  const style = window.document.createElement('style');
  style.textContent = css; window.document.head.append(style);
  window.Function = function() { throw new Error('Dynamic JavaScript evaluation is disabled'); };
  window.structuredClone = structuredClone;
  window.TextEncoder = TextEncoder;
  window.fetch = () => { throw new Error('Unexpected network request'); };
  window.HTMLCanvasElement.prototype.getContext = () => ({measureText: text => ({width: String(text).length * 7})});
  window.SVGElement.prototype.getBBox = function() { return {x: 0, y: 0, width: Math.max(40, this.textContent.length * 7), height: 24}; };
  window.SVGElement.prototype.getComputedTextLength = function() { return this.textContent.length * 7; };
  Object.defineProperty(window.HTMLElement.prototype, 'clientWidth', {get() { return 480; }});
  const messages = [];
  window.webkit = {messageHandlers: {markdown: {postMessage: payload => messages.push(payload)}}};
  window.eval(bundle);
  const root = window.document.querySelector('#preview');
  root.getBoundingClientRect = () => ({width: 480, height: root.querySelector('svg') ? 260 : 64});
  try {
    let result = await window.dieterMarkdown.renderDiagram('mermaid', 'flowchart LR\nA[Source] --> B[Preview]', 'light', 'flow');
    assert.equal(result.renderedBlocks, 1, root.textContent);
    assert.equal(result.failedBlocks, 0);
    assert.equal(result.width, 480);
    assert.equal(result.height, 260);
    assert.equal(root.querySelectorAll('.diagram').length, 1);
    assert.equal(root.querySelectorAll('svg').length, 1);
    assert.equal(root.querySelector('foreignObject'), null);
    assert.equal(parseFloat(window.getComputedStyle(root).paddingTop), 0);
    assert.equal(window.getComputedStyle(root).maxWidth, 'none');
    assert.equal(parseFloat(window.getComputedStyle(root.querySelector('.diagram')).borderTopWidth), 0);
    assert.equal(root.getAttribute('role'), 'button');
    root.dispatchEvent(new window.KeyboardEvent('keydown', {key: 'Enter'}));
    assert.equal(messages.at(-1).type, 'diagramActivate');
    assert.equal(messages.at(-1).blockID, 'flow');
    const chart = {width: 720, height: 180, data: {values: [{x: 'A', y: 2}, {x: 'B', y: 4}]}, mark: 'bar', encoding: {x: {field: 'x', type: 'nominal'}, y: {field: 'y', type: 'quantitative'}}};
    result = await window.dieterMarkdown.renderDiagram('vegalite', JSON.stringify(chart), 'dark', 'chart');
    assert.equal(result.renderedBlocks, 1, root.textContent);
    assert.ok(parseFloat(root.querySelector('svg').style.width) <= 480);
    assert.equal(root.querySelectorAll('.diagram').length, 1, 'Next block replaces the previous snapshot surface');
    result = await window.dieterMarkdown.renderDiagram('vega-lite', '{invalid JSON', 'light', 'broken');
    assert.equal(result.failedBlocks, 1);
    assert.equal(typeof result.error, 'string');
    assert.equal(root.querySelector('[data-state="error"]') !== null, true);
    root.click();
    assert.equal(messages.at(-1).type, 'diagramActivate');
    assert.equal(messages.at(-1).blockID, 'broken');
    result = await window.dieterMarkdown.renderDiagram('mermaid', 'x'.repeat(100_001), 'light', 'too-large');
    assert.equal(result.failedBlocks, 1);
    assert.match(root.textContent, /100,000 character limit/);
    await window.dieterMarkdown.render('# Document again', 'light');
    assert.equal(root.dataset.mode, 'preview');
    assert.equal(root.hasAttribute('role'), false);
    assert.ok(parseFloat(window.getComputedStyle(root).paddingTop) > 0);
    assert.equal(messages.every(message => ['diagramSize', 'diagramActivate'].includes(message.type)), true);
    await window.dieterMarkdown.dispose();
    assert.equal(root.childElementCount, 0);
  } finally { window.close(); }
});
