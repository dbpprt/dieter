# getdieter.com

The marketing site and documentation for **Dieter** — coding agents across all
your machines, behind one interface. Built with [Hugo](https://gohugo.io)
(extended) and a fully custom, light theme.

> This lives in the repo for now. It will move to a GitHub Pages deployment at
> `getdieter.com` later (domain not yet purchased).

## Develop

```sh
cd landingpage
hugo server            # http://localhost:1313
```

Requires Hugo **extended** ≥ 0.164.

## Build

```sh
hugo --minify          # outputs to ./public
```

## Structure

```
landingpage/
├── hugo.toml                 # config, params (brew commands, GitHub, OG)
├── content/
│   ├── _index.md             # home metadata
│   └── docs/                 # documentation (Overview · Guides · Reference)
├── layouts/
│   ├── index.html            # landing page (all sections)
│   ├── 404.html
│   ├── robots.txt
│   ├── _default/             # baseof · single · list · _markup/render-link
│   ├── partials/             # head · nav · footer · icon · codeblock · docs-*
│   └── shortcodes/           # callout
├── assets/
│   ├── css/main.css          # the design system (light, flat)
│   ├── css/_chroma.css       # syntax highlighting (github, light)
│   └── js/main.js            # nav, copy, reveal, TOC spy, install terminal
├── data/landing.yaml         # harness cards
└── static/
    ├── brand/                # logos + favicon (copied from assets/brand)
    ├── fonts/                # Sora variable
    └── images/               # og-image, app icon
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

Every URL is baseURL-relative (`relURL` / a link render hook), so the site runs
unchanged at a subpath or a domain root.

## Deploy — GitHub Pages

Deployment is automatic. [`.github/workflows/pages.yml`](../.github/workflows/pages.yml)
builds this directory and publishes it on every push to `main` that touches
`landingpage/**`. The base URL comes from the Pages configuration, so nothing
here is hard-coded to a host.

- **Now:** served at the project-pages URL, `https://dbpprt.github.io/dieter/`.
- **Later (getdieter.com):** buy the domain, add a `getdieter.com` file to
  `static/`, set it as the custom domain under **Settings → Pages**, and point
  DNS at GitHub Pages. The workflow picks up the new base URL automatically — no
  code change.

One-time setup: **Settings → Pages → Build and deployment → Source: GitHub Actions.**
