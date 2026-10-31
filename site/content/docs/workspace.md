---
title: "Conversation workspace"
linkTitle: "Conversation workspace"
description: "Read the result, inspect changes, and keep the running tools beside the conversation."
group: "Workflows"
weight: 21
slug: "workspace"
---

The Mac conversation workspace opens files, web pages, terminals, changes, and
registered processes beside the chat. Use **Split conversation and workspace** in
the conversation header to show it, and **+** to open another workspace tab. The
Android and iOS app offers the same tools in each task's panes, on each project's
page (Files, Changes, Schedules) and on each machine's page (screen, terminals).

{{< screenshot src="macos-conversation.png" width="1380" height="870" alt="A running Atlas API task with its reply and plan progress on the left and the limiter.go diff in the Changes tab on the right" caption="A running task with its Git changes open beside the conversation." >}}

## Open the result

Click a file or web link in a Mac conversation to open the right pane. Markdown
uses the native rich editor; code opens with syntax highlighting and linked line
numbers; images support zoom; PDFs use PDFKit. Web URLs open with browser
navigation and an **Open in default browser** action.

Files are read from the conversation's actual machine and workspace. Remote
paths are not treated as files on your Mac. Use Download or Save a Copy to bring
one locally. Local files also offer **Open in** and **Show in Finder**.

Agents can explicitly present a deliverable:

```sh
dieter card present CARD_ID --path docs/plan.md --title "Implementation plan"
dieter card present CARD_ID --path src/main.go --line 42
dieter chat present CHAT_ID --url https://example.com
```

Presentation opens or focuses a native content tab. It does not wake an agent or
prove that somebody has read it. A file must be within the conversation workspace,
regular, outside `.git`, and no larger than 5 MiB; symlink escapes are rejected.

## Browse project files

A project's **Files** surface opens a checkout's files in the main workspace.
Choose the checkout to browse, then open a file.

{{< screenshot src="macos-files.png" width="1380" height="870" alt="Atlas API Files on Office mini with docs/rate-limits.md open in the native Markdown editor" caption="Read and edit the project’s actual files on the host that has the checkout." >}}

## Edit Markdown

**Edit · Source** switches between native rich editing and the Markdown source.
Both use the same draft and a separate Save action. Saves check the file revision;
a concurrent change preserves your edits and reports a conflict.

Large documents and files with unusually long lines open in Source automatically
to keep the viewer responsive. The complete text remains available for editing
and saving; rich formatting and diagram previews are disabled for these files.

While a Markdown file is visible in the active Mac app, Dieter checks for changes
on its machine every two seconds. A clean editor reloads automatically. If you have unsaved edits,
choose **Reload from Disk** to discard them and load the disk version, or
**Overwrite Disk** to save your edits over it. This works for remote files too.

Mermaid and Vega/Vega-Lite fences render locally. Click a diagram to edit its
source, then leave the block to render it again. Rendering libraries are bundled;
external datasets, scripts, and images are not fetched by the diagram renderer.

Use **Export PDF…** or **Export HTML…** to share the current draft, including its
rendered diagrams. PDF uses light A4 pages; HTML is standalone. Copy as Rich Text
and Copy as Markdown work for a selection or the whole document.

## Inspect Git changes

Changes behaves like a source-control panel, not a per-agent report.
New-worktree conversations own their Changes view. For project-directory work,
open the project's **Changes** (on Android and iOS, the project's page → **Changes**), which
shows the shared checkout. The
daemon reads one lightweight status snapshot, loads diffs on selection, and owns
staging, commits, updates, validation, integration and explicit publishing, so
Mac, Android, iOS and CLI clients converge on the same Git state. The same file can appear in both Staged
and Changes when only part of its edits is staged.

The list shows changes as a folder tree by default, or as a flat list. Hover a
file or folder to stage (+), unstage (−), discard, or open it in Files; right-click
for the full menu, including copying paths. Discarding a folder restores its
tracked files to HEAD and removes its untracked files, after Dieter saves a
recovery copy. Use ↑/↓ to step through files, Space to stage or unstage the
selected file, and ⌘↩ to commit.

```sh
dieter workspace changes WORKTREE_CARD_ID
dieter workspace changes --project PROJECT_ID
dieter workspace diff --project PROJECT_ID --section unstaged --path src/main.go
```

Mutations use the current changeset revision to reject stale edits. Review staged
content before committing; committing everything is a separate, explicit choice.

## Follow processes

An agent can start a build or server with `start_background_process`. It appears
in that conversation's **Processes** tab, with running/exit state and separate
bounded stdout and stderr. CLI equivalents are:

```sh
dieter remote exec --card CARD_ID --detach -- npm run dev
dieter remote list --card CARD_ID
dieter remote --help
```

Commands use exact argv without a shell unless one is explicitly requested.
Leaving the tab or ending a turn does not stop the process. Exit, timeout,
explicit Stop, or daemon shutdown ends it. Processes and terminal sessions have
different lifecycles; see [Terminals & automation](/docs/automation/).

## Capture an idea on Mac

Choose **Capture task** in the expanded Dieter Island and drag a screen region.
The capture opens in **Quick task** with project, board, and agent selection.
Supported browsers can contribute their current page URL; you can edit it.
Draw, highlight, or add arrows in the attachment markup editor before adding
or running the task. Escape cancels capture.

Browser context may require Automation or Accessibility access. Screen capture
requires Screen Recording. Temporary capture files are removed after attachment
import. See the [product tour](/docs/tour/) for native screenshots.
