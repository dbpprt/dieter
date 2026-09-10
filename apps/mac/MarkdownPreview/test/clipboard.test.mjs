import assert from 'node:assert/strict';
import test from 'node:test';
import {JSDOM} from 'jsdom';
import {buildClipboardPayload, sanitizeClipboardHTML, selectionMarkdown} from '../src/clipboard.js';

function fixture(html = '') {
  const {window} = new JSDOM('<main id="preview">' + html + '</main><aside>Outside</aside>');
  const document = window.document;
  const root = document.querySelector('main');
  function select(start, startOffset, end = start, endOffset = start.textContent.length) {
    const range = document.createRange();
    range.setStart(start, startOffset);
    range.setEnd(end, endOffset);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }
  return {window, document, root, select};
}

test('clipboard HTML retains semantic formatting while removing active content and unsafe links', () => {
  const {document} = fixture();
  const html = sanitizeClipboardHTML(document, '<h2 id="target" onclick="evil()">Heading</h2><p style="background:url(https://example.com/track)"><b>Bold</b> <i>Italic</i> <s>Deleted</s></p><a href="https://example.com/docs" ping="https://example.com/track" target="_blank">Safe</a><a href="java&#x73;cript:alert(1)">Bad</a><a href="file:///etc/passwd">Local</a><a href="data:text/html,bad">Data</a><a href="//example.com">Relative</a><script>evil()</script><style>@import "https://example.com";</style><iframe src="https://example.com">frame</iframe><svg><foreignObject><p>SVG body</p></foreignObject></svg><img src="https://example.com/image" alt="Image description"><input type="checkbox" checked onclick="evil()"><input type="text" value="secret"><button>Preview UI</button><!--comment-->');
  const output = document.createElement('div');
  output.innerHTML = html;
  assert.equal(output.querySelectorAll('script,style,iframe,svg,foreignObject,img,input,button').length, 0);
  assert.equal(output.querySelectorAll('[style],[onclick],[id],[ping],[target]').length, 0);
  assert.deepEqual([...output.querySelectorAll('a[href]')].map(link => link.href), ['https://example.com/docs']);
  assert.equal(output.querySelector('strong').textContent, 'Bold');
  assert.equal(output.querySelector('em').textContent, 'Italic');
  assert.equal(output.querySelector('del').textContent, 'Deleted');
  assert.match(output.textContent, /Image description\[x\]/);
  assert.doesNotMatch(output.textContent, /evil|SVG body|secret|Preview UI/);
});

test('payload includes rich tables, text-only tasks and source code for diagram fences', () => {
  const {document} = fixture();
  const source = '# Report\n\n**Strong** and *emphasis*\n\n| Name | Value |\n| --- | --- |\n| A | 2 |\n\n- [x] Done\n- [ ] Pending\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\n```vega-lite\n{"mark":"bar","data":{"values":[]}}\n```\n';
  const payload = buildClipboardPayload({document, markdown: source});
  assert.equal(payload.type, 'contextMenu');
  assert.equal(payload.markdown, source);
  const output = document.createElement('div');
  output.innerHTML = payload.html;
  assert.equal(output.querySelector('h1').textContent, 'Report');
  assert.equal(output.querySelectorAll('td').length, 2);
  assert.equal(output.querySelectorAll('input,svg').length, 0);
  assert.equal(output.querySelector('code.language-mermaid').textContent, 'flowchart LR\n  A --> B\n');
  assert.match(output.querySelector('code.language-vega-lite').textContent, /"mark":"bar"/);
  assert.match(payload.text, /Strong and emphasis/);
  assert.match(payload.text, /Name\tValue/);
  assert.match(payload.text, /- \[x\] Done/);
  assert.match(payload.text, /flowchart LR\n  A --> B/);
  assert.doesNotMatch(payload.text, /<table>|\*\*Strong\*\*|Show source/);
});

test('source HTML is escaped and image URLs never enter the rich payload', () => {
  const {document} = fixture();
  const source = '<script>alert(1)</script>\n\n![Remote](https://example.com/image)\n\n[Bad](javascript:alert(1))';
  const payload = buildClipboardPayload({document, markdown: source});
  const output = document.createElement('div');
  output.innerHTML = payload.html;
  assert.equal(output.querySelector('script,img,a'), null);
  assert.match(output.textContent, /<script>alert\(1\)<\/script>/);
  assert.match(output.textContent, /Remote/);
  assert.doesNotMatch(payload.html, /https:\/\/example.com\/image/);
});

test('preview selection preserves formatting for a substring inside inline ancestors', () => {
  const {document, root, select} = fixture('<p>Before <strong><em>selected words</em></strong> after.</p>');
  const text = root.querySelector('em').firstChild;
  select(text, 0, text, 8);
  assert.equal(selectionMarkdown({document, root, source: 'Full document'}), '***selected***');
});

test('partial selections of a diagram copy its entire original fence without SVG or controls', () => {
  const {document, root, select} = fixture('<p>Before</p><div class="diagram"><svg><text>Diagram label</text></svg><details><summary>Show source</summary></details></div><p>After</p>');
  const diagram = root.querySelector('.diagram');
  const source = '```mermaid\nflowchart LR\n  A --> B\n```';
  diagram.dataset.source = source;
  const text = diagram.querySelector('text').firstChild;
  select(text, 2, text, 7);
  assert.equal(selectionMarkdown({document, root, source: 'Full document'}), source);
  select(root.querySelector('p').firstChild, 2, text, 7);
  const value = selectionMarkdown({document, root, source: 'Full document'});
  assert.match(value, /^fore/);
  assert.ok(value.includes(source));
  assert.doesNotMatch(value, /Diagram label|Show source|<svg/);
});

test('table selections produce GFM and missing or outside selections allow full-source fallback', () => {
  const {window, document, root, select} = fixture('<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>');
  assert.equal(selectionMarkdown({document, root, source: 'Full source'}), null);
  select(document.querySelector('aside').firstChild, 0);
  assert.equal(selectionMarkdown({document, root, source: 'Full source'}), null);
  const table = root.querySelector('table');
  select(table, 0, table, table.childNodes.length);
  assert.match(selectionMarkdown({document, root}), /\| A \| B \|\n\| --- \| --- \|\n\| 1 \| 2 \|/);
  const body = root.querySelector('tbody');
  select(body, 0, body, body.childNodes.length);
  assert.match(selectionMarkdown({document, root}), /\| 1 \| 2 \|/);
  select(root, 0, root, root.childNodes.length);
  assert.equal(selectionMarkdown({document, root, source: '# Original formatting\n\n'}), '# Original formatting\n\n');
  window.getSelection().removeAllRanges();
});
