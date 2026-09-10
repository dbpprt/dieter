import assert from 'node:assert/strict';
import test from 'node:test';
import {JSDOM} from 'jsdom';
import {fitChartSVG, observeChartWidth, prepareChartTitles, previewChartSizing} from '../src/chart-sizing.js';

const size = spec => previewChartSizing(spec, 'vega-lite');

test('single and layered numeric widths reflow within their authored maximum without mutating source', () => {
  assert.deepEqual(size({mark: 'bar'}), {spec: {mark: 'bar', width: 'container', height: 260, autosize: {type: 'fit-x', contains: 'padding'}}, responsiveWidth: true, maximumWidth: Infinity});
  const original = {mark: 'bar', width: 420, height: {step: 40}};
  const sized = previewChartSizing(original, 'vega-lite', 300);
  assert.equal(sized.spec.width, 300);
  assert.deepEqual(sized.spec.height, {step: 40});
  assert.equal(sized.maximumWidth, 420);
  assert.equal(original.width, 420);
  assert.equal(previewChartSizing(original, 'vega-lite', 800).spec.width, 420);
  const layer = {layer: [{mark: 'bar', width: 420}, {mark: 'text'}]};
  assert.equal(size(layer).spec.layer[0].width, undefined);
  assert.equal(layer.layer[0].width, 420);
  assert.equal(size(layer).spec.height, 260);
  assert.equal(size({layer: [{mark: 'bar', height: {step: 25}}]}).spec.height, undefined);
  const configured = {mark: 'bar', config: {view: {discreteWidth: {step: 80}, continuousHeight: 120}}};
  assert.deepEqual(size(configured), {spec: configured, responsiveWidth: false, maximumWidth: Infinity});
});

test('explicit and implicit compositions keep their authored layout', () => {
  for (const spec of [
    {hconcat: [{mark: 'bar'}, {mark: 'point'}]},
    {vconcat: [{mark: 'bar'}]},
    {concat: [{mark: 'bar'}]},
    {facet: {field: 'group'}, spec: {mark: 'bar'}},
    {repeat: ['a', 'b'], spec: {mark: 'bar'}},
    ...['row', 'column', 'facet'].map(key => ({mark: 'bar', encoding: {[key]: {field: 'group'}}})),
    {layer: [{mark: 'bar', encoding: {column: {field: 'group'}}}]},
  ]) {
    assert.deepEqual(size(spec), {spec, responsiveWidth: false, maximumWidth: Infinity});
  }
  const vega = {marks: []};
  assert.deepEqual(previewChartSizing(vega, 'vega'), {spec: vega, responsiveWidth: false, maximumWidth: Infinity});
});

test('plain title/subtitle rewrap through private signals while expressions and authored source stay intact', () => {
  const {window} = new JSDOM('');
  window.HTMLCanvasElement.prototype.getContext = () => ({measureText: value => ({width: value.length * 7})});
  const original = {mark: 'bar', title: {text: 'Every word of this long title must remain visible', subtitle: ['First subtitle line', 'Second subtitle line'], anchor: 'start'},
    params: [{name: '__dieter_preview_title_0', value: 4}], config: {title: {fontSize: 16}}, background: 'white'};
  const before = JSON.stringify(original);
  const prepared = prepareChartTitles(window.document, original, 200);
  assert.equal(JSON.stringify(original), before);
  assert.equal(prepared.spec.background, 'white');
  assert.equal(prepared.spec.title.anchor, 'start');
  assert.equal(prepared.spec.params[0].name, '__dieter_preview_title_0');
  assert.notEqual(prepared.spec.title.text.expr, '__dieter_preview_title_0');
  assert.equal(prepared.spec.params[1].value.join(' '), original.title.text);
  assert.equal(prepared.spec.params[2].value.join(' '), original.title.subtitle.join(' '));
  const changes = [];
  prepared.update({signal(name, value) { changes.push({name, value}); }}, 100);
  assert.ok(changes[0].value.length > prepared.spec.params[1].value.length);
  assert.equal(changes[0].value.join(' '), original.title.text);
  const expression = {mark: 'bar', title: {text: {expr: 'authoredTitle'}, fontSize: 18}};
  assert.deepEqual(prepareChartTitles(window.document, expression, 200).spec.title, expression.title);
  window.close();
});

