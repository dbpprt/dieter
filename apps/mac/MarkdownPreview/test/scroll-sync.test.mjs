import assert from 'node:assert/strict';
import test from 'node:test';
import {JSDOM} from 'jsdom';
import {createPreviewScroll} from '../src/scroll-sync.js';

function fixture() {
  const {window} = new JSDOM('<main></main>');
  const document = window.document;
  const root = document.querySelector('main');
  const element = document.documentElement;
  let height = 1400;
  let viewport = 400;
  let nextFrame = 0;
  const frames = new Map();
  const messages = [];
  const observers = [];
  Object.defineProperty(element, 'scrollHeight', {get: () => height});
  Object.defineProperty(element, 'clientHeight', {get: () => viewport});
  window.requestAnimationFrame = callback => { frames.set(++nextFrame, callback); return nextFrame; };
  window.cancelAnimationFrame = id => frames.delete(id);
  window.ResizeObserver = class {
    constructor(callback) { this.callback = callback; this.disconnected = false; observers.push(this); }
    observe() {}
    disconnect() { this.disconnected = true; }
  };
  const sync = createPreviewScroll({document, root, postMessage: message => messages.push(message)});
  function flush() { for (const [id, callback] of [...frames]) { frames.delete(id); callback(); } }
  function scroll(top, input = true) {
    if (input) document.dispatchEvent(new window.WheelEvent('wheel'));
    element.scrollTop = top;
    window.dispatchEvent(new window.Event('scroll'));
  }
  return {window, document, element, sync, messages, frames, observers, flush, scroll,
    resize(nextHeight, nextViewport = viewport) { height = nextHeight; viewport = nextViewport; observers[0].callback(); },
    replaceHeight(value) { height = value; },
    close() { sync.dispose(); window.close(); }};
}

test('peer updates clamp progress, reject invalid input, and never echo coalesced scroll events', () => {
  const state = fixture();
  try {
    assert.deepEqual(state.sync.setScrollProgress(0.25, 'native-1'), {applied: true, progress: 0.25, token: 'native-1'});
    assert.equal(state.element.scrollTop, 250);
    state.scroll(250, false);
    state.sync.setScrollProgress(0.75, 'native-2');
    state.scroll(750, false);
    state.flush();
    assert.deepEqual(state.messages, []);
    assert.equal(state.sync.setScrollProgress(4).progress, 1);
    assert.equal(state.element.scrollTop, 1000);
    assert.equal(state.sync.setScrollProgress(-1).progress, 0);
    for (const invalid of [NaN, Infinity, -Infinity, '0.5', null]) {
      assert.deepEqual(state.sync.setScrollProgress(invalid), {applied: false});
    }
    assert.equal(state.element.scrollTop, 0);
  } finally { state.close(); }
});

test('user scrolling interrupts peer positioning and publishes one normalized update per frame', () => {
  const state = fixture();
  try {
    state.sync.setScrollProgress(0.25);
    state.scroll(400);
    state.scroll(600);
    assert.equal(state.frames.size, 2, 'One scroll publication plus the bounded input-intent expiry');
    state.flush();
    assert.deepEqual(state.messages, [{type: 'scroll', progress: 0.6}]);
    state.scroll(600, false); state.flush();
    assert.equal(state.messages.length, 1, 'Duplicate native scroll notifications are ignored');
    // Scrollbar/keyboard scrolling still works without a wheel event.
    state.scroll(800, false); state.flush();
    assert.deepEqual(state.messages.at(-1), {type: 'scroll', progress: 0.8});
  } finally { state.close(); }
});

test('rendering and pane/diagram resizing preserve progress without rebroadcasting reflow', () => {
  const state = fixture();
  try {
    state.scroll(400); state.flush();
    state.sync.prepareForRender();
    state.replaceHeight(2400);
    state.element.scrollTop = 0; // Browser clamp/anchor while replacing nodes.
    state.sync.preservePosition();
    assert.equal(state.element.scrollTop, 800);
    state.scroll(800, false); state.flush();
    state.resize(3400, 600);
    assert.equal(state.element.scrollTop, 1120);
    state.scroll(1120, false); state.flush();
    assert.deepEqual(state.messages, [{type: 'scroll', progress: 0.4}]);
    state.resize(200, 600);
    assert.equal(state.element.scrollTop, 0);
    state.resize(1400, 400);
    assert.equal(state.element.scrollTop, 400, 'A temporarily short render retains its intended position');
  } finally { state.close(); }
});

test('a reflow scroll arriving before ResizeObserver restores the prior fraction silently', () => {
  const state = fixture();
  try {
    state.sync.setScrollProgress(0.5);
    state.replaceHeight(2400);
    state.scroll(700, false); state.flush();
    assert.equal(state.element.scrollTop, 1000);
    assert.deepEqual(state.messages, []);
  } finally { state.close(); }
});

test('a user gesture wins over a simultaneous diagram resize', () => {
  const state = fixture();
  try {
    state.sync.setScrollProgress(0.4);
    state.scroll(600);
    state.resize(2400);
    assert.equal(state.element.scrollTop, 600);
    assert.deepEqual(state.messages, [{type: 'scroll', progress: 0.3}]);
    state.flush();
    assert.equal(state.messages.length, 1);
  } finally { state.close(); }
});

test('clicks and expired non-scrolling input do not turn later viewport clamps into user scrolling', () => {
  for (const input of ['pointerdown', 'wheel', 'keydown']) {
    const state = fixture();
    try {
      state.sync.setScrollProgress(0.9);
      const event = input === 'keydown'
        ? new state.window.KeyboardEvent('keydown', {key: 'ArrowDown'})
        : new state.window.Event(input);
      state.document.dispatchEvent(event);
      if (input !== 'pointerdown') { state.flush(); state.flush(); }
      // A resized viewport clamps the old offset before ResizeObserver runs.
      state.element.scrollTop = 400;
      state.resize(800, 400);
      state.scroll(state.element.scrollTop, false); state.flush();
      assert.equal(state.element.scrollTop, 360, input);
      assert.deepEqual(state.messages, [], input);
    } finally { state.close(); }
  }
});

test('disposal cancels pending work, observers and future bridge updates', () => {
  const state = fixture();
  try {
    state.scroll(400);
    assert.equal(state.frames.size, 2);
    state.sync.dispose();
    assert.equal(state.frames.size, 0);
    assert.equal(state.observers[0].disconnected, true);
    state.scroll(600); state.flush();
    state.resize(2400);
    assert.deepEqual(state.messages, []);
    assert.deepEqual(state.sync.setScrollProgress(0.75), {applied: false});
  } finally { state.close(); }
});
