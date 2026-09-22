# Documentation refresh — 22 September 2026

This is a review record for the documentation and website refresh. Current user
guidance lives in [the public guides](../landingpage/content/docs/_index.md).

## Result

The root README went from 1,450 lines to 132. Installation, the product overview,
and contribution entry points remain there; detailed workflows now have dedicated
guides. The Hugo website has a new responsive design, native app screenshots,
local documentation search, and a matching sharing image.

The documentation map now separates three kinds of material:

- Maintained user guides in `landingpage/content/docs`, grouped by task.
- Component development guides and implementation references in `apps`, `api`,
  `deploy`, and `docs`.
- Dated investigations and validation records, explicitly marked as historical
  evidence with their original paths preserved.

## Accuracy corrections

| Area | Current documented behavior |
| --- | --- |
| Setup | `dieter setup` enrolls and starts the host; `dieter project open PATH` separately registers an existing working tree. |
| Project ownership | Shared logical project identity; immutable checkout and execution owners. A project is not owned by one machine. |
| Concurrency | No global, provider, or board conversation caps; one active turn per conversation and bounded resources. |
| Models | Five harnesses, including DSH; the selected host's catalog is authoritative. |
| Mac workspace | Experimental side panel, off by default; exact enable path documented. |
| Processes | Exact argv, separate output streams, retained exit state; client disconnect does not stop a command. Daemon shutdown does. |
| Screens | Four viewers, one controller; implemented clipboard sharing; inactivity disconnection defaults off. Platform capabilities remain explicit. |
| Gateway | Stored control metadata and normalized quotas are distinguished from relayed API payloads. |
| Local execution | Agents and tools execute on hosts; cloud model providers can still receive prompts and code. |
| Native clients | Android starts in Activity; iOS is described as beta. Isolated test fixtures and lifecycle rules are documented. |

Added contribution and security policies, issue forms, a PR template, troubleshooting,
workflow guides, screenshot provenance, and a technical documentation index.
Third-party vendored documentation and generated schemas were left untouched.

## Native evidence

Eight new real screenshots cover Mac boards, document review, and Processes;
Android Activity, standalone chat, task conversation, machine discovery, and
telemetry. They use disposable data and the mock harness, with no production
conversation or account credential capture. See [provenance and refresh steps](screenshots/README.md).

The Mac app was built with the canonical SwiftPM cache. The core native smoke
suite passed. Android Machines and Activity fixture journeys passed on
`Pixel_9_API_37_1`, `emulator-5554`; the attached physical phone was not targeted.

An experimental Mac automated screenshot wrapper failed and timed out. Its
exports are not used, and that conversation-suite attempt is not counted as a
pass. The final Mac images were captured from the actual isolated app window and
visually inspected, including the native Markdown table and process exit state.
The owned Mac app exited cleanly, and the owned Android emulator saved its
snapshot and stopped cleanly.

## Website verification

- `just check-changed --dry-run`, then `just check-changed`: passed the selected
  Just formatting, workflow, and Hugo checks.
- `just site check`: passed for 19 rendered HTML pages and 43 maintained
  Markdown documents, including local links, rendered fragments, screenshots,
  alt text, and search destinations.
- A separate production build at `https://example.com/dieter/` passed the same
  checks, covering GitHub Pages subpath deployment.
- Browser review covered desktop and phone layouts, documentation navigation,
  search filtering, keyboard opening, Arrow Down/Enter, Escape, copy feedback,
  and real image loading. Installation had no horizontal page overflow at 360,
  768, 1024, and 1440 pixels.
- With JavaScript disabled at phone width, primary and documentation navigation
  remained visible and the page had no horizontal overflow.
- CSS/JavaScript formatting and `git diff --check` passed.

The link checker deliberately excludes dated engineering records, whose local
evidence may no longer exist. It checks links to those records from the maintained
index. It does not claim that every external website remains available.

## Publication

The initial refresh was prepared locally for review. For the subsequent commit
and push request, the changes were rebased onto the latest `origin/main`,
preserving the new standard gateway endpoint and signed migration guidance.
`just check-changed --base origin/main` and `just site check` passed again after
resolving the documentation overlaps.

Publication to `main` triggers the Pages workflow, which builds and validates the
site before deploying; the GitHub README updates from the same change. A successful
local check does not by itself confirm completion of the Pages deployment.
