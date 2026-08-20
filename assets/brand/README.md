# Nauclio brand pack

Nauclio is pronounced **NAW-klee-oh** (/ˈnɔː.kli.oʊ/).

The name is inspired by Greek *naúklēros* and Latin *nauclērus*: the shipmaster responsible for a vessel and its crew. The identity translates that idea into a developer product: the human remains at the helm while multiple agent harnesses and shell sessions work as a coordinated fleet.

## Core idea

The selected mark is **Docked Shells**:

- three terminal windows represent multiple agents, harnesses, or sessions;
- the three-spoke wheel represents orchestration and human control;
- the surrounding ring represents persistent connectivity across devices;
- cyan and seafoam indicate live execution and healthy state.

Primary message: **One command deck. Every coding agent.**

Supporting promise: **Run any harness, on any machine, from any device.**

## Contents

- brand-guide.html — complete interactive light/dark reference
- theme.css — website-ready semantic theme variables and components
- tokens.json — portable design tokens
- manifest.webmanifest — starter web-app manifest
- assets/svg/mark.svg — primary color mark on transparency
- assets/svg/mark-mono-dark.svg — one-color mark for light surfaces
- assets/svg/mark-mono-light.svg — reversed mark for dark surfaces
- assets/svg/logo-horizontal-*.svg — horizontal lockups
- assets/svg/logo-stacked-*.svg — stacked lockups
- assets/svg/app-icon-*.svg — flat app-icon constructions
- assets/svg/favicon.svg — simplified small-size mark
- assets/png/app-icon-*.png — production PNG sizes
- assets/favicon.ico — browser favicon
- assets/Nauclio.icns — macOS icon bundle
- assets/Nauclio.iconset/ — editable macOS iconset source
- assets/social/og-image.* — social sharing artwork
- reference/ — dimensional ImageGen master icons
- generation-prompts.md — final identity-preserving prompts

## Repository integration

This directory is the canonical source of Nauclio artwork and tokens. The
native release surfaces consume it as follows:

- macOS packages `assets/Nauclio.icns`, the dark 1024 px app icon, and the
  small-size favicon directly into `Nauclio.app`;
- Android launcher, adaptive, monochrome, and notification resources are
  derived from the dark app icon, primary mark, and reversed monochrome mark;
- the open-source README uses `assets/social/og-image.png` as its release hero;
- both native themes implement the dark semantic palette from `tokens.json`.

Keep generated platform derivatives synchronized whenever a canonical master
changes. On macOS, run `apps/android/scripts/sync-brand-assets.sh` from the
repository root to regenerate Android bitmaps. Do not introduce a separate
platform-specific logo source.

## Palette

| Token | Hex | Purpose |
| --- | --- | --- |
| Abyss | #071426 | Primary dark brand field |
| Deep Current | #0B1F3A | Dark surfaces and terminal bodies |
| Cobalt | #2563EB | Control and primary brand energy |
| Aegean | #22D3EE | Live agents, focus and active state |
| Seafoam | #5EEAD4 | Success and connection accents |
| Foam | #F7FAFC | Light background |
| Mist | #EAF2F8 | Light secondary surface |
| Slate | #526174 | Light-theme secondary text |

Use cyan and seafoam to communicate state. Avoid using them as decoration across every surface.

## Typography

- **Sora 600–700** for brand, headlines, and major numeric state.
- **Inter 400–600** for product UI and body copy.
- **JetBrains Mono 500** for commands, identifiers, logs, and status.

The CSS includes system fallbacks. For production, self-host the three open-source families or install them through the application's existing font pipeline.

## Logo rules

- Clear space: at least the diameter of the central hub around the complete mark.
- Minimum primary-mark size: 32 px digital; use favicon.svg below 32 px.
- Minimum horizontal-logo width: 132 px.
- On light surfaces use the dark wordmark; on dark surfaces use the light wordmark.
- Monochrome marks may be Abyss, Foam, or pure black/white when production requires it.
- Do not rotate the mark, rearrange the sessions, add more spokes, or recolor individual windows.
- Do not use a bare many-spoked wheel; the three session windows are the distinctive element.

## Website behavior

Light mode is editorial and open: Foam background, white surfaces, Abyss text, and Cobalt actions.

Dark mode is the product-native default: near-black background, Deep Current surfaces, Foam text, and brighter cyan controls.

Both modes share the same component geometry:

- 14 px control corners
- 22 px card corners
- 44 px minimum interactive height
- visible 3 px focus ring
- restrained shadows and glow

Open brand-guide.html in a browser to review both themes.

## Voice

Nauclio should sound calm, capable, and direct.

Prefer:

- “Launch agent”
- “Attach shell”
- “Review changes”
- “Agent still running on Mac Studio”
- “Connected from three devices”

Avoid:

- vague “AI magic” language
- aggressive military language
- excessive nautical jokes
- pretending the agent, rather than the user, is in command

## Recommended favicon markup

    <link rel="icon" href="/assets/svg/favicon.svg" type="image/svg+xml">
    <link rel="icon" href="/assets/png/favicon-32.png" sizes="32x32">
    <link rel="apple-touch-icon" href="/assets/png/app-icon-dark-180.png">
    <link rel="manifest" href="/manifest.webmanifest">
    <meta name="theme-color" content="#071426">

## Status

This is a complete first-round identity system derived from the selected icon direction. The dimensional store icon was generated with the built-in image-generation workflow; the small-size, monochrome, lockup, token, and website assets were constructed deterministically.
