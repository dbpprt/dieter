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

## Follow-up: headless agents and a busier Mac workspace

The README, homepage, metadata, and sharing artwork now lead with **“Close your
laptop. Keep your agents running.”** The copy explains that execution stays on
an awake, powered-on host; closing a client or sleeping the client laptop does
not transfer or stop an agent on another machine. The README is now 136 lines.

Five Mac captures replace the initial three. They use dark Electric Blue styling
with the right conversation workspace panel disabled. The board shows five
projects in navigation and 17 labeled tasks across two enrolled daemon owners,
with three mock turns active at capture. Other images show a native terminal
running eight real sample-project tests, the main Files surface, host telemetry,
and a live screen-sharing session. The five Android images remain unchanged.

The homepage has a new terminal and screen-sharing section. The product tour and
projects, workspace, automation, machines, and screens guides now use the updated
set, with meaningful alt text and accurate captions. The two obsolete side-panel
images were removed. The 1200 × 630 sharing artwork was regenerated and inspected.

### Evidence and limits

- `just mac build` passed using the canonical packaged debug app and existing
  SwiftPM cache. Existing source warnings remained; no app source changed.
- Actual native journeys covered the multi-owner board, terminal, Files,
  machine telemetry, and live Screens. Every final PNG was visually inspected.
- The two daemon identities run on one physical Mac. The screen fixture limits
  capture to its owned demo window through a development copy of the helper;
  the production feature remains display sharing. These limitations and the
  sample data are recorded in [screenshot provenance](screenshots/README.md).
- A prior Release Control interaction showed a clipboard cancellation warning.
  A fresh session produced the clean live capture. This does not establish a
  complete clipboard or remote-input test, and no app fix is claimed here.
- Both owned Mac app sessions exited cleanly; `just mac status` reported zero
  app processes. The registered fixtures and visual target were explicitly
  stopped. The operator daemon was left running. The site preview remains
  registered separately.

### Verification

- `just check-changed --dry-run`, `just check-changed`, `just site check`, and
  `git diff --check` passed. Documentation validation covered 19 rendered pages
  and 43 maintained Markdown files, including links, fragments, images, and search.
- BrowserOS neo review verified the current headline, desktop hero, native
  screenshot loading, and the new terminal/screen layout. The homepage had no
  horizontal overflow at 360, 390, 768, 1024, or 1440 pixels; the new section
  changes from two columns to one. The tour had no horizontal overflow at
  360 or 1024 pixels and contained all ten images with their new alt text.
- Desktop and phone screenshots and the sharing artwork were visually checked.
  An asynchronous image-decode browser probe timed out; subsequent direct visual
  inspection confirmed both new homepage images loaded. It is not counted as a
  passing automated browser assertion.
- Native integration suites were not repeated for this documentation-only
  follow-up. The initial refresh's suite results above remain historical evidence.
