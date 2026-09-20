# getdieter.com

The marketing site and documentation for **Dieter** — coding agents across all
your machines, behind one interface. Built with [Hugo](https://gohugo.io)
(extended) and a fully custom, light theme.

The GitHub Pages workflow is named **Deploy getdieter.com**. The configured
public URL is currently `https://dbpprt.github.io/dieter/`; `getdieter.com` is
not yet configured as its custom domain.

## Develop

```sh
just site serve        # http://localhost:1313
```

Requires Hugo **extended** ≥ 0.164.

## Build

```sh
just site build        # outputs to ./landingpage/public
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
`landingpage/**`, the site recipes, or the deployment workflow. It can also be
started manually. The base URL comes from the Pages configuration. Deployment
uses the Node 24 Pages action with OIDC permissions on the deploy job and one
bounded retry for transient GitHub failures; a second failure fails the run.

- **Now:** served at the project-pages URL, `https://dbpprt.github.io/dieter/`.
- **Custom domain:** configure `getdieter.com` under **Settings → Pages** and
  point the domain's DNS at GitHub Pages. The workflow picks up the configured
  base URL automatically.

One-time setup: **Settings → Pages → Build and deployment → Source: GitHub Actions.**
