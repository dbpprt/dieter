# getdieter.com

The marketing site and documentation for **Dieter** — coding agents across all
your machines, behind one interface. Built with [Hugo](https://gohugo.io)
(extended) and a fully custom, light theme.

> This lives in the repo for now. It will move to a GitHub Pages deployment at
> `getdieter.com` later (domain not yet purchased).

## Develop

```sh
cd getdieter.com
hugo server            # http://localhost:1313
```

Requires Hugo **extended** ≥ 0.164.

## Build

```sh
hugo --minify          # outputs to ./public
```

## Structure

```
getdieter.com/
├── hugo.toml                 # config, params (brew commands, GitHub, OG)
├── content/
│   ├── _index.md             # home metadata
│   └── docs/                 # documentation (Overview · Guides · Reference)
├── layouts/
│   ├── index.html            # landing page (all sections)
│   ├── 404.html
│   ├── _default/             # baseof · single · list (docs shell)
│   ├── partials/             # head · nav · footer · icon · codeblock · docs-*
│   └── shortcodes/           # callout
├── assets/
│   ├── css/main.css          # the design system (Arctic Console)
│   ├── css/_chroma.css       # syntax highlighting (themed)
│   └── js/main.js            # nav, copy, reveal, TOC spy, install terminal
├── data/landing.yaml         # harness cards
└── static/
    ├── brand/                # logos + favicon (copied from assets/brand)
    ├── fonts/                # Sora variable
    └── images/gen/           # codex-generated ambient art
```

## Design system

Light, flat, and professional — no gradients. Monochrome ink on white:

- **Palette** — white `#FFFFFF` / `#F7F7F8` surfaces, near-black `#17171A` ink,
  gray `#5F5F67` secondary, hairline `#E7E7EA` borders. The one dark element is
  the hero terminal. Semantic `amber`/`coral` appear only in status dots.
- **Syntax** — light (`github`) chroma theme.
- **Type** — Sora (display), Inter (body), JetBrains Mono (mono).
- **Signature element** — the animated install terminal in the hero replays the
  real `brew install` → `dieter setup` flow (`assets/js/main.js`).

Ambient art in `static/images/gen/` was generated with the Codex CLI's
`image_gen` tool and matches the palette.

## Deploy to GitHub Pages (later)

A ready workflow lives in [`deploy/github-pages.yml`](deploy/github-pages.yml).
When the domain is live:

1. Move the site to the repo root (or set `deploy/` `working-directory`).
2. Copy `deploy/github-pages.yml` to `.github/workflows/`.
3. Add a `static/CNAME` file containing `getdieter.com`.
4. Point the DNS `A`/`CNAME` records at GitHub Pages and enable Pages → Actions.
