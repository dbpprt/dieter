# Conversation workspace reference

The Mac side panel is experimental and off by default. Enable **Settings → Experimental → Show the workspace side panel** before following the panel workflows below.

See the [workspace guide](../landingpage/content/docs/workspace.md) for the everyday flow.
This page records native file rendering, editing, presentation, and capture routing.

## Linked content


Click a file or web link in a conversation to expand the chat and open a resizable
content pane on the right. Markdown opens in the native rich editor, code and text
open in a selectable syntax view (including linked line numbers), images support
zoom, PDFs use PDFKit, and web URLs open in a browser with Back, Forward, Reload,
and Open in default browser. Other files offer Save a Copy.
Bare development addresses such as `127.0.0.1:4018`, `localhost:3000`, and
`[::1]:8080` are clickable in prose and inline code. Fenced code stays literal.

Files are read from the conversation's machine and workspace through the existing
file API. Markdown saves check the file revision; conflicts preserve your edits.
Opening another item or closing an edited document offers Save, Discard Changes,
or Cancel. Switching conversations retains the current unsaved document until
you return or choose another item. Closing the content pane restores the previous
board or chat-list layout. Right-click a file link for **Open in** (supported
installed apps) or **Show in Finder** on its owning local workspace. Remote files
offer **Download File** for a local copy; their paths are never opened as local
files. Command-click keeps the system's external link action.

Agents can register exact-argv background commands with `start_background_process`;
`list_background_processes`, `read_background_process`, and
`stop_background_process` stay bound to the owning conversation. CLI automation
uses `dieter remote exec --card ID --detach --format json -- COMMAND ARG…`.
The **Processes** workspace tab shows running and exit state, separate bounded
stdout/stderr, and an explicit **Stop** action. Closing a tab or finishing a turn
detaches observers; processes end on exit, timeout, explicit stop, or daemon
shutdown.

### Markdown files on macOS

Markdown files in **Files** open in **Edit**, using SwiftMarkdownEngine for native
rich editing with headings, formatting, lists, links, and tables. Mermaid and
Vega/Vega-Lite fences appear as rendered diagrams and charts. Click a diagram to
edit its code; moving the caret outside the block renders it again. The original
fenced Markdown remains the saved source.

Use **Edit · Source** to switch between rich editing and Markdown source. Both
views share the current draft, retain their native editors when switching modes,
and use the same separate **Save** action. Files always open in Edit mode.

Right-click the rich editor to **Copy as Rich Text** or **Copy as
Markdown**. A selection copies only that content; without a selection, the whole
document is copied. Rich text uses formatted HTML with a plain-text fallback.

Vega-Lite charts adapt to the editor pane even when their Markdown specifies a
fixed width. Titles and subtitles wrap; axes, labels, and chart annotations stay
within the pane. Authored heights and colors are preserved. Composed, stepped,
and Vega charts fit proportionally when their layout cannot reflow. Resizing the
pane does not modify the saved chart specification.

Fenced `mermaid` blocks render diagrams. Use `vega-lite` (or `vegalite`) fences
for Vega-Lite charts, or `vega` for Vega specifications, with inline chart data
such as `data.values`. Tables, ordinary code blocks, and links also render. The
renderer and its libraries are bundled for offline use; it does not fetch
external images, datasets, or scripts. A diagram error stays beside that block
while the rest of the document remains visible. Mermaid source is limited to
100 KB; Vega/Vega-Lite JSON has a separate 1 MB limit for embedded datasets.

The file header's name and path are selectable, with **Copy File Name** and
**Copy Path** actions. **Open in** lists installed applications for verified
local files, with **Save As…** for a local copy. A visible **Show in Finder**
control is available for every file type in Files and the conversation workspace.
Files on remote machines can be saved as a local copy; remote paths are never
opened on this Mac.

Markdown files offer **Export PDF…** and **Export HTML…** from the file toolbar
in Files and the conversation workspace.
Exports include the current unsaved draft and rendered diagrams and charts. PDF
uses a light appearance and paginated A4 pages; HTML is a standalone document.


## Capture a Quick Task


