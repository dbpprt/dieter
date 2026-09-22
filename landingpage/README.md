# Dieter website and documentation

The Hugo site at [getdieter.com](https://getdieter.com/) is the public product
introduction and maintained user documentation. It is separate from the
machine-only gateway and is not a browser client for Dieter.

## Preview and check

Requires Hugo extended 0.164+ and Python 3. From the repository root:

```sh
just site serve
just site check
```

The default preview is `http://127.0.0.1:1313`. In a Dieter conversation, register
long-running preview/build processes with `start_background_process` or
`dieter remote exec --card CARD_ID --detach -- just site serve`.

`just site build` generates `landingpage/public`. `just site check` builds, then
checks rendered local links, fragments, assets, search entries, image alt text,
and maintained repository documentation links. Dated engineering records retain
their historical evidence paths and are excluded from that last check. Also check the page in a real browser at
both desktop and phone widths, including keyboard navigation and search.

## Source layout

| Location | Contents |
| --- | --- |
| `content/docs` | Canonical user guides, one Markdown file per topic |
| `layouts/index.html` | Product landing page |
| `layouts/partials/docs-*.html` | Sidebar, content shell, table of contents, next/previous |
| `layouts/partials/search.html` | Build-time JSON index and native search dialog |
| `layouts/shortcodes/screenshot.html` | Captioned, full-size-linked product captures |
| `assets/css/main.css` | Responsive site and documentation styles |
| `assets/js/main.js` | Navigation, copy buttons, local search, keyboard controls |
| `data/landing.yaml` | Supported harness names; models stay in the host catalog |
| `static/images/screenshots` | Curated native screenshots shared by site and GitHub README |
| `static/fonts` | Self-hosted Sora font; body and code use system fonts |

Do not edit or commit generated `public/` or `resources/` output. The site needs
no client framework, external search service, analytics, or external font request.
Core content and navigation work without JavaScript. The bundled Sora font is
redistributed with its [SIL Open Font License](static/fonts/OFL-Sora.txt).

## Write documentation

Keep the README concise and put detailed user workflows here. Use the front matter
`group` and `weight` to place a guide in the sidebar. Groups are Overview, Start
here, Workflows, Operate, Reference, and Contribute. Weight order also controls
next/previous navigation.

Use `/docs/slug/` for internal page links and relative repository links only in
repository Markdown. Hugo render hooks make root-relative links and image URLs
work when the site is mounted under a GitHub Pages subpath. Search indexes titles,
descriptions, and rendered guide text locally at build time.

Use the screenshot shortcode with meaningful alt text and a caption. See
[screenshot provenance](../docs/screenshots/README.md) for the capture environment
and privacy rules. Use real native captures; do not fabricate product UI.

Dated `docs/` investigations are historical evidence. Keep their original paths
and link current user guidance from [the technical index](../docs/README.md).

## Sharing image

`static/images/og-image.png` uses the same typography, colors, and real app captures
as the site. Regenerate it on macOS with:

```sh
swift landingpage/tools/render_social.swift
```

Inspect the resulting 1200 × 630 PNG before committing it.

## Publication

`.github/workflows/pages.yml` builds site changes on `main` and deploys the
resulting artifact to GitHub Pages. It also supports manual dispatch. The workflow
uses the Pages-configured base URL; the canonical custom domain is getdieter.com.
`SITE_BASE_URL` overrides the production base for local subpath checks.

A local build or preview does not publish the site. The GitHub README likewise
changes publicly only after the reviewed repository changes are published.
