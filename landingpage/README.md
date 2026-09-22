# getdieter.com

The marketing site and documentation for **Dieter** — coding agents across all
your machines, behind one interface. Built with [Hugo](https://gohugo.io)
(extended) and a fully custom, light theme.

The GitHub Pages workflow is named **Deploy getdieter.com**. Its custom-domain
configuration uses `https://getdieter.com/` as the canonical website, with
`www.getdieter.com` redirecting to the apex through GitHub Pages.

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

Repository settings use **Settings → Pages → Source: GitHub Actions**, custom
domain **getdieter.com**, and **Enforce HTTPS** after certificate provisioning.
The workflow reads the Pages base URL automatically; publish a fresh build after
changing the domain so asset paths and canonical URLs use the domain root.
Workflow-based Pages deployments do not need a `CNAME` file.

Namecheap's DNS zone uses these website records:

| Type | Host | Value |
| --- | --- | --- |
| A | `@` | `185.199.108.153` |
| A | `@` | `185.199.109.153` |
| A | `@` | `185.199.110.153` |
| A | `@` | `185.199.111.153` |
| AAAA | `@` | `2606:50c0:8000::153` |
| AAAA | `@` | `2606:50c0:8001::153` |
| AAAA | `@` | `2606:50c0:8002::153` |
| AAAA | `@` | `2606:50c0:8003::153` |
| CNAME | `www` | `dbpprt.github.io` |
| TXT | `_github-pages-challenge-dbpprt` | Account-specific value from GitHub Settings → Pages |

Keep the verification TXT record after GitHub verifies domain ownership. Replace
Namecheap's apex parking redirect and `www` parking CNAME; preserve unrelated
records. TTL can remain Automatic. The TURN subdomain has its own VPS record,
owned by the private deployment repository; it must not point at GitHub Pages.

Verify the apex HTTPS page, `www` redirect, old project-URL redirect, canonical
and sitemap URLs, documentation pages, and CSS/JavaScript/image loads. GitHub's
[custom-domain guide](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site)
documents DNS and certificate provisioning; its
[domain-verification guide](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/verifying-your-custom-domain-for-github-pages)
documents the account-level TXT record.
