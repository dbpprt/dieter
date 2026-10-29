# Dieter — Arctic Console asset pack

**Palette 06: Arctic Console**
Quiet, credible, and enterprise-ready; intentionally restrained.

This is a complete color variation of the Dieter v3 **Conductor Mask** identity. The geometry, one calm face, three command panes, and Sora wordmark are identical across every palette pack.

## Core colors

| Role              | Value     |
| ----------------- | --------- |
| Dark field        | `#0D1B24` |
| Raised dark       | `#193A49` |
| Shell start       | `#8DD8E8` |
| Shell end         | `#3D6E85` |
| Pane start        | `#D7F2F5` |
| Pane end          | `#62B6CB` |
| Eye/status accent | `#BCEAF1` |
| Light field       | `#F5FBFD` |

## Contents

- `brand-guide.html` — responsive light/dark palette guide
- `palette-preview.png` — visual overview
- `theme.css`, `tokens.json` — implementation tokens
- `assets/svg/` — color, compact, monochrome, app, favicon, tray, wordmark, and lockup vectors
- `assets/png/` — app icons from 16–1024 px, marks, lockups, wordmarks, and tray exports
- `assets/favicon.ico` — website favicon
- `assets/social/og-image.*` — 1200×630 sharing artwork
- `assets/fonts/` — Sora variable font and SIL Open Font License

Use the detailed mark at 48 px and above. Use `mark-small.svg` or the favicon assets below 48 px. Keep exactly three panes and do not add facial features beyond the two status-eye bars.

## Consumers

This directory is the single source. Products reference it instead of keeping
their own copies:

- The website (`site/hugo.toml`) mounts the font, favicons, and the 512 px app
  icon from here.
- The Android launcher icon is regenerated from `assets/svg/mark-mono-light.svg`
  by `apps/kotlin/android/scripts/sync-brand-assets.sh`.
- The Mac app bundle embeds `assets/fonts/Sora-Variable.ttf`. Compose resources
  must live inside their module, so `apps/kotlin/ui` keeps a byte-identical copy
  of the font and its licence.
- The repository README shows the horizontal logo.

App icons use the Monochrome palette and live with each app
(`apps/apple/mac/Resources`, `apps/apple/ios/App/Assets.xcassets`,
`apps/kotlin/android/src/main/res`). `go test ./tools/brandcheck` verifies the
source files, the copies, and this wiring.

The Dieter name and logo are not covered by the code's MIT license; see
[TRADEMARKS.md](../../TRADEMARKS.md).