test('full SVG bounds down-fit without clipping or accumulating scale, and never stretch small charts', () => {
  const {window} = new JSDOM('<div><svg width="720" height="300" viewBox="0 0 720 300"></svg></div>');
  const element = window.document.querySelector('div');
  let available = 300;
  Object.defineProperty(element, 'clientWidth', {get: () => available});
  const svg = element.querySelector('svg');
  const view = {scenegraph: () => ({root: {bounds: {x1: -50, y1: -40, x2: 760, y2: 330}}}), origin: () => [10, 20], padding: () => ({left: 5, top: 5})};
  fitChartSVG(element, view);
  const [x, y, width, height] = svg.getAttribute('viewBox').split(' ').map(Number);
  assert.ok(x <= -35 && y <= -15 && x + width >= 775 && y + height >= 355);
  assert.equal(parseFloat(svg.style.width), 300);
  assert.equal(parseFloat(svg.style.height), height * 300 / width);
  available = 1000;
  fitChartSVG(element, view);
  assert.equal(parseFloat(svg.style.width), width);
  assert.equal(parseFloat(svg.style.height), height);
  available = 200;
  fitChartSVG(element, view);
  assert.equal(parseFloat(svg.style.width), 200);
  assert.equal(svg.getAttribute('width'), '720');
  assert.equal(svg.getAttribute('height'), '300');
  window.close();
});

function observerFixture({runAsync = async () => {}, initialWidth, responsiveWidth = true, maximumWidth = Infinity} = {}) {
  const element = {clientWidth: 600};
  const widths = [];
  let callback;
  let disconnected = 0;
  let current = true;
  const errors = [];
  const view = {width(width) { widths.push(width); return this; }, resize() { return this; }, runAsync};
  class Observer {
    constructor(handler) { callback = handler; }
    observe(target) { assert.equal(target, element); }
    disconnect() { disconnected++; }
  }
  const stop = observeChartWidth({element, view, initialWidth, responsiveWidth, maximumWidth, isCurrent: () => current, onError: error => errors.push(error), ResizeObserver: Observer});
  return {element, widths, errors, stop, trigger: () => callback(), stale: () => { current = false; }, disconnected: () => disconnected};
}

test('observer ignores height-only changes and coalesces width changes without overlapping updates', async () => {
  let finish;
  const pending = new Promise(resolve => { finish = resolve; });
  let calls = 0;
  const fixture = observerFixture({runAsync: () => ++calls === 1 ? pending : Promise.resolve()});
  fixture.trigger();
  assert.deepEqual(fixture.widths, []);
  fixture.element.clientWidth = 700;
  fixture.trigger();
  fixture.element.clientWidth = 710;
  fixture.trigger();
  fixture.element.clientWidth = 750;
  fixture.trigger();
  assert.deepEqual(fixture.widths, [700]);
  finish();
  await pending;
  await Promise.resolve();
  assert.deepEqual(fixture.widths, [700, 750]);
  fixture.trigger();
  assert.deepEqual(fixture.widths, [700, 750]);
  fixture.stop();
  fixture.stop();
  fixture.element.clientWidth = 800;
  fixture.trigger();
  assert.equal(fixture.disconnected(), 1);
  assert.deepEqual(fixture.widths, [700, 750]);
});

test('observer reconciles a pane width that changed during the initial chart render', () => {
  const fixture = observerFixture({initialWidth: 500});
  assert.deepEqual(fixture.widths, [600]);
  fixture.stop();
});

test('observer respects authored maxima and down-fit-only charts do not rewrite Vega dimensions', async () => {
  const capped = observerFixture({maximumWidth: 720});
  capped.element.clientWidth = 900;
  capped.trigger();
  assert.deepEqual(capped.widths, [720]);
  capped.stop();
  const fixed = observerFixture({responsiveWidth: false});
  fixed.element.clientWidth = 200;
  fixed.trigger();
  await Promise.resolve();
  assert.deepEqual(fixed.widths, []);
  fixed.stop();
  assert.equal(fixed.disconnected(), 1);
});

test('observer disconnects on stale views or failed resize updates', async () => {
  const stale = observerFixture();
  stale.stale();
  stale.element.clientWidth = 700;
  stale.trigger();
  assert.equal(stale.disconnected(), 1);
  assert.deepEqual(stale.widths, []);
  const failure = observerFixture({runAsync: async () => { throw new Error('Resize failed'); }});
  failure.element.clientWidth = 700;
  failure.trigger();
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(failure.disconnected(), 1);
  assert.equal(failure.errors[0].message, 'Resize failed');
});
