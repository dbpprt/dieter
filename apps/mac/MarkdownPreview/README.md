# Offline Markdown preview

The checked-in resources in `../Sources/DieterMac/Resources/MarkdownPreview`
are loaded by the native Files preview through `dieter-markdown://preview/`.
They require no server or network connection. Rebuild after editing this source:

```sh
npm ci --ignore-scripts
npm test
npm run build
npm run check
```

All dependency versions and the complete dependency graph are pinned. The
`lodash-es` override supplies the patched release for Mermaid's Chevrotain
dependency. The build records every production dependency's complete license
and notice files in `LICENSES.txt`. Normal Swift builds use the checked-in files
and do not install JavaScript dependencies.

`window.dieterMarkdown.render(source, theme, editing = false, revision = 0)`
returns a promise with
`{generation, stale, renderedBlocks, failedBlocks}`. Pass `light` or `dark` as
the theme. The compatibility `editing` and `revision` arguments are ignored;
editing belongs to the native SwiftMarkdownEngine surface. `dispose()` invalidates
pending work and finalizes chart views.
The root is `main#preview`, with `data-render-state` set to `idle`, `rendering`,
`ready`, or `disposed`. Diagram wrappers have `data-kind` (`mermaid`,
`vega-lite`, or `vega`) and `data-state` (`rendering`, `rendered`, or `error`).
`vegalite` fences are normalized to `vega-lite`.

`setScrollProgress(progress, token)` applies a normalized vertical position and
returns `{applied, progress, token?}`. Finite numbers clamp to 0…1; invalid values
return `{applied: false}`. The optional token is a string of at most 128 characters.
User scrolling emits `{type: 'scroll', progress}` to the native `markdown` handler.
Peer scroll updates and render/resize position restoration emit no scroll messages,
preventing feedback loops between the Split panes. Native code gates synchronization
to the visible Split view. Disposal removes scroll listeners and observers.

`renderDiagram(kind, source, theme, blockID)` renders one Mermaid, Vega-Lite
(`vegalite` is accepted), or Vega block on a transparent surface with no page
padding or border. The existing render result also includes measured `width`,
`height`, and `error` (a bounded message for failed blocks, otherwise `null`);
the promise resolves after SVG rendering and keeps content mounted for
a native snapshot. Identical source/theme/block/viewport-width requests reuse
the finished render. The normal per-block limits and offline security rules apply.
The bounded block ID (at most 128 characters) is echoed in
`{type: 'diagramSize', blockID, height}` when completed content changes height,
and `{type: 'diagramActivate', blockID}` on click or Enter/Space. Failed diagrams
remain activatable so the native editor can always open their source. Ordinary
`render(...)` restores document preview behavior; disposal removes these handlers.

Markdown files open in native Edit mode. The source editor is created on first
use and suspends highlighting and layout while hidden. The full WebKit document
preview is mounted only in Split and Preview modes; the retained rich editor
pauses diagram work while hidden without losing its buffer or undo history.
Inline diagram images share a 24 MiB cache. Under bitmap pressure, backing
resolution is reduced while display size and all admitted previews are retained,
so completion notifications cannot cause render/eviction loops. A document can
admit up to 48 unique diagrams, with source strings also bounded by the cache
budget. Closing the document cancels its queued work and releases the renderer.

The shell loads only the bundled `app.js` and `app.css`; its CSP allows neither
inline scripts nor dynamic JavaScript evaluation. Inline styles are permitted
for generated SVG and chart layout. Source HTML is escaped. Images display alt
text. Mermaid uses strict security and no click callbacks. Chart specifications
must be JSON objects with inline data; resource/link URLs are rejected, embedded
host options are removed, and the loader rejects every network/file operation.
Vega expressions use its AST interpreter. Chart bindings and SVG charts remain
interactive. Native navigation policy is responsible for opening Markdown
links in the user's browser.

Single and layered Vega-Lite charts reflow to the available preview width. An
authored numeric width remains a maximum, and explicit heights are retained;
otherwise the default plot height is 260px. Titles and subtitles wrap without
losing text. Step, composed, faceted and raw Vega charts retain their layout and
scale down as a complete figure, including labels and legends. Small charts are
never stretched. All charts observe their container width when the native Files
pane resizes. The stored Markdown and JSON specification remain unchanged.

Chart JSON is limited to 1 MB of UTF-8; Mermaid retains a 100,000-character limit.
Oversized or invalid blocks show a local error while other content still renders.

Upstream API references:

- [markdown-it](https://github.com/markdown-it/markdown-it)
- [Mermaid usage and strict security](https://mermaid.js.org/config/usage.html)
- [Vega expression interpreter](https://vega.github.io/vega/usage/interpreter/)
- [Vega Embed options](https://github.com/vega/vega-embed)


The native right-click menu receives a snapshot `{type: 'contextMenu', markdown,
html, text}`. It copies the selection, or the entire source when nothing is
selected. Turndown with its GFM plugin converts rendered selections to Markdown.
Rich HTML is rebuilt from semantic, allowlisted elements with no active content,
styles, images or resource loads. Diagram selections copy their complete source
fences; rich text presents these as code. Rendered SVG internals never enter the
clipboard.

- [Turndown](https://github.com/mixmark-io/turndown)