Use **Capture task** in the expanded Dieter Island, then drag to select a screen
area (Escape cancels). The screenshot opens in a Quick Task draft with project
and board selection, the usual agent controls, and an editable page URL when
the foreground app is a supported browser. **Add task** saves a draft; **Run task**
creates and starts it immediately. Safari and Chromium browsers can request macOS Automation access to read
the current tab; Firefox uses existing Accessibility access. If the URL cannot
be read, paste it into the draft. Screen capture requires macOS Screen Recording
permission. Temporary capture files are removed after attachment import.

The screenshot editor appears to the right of the inputs, or below them in a
narrow window. Draw, highlight, add arrows or shapes, choose colors, and undo
marks before applying them. **Apply** replaces only the staged attachment;
**Cancel** preserves it. The same markup editor is available on image attachments
in chat, new conversations, Quick Task, and draft editing.

This uses the existing card-creation API; CLI automation can create the same
request with `dieter card create --project PROJECT --board BOARD --auto-title --prompt TEXT --attach SCREENSHOT` and include the page URL in the prompt.

### Browser capture project routing

Agents can maintain browser host mappings, with optional ports, on a project
through the daemon:

```sh
dieter project update --hostname app.example.com --hostname localhost:4018 PROJECT_ID
dieter project show PROJECT_ID
dieter project update --clear-hostnames PROJECT_ID
```

`--hostname` is repeatable and replaces the complete list; omitting both hostname
flags preserves it. Use `--machine ID|NAME` for projects on another daemon.
Mappings are stored centrally with project metadata. CLI inputs accept DNS names
(punycode for international names) or IPv4 addresses, optionally followed by
`:port`. Use bare IPv6 addresses for host-only mappings and brackets for an IPv6
address with a port, such as `'[::1]:4018'`. Ports must be numeric and between 1
and 65535. Hostnames are lowercased and trailing dots removed; IP addresses and
ports are canonicalized. The list is deduplicated, sorted, and limited to 64
entries. CLI inputs cannot contain URLs, paths, or wildcards; subdomains require
their own entries.

Capture task checks board mappings before mappings on active projects. Within each scope,
an exact host-and-port match wins; if none exists, a bare-host mapping matches
that host on any port. Matching uses the URL's explicit port, or port 80 for HTTP
and 443 for HTTPS when omitted. For example, `localhost:4018` takes priority over
`localhost` within board mappings. Multiple equally specific destinations require
a manual choice; no match also asks for a destination. The user still reviews
and submits the Quick Task. Mappings do not grant access to a website or start
any task.

Local Mac builds automatically use the sole available Apple Development signing
identity, so macOS privacy grants can survive rebuilds. Set
`DIETER_MAC_SIGNING_IDENTITY` to a specific certificate fingerprint when multiple
identities are installed, or `-` for ad-hoc signing. CI and machines without a
single development identity retain ad-hoc signing. Switching from an old ad-hoc
build may require granting Screen Recording to the newly signed Dieter app once.

Board hostname mappings take priority over project mappings for Capture task.
Users can edit URLs/host mappings in Board settings or remember a captured URL's
host mapping for the selected board when saving a Quick Task. Global Quick Task is
available in the sidebar and always shows project and board selectors. Unmatched
or ambiguous captures stage a draft with no destination until the user chooses.
Capture alone does not start an agent; choose **Add task** or **Run task**. The sidebar and board
Quick Task popovers keep their draft in memory when dismissed, including attachments
and agent settings. Submitting or restarting clears task text and attachments,
while the last project, board per project, and agent settings are remembered.
Projects without a previous board selection default to their first board.

```sh
dieter board hostnames --hostname localhost:4018 --hostname '[::1]:4018' BOARD_ID
dieter board hostnames --append --hostname preview.example.com BOARD_ID
dieter board hostnames --clear BOARD_ID
dieter board show BOARD_ID
```

The default replaces the full list; `--append` adds atomically and deduplicates.
CLI inputs use the host or host-and-port format above. Board settings also accepts
HTTP(S) URLs and stores their hostname plus an explicit port when present. The
same normalization, matching rules, and 64-entry limit apply.
