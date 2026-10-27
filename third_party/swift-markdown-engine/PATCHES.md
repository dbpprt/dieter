# Dieter patches

Vendored from nodes-app/swift-markdown-engine tag 0.14.0.
Upstream: https://github.com/nodes-app/swift-markdown-engine/tree/0.14.0
License: Apache-2.0 (see `LICENSE`).

Used by `apps/apple/mac` as a local package; it depends on the sibling
`../HighlighterSwift`. The repository marks it `linguist-vendored` and does not
reformat it (`.gitattributes`); the Mac's native Markdown integration tests
cover the patches.

## Patches

Dieter adds an optional rendered fenced-code service. The native editor keeps
the original Markdown in text storage, displays cached diagram images for
inactive blocks, and reveals source on native mouse or keyboard interaction.
Provider notifications and width changes refresh presentation without editing
the document or registering undo operations.

Attributed formatting replacements use NSTextView's native insertion path so
formatting and code-block wrapping participate correctly in undo and redo.

Collapsed diagrams skip syntax highlighting and use a bounded number of attribute
ranges regardless of source line count. Completed images and width changes update
only existing diagram anchors, avoiding whole-document restyling and preserving
unrelated presentation, source text, and undo history.

When a rendered diagram changes height, wide-table overlays are repositioned
against their settled TextKit anchors in the same update. Reconciliation reuses
the existing table anchors and images, without scanning or restyling the source,
and preserves horizontal scroll offsets. This prevents tables after asynchronous
charts from remaining over earlier content. `NativeRenderedCodeBlockTests`
covers growth and shrinkage with repeated tables and reading-column layouts.

If an asynchronous renderer withdraws a placeholder and opts into source fallback, refresh
restyles only that fence to reveal readable source. Other image anchors and
unrelated prose keep their existing presentation; the source and undo history
are unchanged. `NativeRenderedCodeBlockTests` covers this failure transition.
Temporary unavailability keeps the previous image by default, including while
a retained editor is hidden.

Code-block overlay tokens are cleared and reseeded when rebuilding a document.
Resize callbacks defer selection work during that rebuild, and stale token
ranges are rejected before text-storage access. Switching from diagrams to a
shorter document therefore cannot index the new text with the old fence ranges.

An optional URL-click callback lets Dieter open linked workspace files and web
pages in the conversation panel. Native edit zones, wiki-link resolution and
Command-click retain their existing behavior; other embedders keep AppKit's
default URL handling.
The styled link also retains its original Markdown destination, so the optional
callback receives relative paths and fragments before external-browser URL
normalization. Native workspace resolution therefore uses the document's path.

On 0.14.0, rendered-code resizing runs alongside the upstream table-only width
refresh so diagram widths still update without restyling unrelated paragraphs.

Links inside GFM table cells draw as their label, in the theme's link colour
and underlined, instead of as raw `[label](url)` source. Each rendered table
image (`RenderedTableImage`, kept by the table image cache) records where its
cell links were drawn. A plain click on one, in an inline table or a wide-table
overlay, goes where a body link goes: the embedder's URL callback with the
original destination (relative paths and fragments intact), else the system
for a URL with a scheme. Read-only views show the pointing hand over them.

A non-editable view is a read-only presentation: besides the existing caret
and selection suppression, a click on a wide table no longer moves the caret
or first responder into the table's source; it only follows links. Tests
check that a caret or selection inside a table, heading, emphasis or link of a
read-only view keeps the table rendered and the markers hidden.

Rendered tables are images, so in read-only views their context menu (inline
tables through the coordinator's menu hook, wide tables through the overlay)
starts with "Copy Table as Markdown" (the table's source) and "Copy Table as
TSV" (the visible cell text, tab separated), followed by the embedder's menu.
`DieterTableInteractionTests` covers these patches.
