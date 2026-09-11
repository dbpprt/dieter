# Dieter integration patches

Vendored from nodes-app/swift-markdown-engine tag 0.12.0.
Upstream: https://github.com/nodes-app/swift-markdown-engine/tree/0.12.0
License: Apache-2.0 (see LICENSE).

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

Code-block overlay tokens are cleared and reseeded when rebuilding a document.
Resize callbacks defer selection work during that rebuild, and stale token
ranges are rejected before text-storage access. Switching from diagrams to a
shorter document therefore cannot index the new text with the old fence ranges.
