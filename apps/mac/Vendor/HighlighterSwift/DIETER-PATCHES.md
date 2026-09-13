# Dieter integration patches

Vendored from smittytone/HighlighterSwift 3.1.0 at commit
`fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0`.
Upstream: https://github.com/smittytone/HighlighterSwift/tree/3.1.0
License: MIT (see LICENCE.md).

Dieter adds `Highlighter.init(bundle:)` so the signed macOS app can load the
SwiftPM resource bundle from `Contents/Resources`. The upstream generated
`Bundle.module` accessor only searches the app-bundle root and the original
absolute build path, then traps when neither exists in a distributed app.
