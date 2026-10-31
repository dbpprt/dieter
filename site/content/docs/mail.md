---
title: "Mail (reports from agents)"
linkTitle: "Mail"
description: "Let agents send you read-only Markdown reports, such as a nightly audit or a finished migration, and read them in a mailbox on your Mac, iPhone, iPad or Android device."
group: "Workflows"
weight: 26
slug: "mail"
---

Mail is a mailbox for reports from your agents. A scheduled dependency audit, a
finished migration or a weekly test summary arrives as a message with a subject
and a Markdown body, so you don't have to dig through the conversation that
produced it. Mail is one-way: you read, flag, archive and delete messages, but
you can't reply. To answer an agent, open the conversation that sent the
message.

## Let agents send you mail

Agents can send mail only from conversations created with mail access:

- **Mac:** switch on **Allow the agent to send you mail** in the New Card sheet,
  the **Mail** button when you start a standalone chat, or **Allow mail** in a
  schedule.
- **Android, iPhone and iPad:** switch on **Allow mail to you** under **Access**
  when you create a task or chat, or **Allow mail** in a schedule.
- **CLI:**

```sh
dieter card create --project P --board B --title "Audit dependencies" \
  --workspace worktree --mail
dieter chat create --project P --title "Summarize open issues" --workspace project --mail
dieter schedule create ... --mail        # every card it creates may send mail
dieter schedule update SCHEDULE_ID --mail=false
```

Mail access is off by default, and the apps don't remember it between forms.
You choose it when you create a card or chat, and you can't change it later on
that conversation. A schedule's setting can be changed at any time and applies
to the cards it creates from then on. A conversation without mail access can't
create a card, chat or schedule that has it.

With mail access, the agent's instructions explain how to send a report and
which Markdown renders. Agents can only send. They can't list, read or change
your mail, so one conversation never sees another's reports.

## Read your mail

On the Mac, choose **Mail** in the sidebar. The list shows the newest messages
first, grouped by day, with the sender, subject and a preview. Unread messages
have a blue bar, important ones a red **!**. The message opens on the right.

- The menu at the top of the list switches between **Inbox**, **Flagged**,
  **Unread**, **Archive** and **Trash**. Search (⌘F) matches the subject,
  sender, project and preview. **Filter** narrows the list to a project,
  machine or sender, or to important mail.
- **Open conversation** jumps to the card or chat that sent the message.
- **Copy Markdown**, **Export PDF…** and **Export HTML…** are in the ⋯ menu.
  **Open in New Window** (⌘O, or double-click) shows a wide report on its own.
- Keyboard: ⌘⌫ moves the selection to the Trash, ⌃⌘A archives it, ⇧⌘U marks
  it read or unread, and ⇧⌘L flags it.

On Android, iPhone and iPad, open **More → Mail**. Swipe a message left to
archive it and right to mark it read or unread; each swipe can be undone. Touch
and hold a message to select several. On tablets and iPads the message opens
next to the list.

Opening a message marks it read. Read, flag and folder changes reach every
device, because each message and its state live together on the machine that
received it. While that machine is offline, its messages stay listed with a
note. A message opens offline if this device has read it before, and changes
you make wait until the machine is back. Messages in the Trash are deleted
after 30 days.

## Notifications and badges

The **Mail** sidebar row on the Mac, and **Mail** in More on Android and iOS,
show how many Inbox messages are unread; the **More** badge includes them. On the Mac, **Settings → Notifications** has three mail options:

- **New mail** posts a notification for each new message. Its **Mark as Read**
  and **Archive** actions work without opening the app, and clicking it opens
  the message.
- **Only important mail** limits notifications to messages marked important.
- **Show unread mail count on the Dock icon** is off by default.

The phone and tablet apps don't post notifications yet.

## Send mail from the CLI

An agent sends a report from its turn. Scripts and jobs can send too:

```sh
dieter mail send --subject "Nightly backup completed (41.2 GB)" \
  --from backup.sh --body-file report.md
generate-report | dieter mail send --subject "Weekly flaky tests" --body-file -
dieter mail send --machine Studio --subject "Disk almost full" --important --body "..."
```

`--from` names a script or job; agents can't use it. `--important` marks a
failure or finding that needs action. Repeating a send with the same
`--operation-id` returns the first message instead of a duplicate.

Read and organize the mailbox of a machine from the CLI:

```sh
dieter mail list                        # Inbox; --folder archive|trash|all, --unread, --flagged
dieter mail show ml_0123456789ab        # header and Markdown body; --raw for the body only
dieter mail mark ml_0123456789ab --read --folder archive
dieter mail delete --empty-trash
```

## What a message can contain

The body is GitHub-flavored Markdown. Every app renders the same subset:

| Renders                                                                    | Shown as text instead                             |
| -------------------------------------------------------------------------- | ------------------------------------------------- |
| Headings, paragraphs, **bold**, _italic_, ~~strikethrough~~, `inline code` | Raw HTML                                          |
| Links; relative links open the file in the sender's workspace              | Images (shown as a link, never loaded)            |
| Ordered, unordered and nested lists; task lists (read-only)                | Footnotes and math                                |
| Block quotes, horizontal rules, fenced code with a language                | Unsupported or invalid diagrams (readable source) |
| Tables with column alignment and formatting and links in cells             |                                                   |
| Mermaid, Vega-Lite (`vega-lite` or `vegalite`) and Vega (`vega`) fences    |                                                   |

Wide tables scroll sideways on their own, and the message stays put. Diagrams
use the same bundled offline renderer as the Mac Files preview on macOS,
Android and iOS. Charts must use inline JSON data (`data.values` or inline
named datasets); external datasets, chart links, scripts and image/resource
loads are blocked. This does not enable remote images. Mermaid uses strict
security. Invalid or unsupported blocks retain readable source, so one bad
chart does not hide the rest of the report.

Mail diagrams are read-only graphics; Vega parameter controls are not interactive.
Charts fit narrow screens and follow the app's light or dark appearance. An
omitted or `null` chart background blends with the message surface; an explicit
background such as `"#ffffff"` stays opaque. Default chart text follows that
background, including titles, subtitles, legends and annotations. Author-specified
colors are preserved.

The renderer keeps its existing limits: 100,000 Mermaid characters, 1 MB of chart
JSON and a maximum JSON nesting depth of 100. Mail's smaller body limit still
applies. Mac PDF and HTML exports keep rendered diagrams as static SVGs.

Limits:

| Limit       | Value                                                    |
| ----------- | -------------------------------------------------------- |
| Subject     | One line, at most 200 characters                         |
| Body        | At most 128 KiB and 4,000 lines; each line at most 8 KiB |
| Agent sends | 10 per turn and 50 per conversation in any 24 hours      |
| Mailbox     | 2,000 messages and 128 MiB of bodies per machine         |

When a machine's mailbox is full, Dieter first removes messages from the
Trash, then the oldest read messages in Archive, then the oldest read messages
in the Inbox. Outside the Trash it never removes unread or flagged mail; if
only those are left, new mail is refused until you make room.

## Privacy

Messages are stored only on the machine that received them, in `DIETER_HOME`.
They are not replicated to your other machines; the apps read them over the
same end-to-end encrypted routes as everything else, so the gateway never sees
them. When an agent has revealed a vault password during its turn, Dieter
removes it from the subject and body before storing the message. Agents run
unsandboxed as your user, so treat mail access as a guard against mistakes,
not as isolation.
