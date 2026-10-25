# Proposal: agent mail (read-only Markdown reports from agents)

Status: implemented 2026-10-25 ([ADR 0004](../adr/0004-agent-mail.md); §6
records the decisions and where the implementation differs) · scope: new `mail` store aggregate and
`MailService`, a `mail_access` conversation and schedule flag, turn
instructions, CLI, `ChangesFrame`, Kotlin core, Markdown rendering on all three
clients, and a Mail destination on macOS, Android and iOS · UI mockup in
[`assets/agent-mail-mockup.html`](assets/agent-mail-mockup.html)

## TL;DR

Agents can only reach the user through the conversation they run in. A
scheduled audit, a nightly dependency check or a long migration ends with a
reply buried in one of dozens of transcripts. This proposal gives agents a
one-way **mailbox**. An agent sends a Markdown "email" with a subject. It shows
up in a new **Mail** destination that looks and works like Outlook: folders, a
message list with unread state and date groups, and a reading pane that
renders rich tables. The user can read, flag, archive and delete messages, and
jump to the conversation that sent one. **There is no reply.**

- **Capability flag.** `mail_access` works like `vault_access`. It is chosen
  when a card, chat or schedule is created, stored only on the owner daemon,
  and checked through the turn token. Every card a schedule creates inherits
  it. A turn can grant `mail_access` to a conversation it creates only if it
  has the flag itself.
- **Sending.** `dieter mail send --subject … --body-file report.md`, inside a
  turn of a conversation with mail access. A local operator, such as a script
  or cron job, can send too. Agents can send but never list, read or change
  mail.
- **Storage.** Mail stays on the daemon that runs the sending turn, like
  transcripts and channels. Read, flag and folder state live with the message,
  so every device sees the same state. Nothing is replicated, and nothing
  reaches the gateway.
- **Delivery to clients.** Small headers (subject, sender, preview, state) ride
  the existing per-machine `WatchChanges` stream as a new owner-only section.
  That gives every client an account-wide mailbox, unread badges and
  notifications without polling. The core fetches bodies on demand with
  `GetMail`, caches them on the device, and prefetches unread ones.
- **Markdown profile.** "What our rendering supports" becomes a defined,
  tested subset: CommonMark plus GFM tables, task lists and strikethrough. The
  daemon enforces size limits so that every client renders every message in
  full. The turn instructions name the profile exactly. Today's renderers fall
  short of it, especially for tables (§2.2), so rendering is real work in this
  plan:
  - Mac: a read-only view on the vendored Markdown engine.
  - Compose: a proper document renderer on an extended core parser, with
    column-aligned, horizontally scrolling tables.
- **UI.** Mac gets a three-pane mailbox (app sidebar, message list, reading
  pane). Phones get a fifth tab, with a list that pushes the message.
  Tablets and iPads get list and reading pane side by side.

## 1. Goals and non-goals

Goals:

1. An agent with mail access can send the user a titled, rich Markdown report
   that renders the same on Mac, Android and iOS, tables included.
2. Opt in per conversation and per schedule at creation, in the same places
   and with the same rules as vault access.
3. One account-wide mailbox across machines, with unread counts, folders,
   flags and search, that feels like a mail client and not a chat.
4. Read-only by design. Mail never starts a turn, never reaches an agent's
   prompt, and has no reply path.
5. Bounded everywhere: body size, rate per turn and per conversation, store
   size and retention.

Non-goals (v1):

- Replies, threads, forwarding, external email, or sending to anyone but the
  account's user.
- Attachments and images. Workspace file links are supported (§3.7).
- Push notifications on phones. Android and iOS have no notification pipeline
  today; they get badges. Mac gets local notifications (§3.11).
- Charts. The Mac engine already renders Mermaid and Vega-Lite, but phones
  can't. Diagrams stay out of the profile until every client renders them
  (§7).

## 2. What exists today (code facts)

### 2.1 The vault flag is the template

`vault_access` is the exact precedent for a per-conversation capability.

| Layer           | Where                                                                                                                                                                                                                                                                               |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Proto           | `CreateConversationRequest.vault_access` (`cards.proto:66`, used by both `CreateCard` and `CreateChat`), `Card.vault_access` (`common.proto:197`, owner-local, fixed at creation), `Schedule.vault_access` / `ScheduleDraft.vault_access` (`schedules.proto:65,89`)                 |
| Client contract | `CreationIntent.vault_access` (`client.proto:538`, "never remembered between forms")                                                                                                                                                                                                |
| Daemon          | `conversationInput` / `scheduleInput` (`internal/api/conversation_snapshots.go:52,132`), `engine.CardInput` (`conversation_creation.go:67,142`), `kanban.CreateCardInput` (`store/kanban/cards.go:31,138,190`), schedule `Create`/`Update` (`store/schedules/schedules.go:360,613`) |
| Scheduler       | `CreateCard(… VaultAccess: schedule.VaultAccess)` (`internal/engine/scheduler/scheduler.go:262`)                                                                                                                                                                                    |
| Owner-only      | Not in `replication/schema/domain.go` `DomainFields`; reaches clients only through `owned_cards` (`api/changes_local.go:295`) and is merged in `AccountView.ownerDetails` (`sync/AccountView.kt:682`)                                                                               |
| Caller          | `vaultCaller` (`api/vault.go:158`): a turn token on the local route → `VerifyTurnToken` → card → `access: card.VaultAccess`; `vaultAdmit` denies with a typed message                                                                                                               |
| Instructions    | `prompt.ResolveForWorkspace` appends `VaultInstructions(cli)` when `detail.Card.VaultAccess` (`prompt.go:211-232`); contract test `TestAgentInstructionsNameRealCommandsAndFlags` (`internal/cli/instructions_contract_test.go:19`)                                                 |
| CLI             | `--vault` on `card create` / `chat create` (`rpc_cards.go:234`), `--vault=true\|false` on `schedule create/update` (`rpc_schedules.go:270`, defaults to the current value)                                                                                                          |
| Compose         | `CreationScreen` "Vault" section (`ui/…/creation/CreationScreen.kt:371-387`), `ScheduleEditor` Behavior row 3 (`tools/SchedulesScreen.kt:557-569`)                                                                                                                                  |
| Mac             | `NewConversationSheet.swift:108-117`, `StandaloneChatStartView.swift:262-271` (key toggle button), `ScheduleEditor.swift:299-302`                                                                                                                                                   |
| Tests           | `api/vault_test.go:102,223`, `cli/vault_cli_e2e_test.go:26,126`, `prompt_test.go:109`, `CompositionTest.kt:417`, `ScheduleRulesTest.kt:279`, `ClientApiEndToEndTest.kt:148,426`                                                                                                     |

Two gaps found along the way:

- **Agents can escalate vault access today.** `idempotentConversation` and
  `CreateSchedule` don't check the turn token. An agent can run
  `dieter card create --vault` and get a vault-enabled sibling. Mail closes
  this for its own flag (§3.2). The vault gap should be fixed the same way,
  as separate work.
- **No test covers the scheduler copying the flag.** This plan adds one for
  both flags.

### 2.2 Markdown rendering is three different renderers

| Construct                 | Mac transcript (`ConversationMarkdownParser` + `NSTextTable`) | Mac Files (vendored `swift-markdown-engine`, TextKit 2)                                                                       | Compose `RichText` (core `Markdown.parse`)                                  |
| ------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Headings                  | H1–H4                                                         | H1–H6                                                                                                                         | H1–H4, all one size                                                         |
| Italic / strike           | yes / yes                                                     | yes / yes                                                                                                                     | **no / no**                                                                 |
| Ordered, nested lists     | **no**                                                        | yes                                                                                                                           | **no**                                                                      |
| Task lists, quotes, rules | **no**                                                        | yes                                                                                                                           | **no**                                                                      |
| Code fences               | no highlighting                                               | highlighted                                                                                                                   | no highlighting (core `syntaxRanges` unused)                                |
| GFM tables                | alignment, equal-width columns, **no horizontal scroll**      | content-fit widths, alignment, **horizontal scroll**; cell links not clickable, table text not selectable (drawn as an image) | horizontal scroll, **alignment ignored, columns don't line up across rows** |
| Size limits               | 12,000-character preview, then raw source                     | source-only above 200,000 UTF-16 chars, 4,000 lines, or 8,192-char lines                                                      | none (eager `Column`)                                                       |

The Mac engine is the best renderer by far. Its read-only mode
(`NativeTextViewWrapper(isEditable: false)`, `heightBehavior = .fitsContent`)
is documented in the vendored package but Dieter doesn't use it yet. Compose's
`RichText` is the weakest, and tables are its worst construct.

### 2.3 Navigation, data flow and prior art

- **Mac.**
  - `AppSection` (`App/Store/DieterStoreSupport.swift:7`) and
    `SidebarPrimaryDestinations` (`Features/Sidebar/Views/AppSidebar.swift:100`)
    list the destinations: Inbox, Channels, Chats, Terminals, Screens.
  - `ChatPaneSplit(layout:)` (`Features/Chats/Views/ChatPane.swift:108`) is the
    resizable list-plus-detail split. Each layout stores its own width.
  - Channels is the closest shape to a mailbox: a list grouped by machine, an
    unread badge, a `setActive` lifecycle, and mark-read when the newest row
    is visible.
- **Compose.**
  - Tabs are `MobileTab { INBOX, PROJECTS, CHATS, TOOLS }`
    (`ui/…/navigation/Navigation.kt:8`).
  - Layout: a bottom bar under 600 dp, a `NavigationRail` from 600 dp, and two
    panes from 840 dp (`app/MobileApp.kt:94-248`). Only the bottom bar's Inbox
    item has a badge.
  - iOS hosts the same tabs in a native `UITabBarController` (sidebar on iPad).
    The tab specs are hard-coded (`ios/Host/…/ComposeHost.swift:93`) and mapped
    by index in `MobileHost.kt:149,195`.
- **Change stream.** `ChangesFrame` (`state.proto:56`) carries typed
  owner-only sections: `owned_cards`, `owned_checkouts`, `activities`,
  `privacy`.
  - `localChanges.refresh` (`api/changes_local.go:111`) builds them as keyed
    entries and sends only the entries whose digest changed. The `privacy`
    section is the most recent addition and the pattern to copy.
  - The core keeps one `MachineReplica` per machine and caches it on disk, so
    a cold start renders straight away.
- **Agent channels** ([ADR 0003](../adr/0003-agent-channels.md)) are the prior
  art for "an agent writes a message the daemon stores":
  - an append-only, daemon-local store under the writer lock;
  - attribution from the turn token;
  - `--operation-id` idempotency and bounded bodies;
  - a `--machine` refusal inside turns.
  - Channels poll `ListChannels` every 10 s or 60 s. Mail avoids that by
    riding `WatchChanges`.
- **Notifications.** The core decides them (`core/notifications`), but only
  the Mac posts any. No platform routes a tap: `OpenRequests` and `OpenTarget`
  exist only in tests.

## 3. Design

### 3.1 Concepts

- **Message.** Subject, Markdown body, importance (normal or high), a sender
  snapshot, a send time, and state: `read`, `flagged`, and `folder` (Inbox,
  Archive or Trash). The ID is `ml_…`. It lives on one daemon and is
  addressed as `(daemon_id, id)`.
- **Sender snapshot.** Taken at send time, so a message stays meaningful after
  its card is archived, renamed or deleted:
  - kind (agent or operator);
  - card ID and turn ID;
  - scope (card or chat) and conversation title;
  - project ID and name;
  - schedule ID and name, when the card came from a schedule;
  - harness and model;
  - for operators: the calling device and an optional `--from` label.
- **Display name.** A core rule picks one: schedule name, else conversation
  title, else operator label, else "Operator on <machine>". The secondary line
  shows project, machine and harness.
- **Folders.** Inbox, Archive and Trash are real states. Flagged and Unread
  are views over them. The Trash empties after 30 days.
- **The mailbox is account-wide.** The core merges headers from every
  machine's stream. Mail on an offline machine stays listed from the cached
  replica and is marked stale ("Studio is offline"). Its body opens only if it
  is cached.

### 3.2 The `mail_access` flag

Follow vault access field for field:

| Where                                                      | Change                                                                                               |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `cards.proto`                                              | `CreateConversationRequest.mail_access` (cards and chats)                                            |
| `common.proto`                                             | `Card.mail_access`. Owner-local, fixed at creation; forks and merges never inherit it.               |
| `schedules.proto`                                          | `Schedule.mail_access` and `ScheduleDraft.mail_access`. Editable, and applies to future occurrences. |
| `client.proto`                                             | `CreationIntent.mail_access`. Not remembered between forms, like vault (decision D2).                |
| `model.Card`, `model.Schedule`                             | `MailAccess`, with `json:"mailAccess,omitempty" yaml:"mail_access,omitempty"`                        |
| API → engine → store → scheduler                           | The same five call sites as `VaultAccess`, plus the scheduler copy at `scheduler.go:262`             |
| `changes_local.protoOwnedCard`, `AccountView.ownerDetails` | Carry it to clients like `vault_access`                                                              |
| `ForkChat`                                                 | Doesn't copy it, like vault                                                                          |

**No escalation.** When `CreateCard`, `CreateChat`, `CreateSchedule` or
`UpdateSchedule` carries a turn token, the daemon refuses `mail_access` unless
the calling card has it, with `PermissionDenied`: "a conversation without mail
access cannot grant it". A human (local operator or remote device) can always
set it. This is a single `capabilityCaller` helper beside `vaultCaller`, and
the vault fix can reuse it.

**Older daemons.** Not gated (decided): one release ships the daemon and the
clients together, so the toggle is always shown.

**Visibility after creation.** Show the flag next to vault access wherever a
conversation shows its settings:

- Mac: the conversation inspector and info popover show an envelope chip.
- Compose: the conversation details sheet does the same.

Users should never wonder why an agent did or didn't send mail.

### 3.3 Sending

```text
dieter mail send --subject TEXT (--body TEXT | --body-file PATH|-)
                 [--important] [--operation-id ID] [--from LABEL]
```

**Callers** (`mailCaller` beside `vaultCaller` and `channelCaller`):

- **Agent:** a valid turn token on the local route. The sender snapshot comes
  from the card. Denied without `mail_access`, with: "this conversation was
  created without mail access; the user can create one with --mail".
- **Local operator:** no turn token. The sender is an operator with this
  machine and an optional `--from` label. This lets scripts, cron jobs and
  tests send.
- **Remote device:** `--machine`. The sender is an operator carrying the
  device ID. This is needed for CLI parity over direct TLS and relay. Inside a
  turn, the CLI refuses `--machine`, as `vault` and `channel` do.

**Agents may only send.** `ListMail`, `GetMail`, `UpdateMail` and
`DeleteMail` refuse a turn token, as `trust.go` `admit` does: "agents can
send mail but not read it". The mailbox holds every conversation's reports.
Letting an agent read it would leak between conversations and would turn it
into a channel for prompt injection.

**Validation** (`internal/model/mail.go`; the profile limits are in §3.7):

| Field        | Limit                                                                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------- |
| subject      | 1–200 characters on one line; control characters are stripped                                                 |
| body         | valid UTF-8, 1 B – 128 KiB, ≤ 4,000 lines, each line ≤ 8 KiB                                                  |
| operation ID | ≤ 128 characters. A retry with the same `(sender card or device, operation ID)` returns the original message. |
| `--from`     | operators only, ≤ 64 characters                                                                               |

The CLI reads `--body-file` with a bounded `io.LimitReader`, using the
`fileTextValue` pattern from `rpc_files.go:62`, not the unbounded
`textValue`.

**Rate bounds** are derived from stored messages, so they survive restarts:

- at most 10 messages per turn;
- at most 50 per conversation in any 24 hours.

Either refusal is `ResourceExhausted` and names the limit, so the agent can
tell the user in chat.

**Preview.** The daemon derives a plain-text preview of at most 200
characters. It takes the first paragraph, list item or table header with
Markdown syntax stripped (`model.MailPreview`). That way list rows never need
the body.

**Vault redaction.** When the sending turn has revealed vault secrets,
subject, preview and body pass through the same replacement as transcripts
(`engine.redactVaultSecrets` forms) before they are stored. An agent can't
mail a password by accident.

### 3.4 Storage and retention (daemon)

Add a new aggregate, `internal/store/mail`, that depends only on `home`. Add it
to the `store-on-home` depguard list in `.golangci.yml`, to the `store.go` doc
table and to `docs/architecture.md`.

- **Layout.** `DIETER_HOME/mail/<id>.json` holds header and state;
  `DIETER_HOME/mail/<id>.md` holds the body. Both are written with
  `fsx.WriteFile`.
  - Sending writes the body, then the header.
  - State changes rewrite only the small header.
  - An in-memory index, loaded at startup with `home.ListJSON`, serves list
    calls and the change stream. A body without a header is cleaned up when
    the index loads.
- **Mutations** use `home.BeginWriteKind(home.ConversationChange)`, like
  channels. `Finish` wakes `SubscribeChanges` subscribers.
- **Revision.** `Mail.Revision()` is a counter that every mutation bumps.
  `localChanges.refresh` rereads headers only when it changes, which mirrors
  the transcript revision check.
- **Bounds.** At most 2,000 messages and 128 MiB of bodies per daemon.
  When a send would exceed either, prune in this order:
  1. Trash
  2. Archived read messages, oldest first
  3. Read Inbox messages, oldest first

  Unread and flagged messages are never pruned. If nothing can go, the send
  fails with `ResourceExhausted` ("the mailbox on <machine> is full"). The
  daemon also purges the Trash after 30 days.

- **Lifecycle.** Mail outlives its sender card. Deleting a card or project
  doesn't delete its mail; the snapshot keeps it readable. Unenrolling or
  wiping the machine removes it with the rest of `DIETER_HOME`.

### 3.5 API

`api/proto/dieter/v1/mail.proto`. Timestamps are RFC 3339 strings, as in the
other services. Method names avoid collisions with other services in the
`TestGRPCAPIImplementsEveryDeclaredRPC` embedding.

```proto
// Agent mail: one-way Markdown reports for the account's user. Agent turns
// with mail access may only send; operators and devices read and organize.
service MailService {
  rpc SendMail(SendMailRequest) returns (MailHeader);
  rpc ListMail(ListMailRequest) returns (MailPage);
  rpc GetMail(MailRef) returns (Mail);
  rpc UpdateMail(UpdateMailRequest) returns (UpdateMailResponse);
  rpc DeleteMail(DeleteMailRequest) returns (DeleteMailResponse);
}

enum MailFolder { MAIL_FOLDER_UNSPECIFIED = 0; MAIL_FOLDER_INBOX = 1; MAIL_FOLDER_ARCHIVE = 2; MAIL_FOLDER_TRASH = 3; }
enum MailImportance { MAIL_IMPORTANCE_UNSPECIFIED = 0; MAIL_IMPORTANCE_NORMAL = 1; MAIL_IMPORTANCE_HIGH = 2; }

message MailSender {
  enum Kind { KIND_UNSPECIFIED = 0; KIND_AGENT = 1; KIND_OPERATOR = 2; }
  Kind kind = 1;
  string card_id = 2;
  string turn_id = 3;
  string scope = 4;          // "card" | "chat"
  string title = 5;          // conversation title when sent
  string project_id = 6;
  string project_name = 7;
  string schedule_id = 8;
  string schedule_name = 9;
  string harness = 10;
  string model = 11;
  string device_id = 12;     // operator over a remote route
  string label = 13;         // operator --from
}

message MailHeader {
  string id = 1;
  MailSender sender = 2;
  string subject = 3;
  string preview = 4;
  MailImportance importance = 5;
  string sent_at = 6;
  uint32 body_bytes = 7;
  string body_digest = 8;    // sha256; keys the client body cache
  bool read = 9;
  bool flagged = 10;
  MailFolder folder = 11;
  string state_changed_at = 12;
}

message Mail { MailHeader header = 1; string body = 2; }
message MailRef { string id = 1; }

message SendMailRequest {
  string subject = 1;
  string body = 2;
  MailImportance importance = 3;
  string operation_id = 4;
  string from = 5;           // operators only
}

message ListMailRequest { MailFolder folder = 1; bool unread_only = 2; bool flagged_only = 3; string before_id = 4; int32 limit = 5; }
message MailPage { repeated MailHeader messages = 1; bool has_more = 2; }

// Unset optional fields stay unchanged; folder UNSPECIFIED keeps the folder.
message UpdateMailRequest { repeated string ids = 1; optional bool read = 2; optional bool flagged = 3; MailFolder folder = 4; }
message UpdateMailResponse { repeated MailHeader messages = 1; }

// Permanent. ids or empty_trash.
message DeleteMailRequest { repeated string ids = 1; bool empty_trash = 2; }
message DeleteMailResponse { repeated string deleted_ids = 1; }
```

The ID lists in `UpdateMailRequest` and `DeleteMailRequest` are bounded at 500
per call. The core uses batches for "mark all read" and "empty Trash".

**`ChangesFrame` gets an owner-only mail section.** It follows the `privacy`
pattern:

```proto
  // Headers of the mail this machine holds, without bodies (GetMail).
  repeated MailHeader mail = 17;
  repeated string removed_mail_ids = 18;
```

- In `localChanges.refresh`, add `next["mail/"+id] = header` for each indexed
  header.
- Add the matching fields to the `localEntry` type switch, `addLocalChange`
  and `hasContent`.
- Size: 2,000 headers at roughly 700 bytes each is about 1.4 MiB on a reset,
  well inside the 8 MiB frame budget.
- After that, only changed headers travel. Marking one message read sends one
  header.

### 3.6 What the agent sees

`prompt.MailInstructions(cli)` is a fixed block. `ResolveForWorkspace` appends
it when `detail.Card.MailAccess` is set, next to the vault block, so the
64 KiB rendered cap still applies. Draft:

```text
## Mail to the user
You can send the user a read-only report in Dieter Mail. The user reads it
later and cannot reply; ask questions in this conversation instead.
  DIETER mail send --subject "Nightly audit: 3 critical" --body-file report.md
Write GitHub-flavored Markdown: headings, paragraphs, bold/italic/strikethrough,
inline code, links, ordered/unordered/task lists, block quotes, horizontal rules,
fenced code with a language, and tables (use column alignment; keep cells short).
No HTML, images or diagrams. Link workspace files by relative path. Bodies are at
most 128 KiB and 4,000 lines. Send one message per finished report, not progress
updates; at most 10 per turn. Use --important only for failures that need action.
Retry with the same --operation-id to avoid duplicates.
```

- `TestAgentInstructionsNameRealCommandsAndFlags` renders the block, by
  setting `MailAccess: true` on its detail, and checks every command and
  flag in it.
- `TestDefaultInstructionsRunTheDaemonsCLI` expects `mail send … --body-file`
  in the block when the flag is set, and expects it absent when the flag is
  not set.

### 3.7 The Markdown profile ("what our rendering supports")

Make the profile explicit, tested and identical on all clients.

| Construct                                                  | Profile                                                                                                                                                                                                                                         |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Headings H1–H6, paragraphs, hard breaks                    | yes, six visually distinct sizes                                                                                                                                                                                                                |
| Bold, italic, strikethrough, inline code                   | yes                                                                                                                                                                                                                                             |
| Links, autolinks                                           | `http(s)`, `mailto`; workspace-relative paths (below)                                                                                                                                                                                           |
| Unordered, ordered and nested lists (3 levels); task lists | yes; checkboxes are read-only                                                                                                                                                                                                                   |
| Block quotes (2 levels), horizontal rules                  | yes                                                                                                                                                                                                                                             |
| Fenced code with language                                  | yes, highlighted with the core `syntaxRanges` / the engine highlighter                                                                                                                                                                          |
| **GFM tables**                                             | header row; `:--`, `:-:` and `--:` alignment; inline formatting and links in cells; columns sized to content within min/max bounds; wrapping inside a column; **horizontal scrolling of the table alone** (never of the page); up to 24 columns |
| Raw HTML, images, footnotes, math, Mermaid/Vega            | **not in the profile.** HTML is shown as text. An image renders as its alt text plus a link and **is never fetched**. Diagram fences show as code.                                                                                              |

**Workspace links.** A relative or `file:` link resolves against the sender's
checkout on the sender's machine. The resolver is the core's
`ContentLinks.resolve`, so links stay inside the workspace. Opening one shows
the file in Files on that machine, at the line when the link has `#L12` or
`:12`. Operator mail has no workspace, so its relative links stay as text.

**Golden corpus.** Add `tests/fixtures/markdown/` with profile documents:

- one per construct;
- a 30-column table and a 1,000-row table;
- an edge case file with ragged rows, pipes in code and escaped pipes;
- the expected block tree as JSON.

The core parser test checks the trees. Mac and Compose snapshot tests render
the same files.

**Renderer work:**

- **Kotlin core** (`core/presentation/Markdown.kt`):
  - Extend `Markdown.parse` into the profile's full block and inline AST:
    ordered, nested and task lists; quotes; rules; table alignment; and an
    inline tree for emphasis, strikethrough, code, links and autolinks.
  - The inline tree replaces the regex in `RichText.kt:118`.
  - Export the AST through `client/rules`, so the Mac could adopt it for
    transcripts later (§7).
- **Compose:** a new `MarkdownDocument(blocks, linkHandler)` in `design/`.
  - Blocks are `LazyColumn` items, so a 128 KiB body doesn't compose all at
    once.
  - Tables use a custom `Layout`:
    - measure each column's max intrinsic width over the first 200 rows;
    - clamp it to 64–320 dp;
    - wrap cells inside the column;
    - honour alignment;
    - put the header on `palette.fill` with hairline row rules.
  - The table scrolls horizontally inside one `horizontalScroll`, with a fade
    edge while more columns are hidden.
  - Tables over 200 rows show "Show all N rows".
  - Code uses the core highlighter.
  - `RichText` for transcripts becomes a thin wrapper over the same blocks, so
    chats gain the improvements too.
- **Mac:** a new `MailMessageBody`, a read-only `NativeTextViewWrapper`
  (`isEditable: false`, `.fitsContent`) that reuses
  `NativeMarkdownControls.configuration`. Tables get content-fit widths and
  horizontal scrolling via `WideTableOverlay`. Two engine patches, recorded in
  `third_party/swift-markdown-engine/PATCHES.md`:
  1. Make links inside table cells clickable. They are drawn as raw source
     today (`MarkdownStyler+Tables.swift:499-503`).
  2. A presentation mode: a read-only view never reveals block source on
     selection or caret placement.

  Table text is drawn as an image, so the table context menu adds **Copy
  table as Markdown** and **Copy table as TSV**. The Mac transcript renderer
  doesn't change in this plan.

Keeping bodies at 128 KiB, 4,000 lines and 8 KiB per line keeps the Mac
engine out of its source-only fallback. It also bounds Compose layout work.

### 3.8 Kotlin core

Add a new package, `core/mail`. Every rule lives here; the apps only present.

- **Ingestion.**
  - `MachineReplica` adds `mail` to `OwnerData` and applies `mail` and
    `removed_mail_ids`. Headers are cached with the replica, so the mailbox
    renders on a cold start.
  - `AccountProjector` exposes `MailProjection`: every machine's headers with
    the machine's `stale` state.
- **Rules** (`MailRules`):
  - Folder membership; the Flagged and Unread views; per-folder counts and the
    unread total that drives badges.
  - Sort by `sent_at` descending, ties by ID.
  - Outlook date groups: Today, Yesterday, This week, Last week, then month
    names. Times show as "09:14", "Mon" or "12 Oct".
  - Display name and secondary line (§3.1).
  - Search over subject, sender, project and preview.
  - Filters by project, machine, sender (schedule or conversation) and
    importance.
  - Mark read when the reading pane shows the body (immediately, as in
    Outlook's default).
  - Stale labels for offline machines.
- **Commands.** These go through the journaled outbox with deterministic IDs.
  State updates are optimistic: an `UpdateMail` to an offline machine waits in
  the outbox, and the row shows the new state at once. Delete is too.
  "Empty Trash" and "mark all read" batch per machine.
- **Body cache.** An on-device record store keyed by
  `(daemon, id, body_digest)`.
  - LRU, at most 64 MiB.
  - Prefetches unread bodies from online machines, up to 8 MiB per sync, so a
    phone can read reports offline.
  - Cleared in `resetAccount` along with the other surfaces.
- **Open targets.**
  - `OpenTarget.Mail(daemon, id)` opens a message.
  - "Open conversation" resolves the sender card through the account view and
    is disabled when the card is gone.
  - Workspace links resolve through `ContentLinks` with the sender checkout.
- **Notifications.** `TransitionTracker` gets a `MailArrived(daemon, id)`
  event.
  - It fires only for headers that arrive on a frame from a machine that was
    already current, the same guard that keeps catch-up from replaying.
  - Content: title = display name; body = subject plus preview, gated by
    `result_previews`. Key `mail:<daemon>:<id>`; actions `OPEN`, `MARK_READ`,
    `ARCHIVE`.
  - New device setting `notifications.mail` (default on), plus
    `notifications.mail_important_only`.
  - The planner skips a message that is open on screen.
- **Client contract** (`client.proto`, next free numbers at the time of
  writing):

```proto
// Command oneof: MailCommand mail = 84;   Result oneof: MailResult mail = 47;
// Slice enum: SLICE_MAIL = 28;            Update oneof: MailSlice mail = 39;
message MailCommand {
  string scope = 1;
  oneof action {
    MailFolderChoice select_folder = 2;   // inbox | flagged | unread | archive | trash
    MailMessageRef select = 3;            // opens the reading pane, marks read, loads the body
    string search = 4;
    MailFilter filter = 5;
    MailStateChange change = 6;           // refs + read/flagged/folder
    MailRefs delete = 7;
    Step empty_trash = 8;
    Step mark_all_read = 9;
    Toggle active = 10;                   // screen visible: body prefetch, mark-read rule
  }
}
message MailSlice {
  repeated MailFolderRow folders = 1;     // title, symbol, unread, total
  string folder = 2;
  repeated MailSection sections = 3;      // date groups of MailRow
  MailReader reader = 4;                  // header, display fields, body blocks/source, state: loading|offline|error, open-conversation target
  int32 unread = 5; string unread_label = 6;
  string empty_title = 7; string empty_detail = 8;
  bool loading = 9;
}
```

- `MailRow` carries the rendered fields: display name, secondary line,
  subject, preview, time label, read, flagged, importance, stale, harness
  glyph and machine. Apps don't format anything.
- `ClientApi.observe` re-emits on account-view changes and on a minute tick
  for the time labels.
- The surface is registered in `Surfaces.kt` like channels.

### 3.9 Mac UI

Mockup: [`assets/agent-mail-mockup.html`](assets/agent-mail-mockup.html).

```text
┌ App sidebar ───────┬ Message list (ChatPaneSplit .mail, 320–460 pt) ┬ Reading pane ────────────────────────────────┐
│ Inbox           2  │ Inbox ▾                ⌕ Search     ⏷ Filter   │ ↩︎ Archive  🗑 Delete  ⚑ Flag  ✉︎ Unread  ⋯   │
│ Mail            4  │ TODAY                                         │                                                │
│ Channels           │ ▌Nightly dependency audit        09:14  !     │ Dependency audit — 3 critical, 7 outdated      │
│ Chats           5  │ ▌Dependency audit — 3 critical, 7 out…        │ ⏲ Nightly dependency audit · dieter · Studio   │
│ Terminals          │   Three packages have critical advisories…    │   Claude · Today 09:14      [Open conversation]│
│ Screens            │ ▌Migrate invoices                08:02        │ ───────────────────────────────────────────── │
│ …projects/boards   │   Invoice migration finished                  │ ## Summary                                     │
│                    │ YESTERDAY                                     │ | Package | Current | Latest | Severity |      │
│                    │   Weekly test flakiness            Fri    ⚑   │ |:--------|--------:|-------:|:--------:|  ⇆   │
│                    │   …                                           │ …                                              │
└────────────────────┴───────────────────────────────────────────────┴────────────────────────────────────────────────┘
```

- **Navigation.**
  - Add `AppSection.mail` (symbol `envelope`) and a `DieterNavRow("Mail")`
    right after Inbox in `SidebarPrimaryDestinations`. Its unread badge is
    `DieterCountBadge(count:tint: DieterTheme.action)`, observed in its own
    `SidebarMailCount` view so it redraws alone.
  - Add `store.openMail()` following the `openChannels()` pattern, a case in
    `DieterRootView.showsSynchronizedWorkspace`, and a `RetainedWorkspacePane`
    so the selection and scroll position survive switching away.
  - Command palette: "Open Mail", "Mark all mail read".
- **List column** (`MailList`):
  - The header has a mailbox menu (Inbox, Flagged, Unread, Archive, Trash,
    each with its count), a search field (⌘F) and a filter menu (project,
    machine, sender, important only).
  - Rows have three lines:
    - display name, with the harness glyph or a schedule clock;
    - the subject, bold while unread;
    - two lines of preview.
  - Trailing: time label, flag, a red "!" for important mail.
  - Unread rows get the blue leading bar Outlook uses.
  - Stale rows dim and say why.
  - Date groups use sticky section headers.
  - The context menu has the reading-pane actions. Multi-select (⌘/⇧-click)
    applies actions to every selected row.
- **Reading pane** (`MailReader`):
  - Toolbar: Archive, Delete, Flag, Mark unread, and a ⋯ menu with Copy
    Markdown, Export PDF/HTML (the existing `MarkdownFileExport`), and Open in
    New Window.
  - Header: subject (title2), sender avatar and name, the secondary line, the
    sent time, and **Open conversation**. Open conversation calls
    `openConversation(cardID:)` on the right machine; it is disabled with a
    tooltip when the card is gone.
  - Body: `MailMessageBody` in a readable column (max about 760 pt) that wide
    tables can scroll beyond.
  - Empty state from the slice ("No mail yet. Create a card or schedule with
    Mail access…").
- **Separate window.** `WindowGroup(for: MailMessageRef.self)` opens one
  message per window (⌘O or double-click). It suits wide reports and
  side-by-side comparison.
- **Keyboard** follows Apple Mail:
  - ↑/↓ moves the selection, Space scrolls the body.
  - ⌫ deletes (moves to Trash); ⌃⌘A archives.
  - ⇧⌘U toggles read; ⇧⌘L toggles the flag.
  - ⌘O opens in a window.
  - The commands live in a `CommandMenu("Message")` that is enabled only in
    Mail.
- **Creation toggles:**
  - `NewConversationSheet` gets a `LabeledContent("Mail") { Toggle("Allow the
agent to send you mail") }` below Vault
    (`accessibilityIdentifier("new-card.mail-access")`).
  - `StandaloneChatStartView` gets an `envelope` / `envelope.fill` toggle
    button next to the key (`chats.new.mail-access`).
  - `ScheduleEditor` gets "Allow mail" ("Runs may send you reports") under
    Vault (`schedule-editor.mail-access`).
- **Notifications.**
  - Add `UNUserNotificationCenterDelegate` to `CoreUserNotifications`. A tap
    resolves `OpenTarget` through the core and opens Mail with the message
    selected. The actions run `MARK_READ` / `ARCHIVE` without opening the app.
  - This also makes taps on today's card notifications open the conversation,
    which `SettingsPages.swift:104` already claims.
  - The Notifications settings page gets a working "New mail" toggle and an
    "Only important mail" toggle (both core settings). They replace the
    `.constant(true)` placeholders.
- **Menu bar extra:** a "Mail · 4 unread" row that opens Mail.

### 3.10 Android and iOS (shared Compose UI)

```text
Phone (list)                     Phone (message)                  Tablet ≥ 840 dp (two panes)
┌────────────────────────────┐   ┌────────────────────────────┐   ┌──────────────┬───────────────────────────┐
│ Inbox ▾            ⌕   ⏷   │   │ ←                 ↩︎  🗑  ⋯ │   │ Inbox ▾  ⌕ ⏷ │ ↩︎ Archive 🗑 ⚑ ✉︎  ⋯        │
│ TODAY                      │   │ Dependency audit — 3 crit… │   │ TODAY        │ Dependency audit — 3 crit… │
│ ● Nightly dependency audit │   │ ⏲ Nightly dependency audit │   │ ● Nightly…   │ ⏲ Nightly dependency audit │
│   Dependency audit — 3 cr… │   │   dieter · Studio · 09:14  │   │   Depend…    │ [Open conversation]        │
│   Three packages have …  ! │   │ [Open conversation]        │   │   Migrate…   │ ## Summary                 │
│   Migrate invoices         │   │ ## Summary                 │   │ YESTERDAY    │ | Package | Cur | Lat | ⇆  │
│ ←swipe: archive  read:swipe→│   │ | Package | Cur | Lat | ⇆ │   │   Weekly…    │ …                          │
├────────────────────────────┤   └────────────────────────────┘   └──────────────┴───────────────────────────┘
│ Inbox Projects Chats Mail⁴ Tools │
└────────────────────────────┘
```

- **Navigation.**
  - Add `MobileTab.MAIL` between CHATS and TOOLS (glyph `envelope`, empty
    detail "Select a message"). Mail is a primary, badged destination, not a
    Tools page. Five tabs is the comfortable maximum on both platforms; iOS
    fits five without "More".
  - Routes: `MobileRoute.MailList` (`root/mail`, `list = true`) and
    `MobileRoute.MailMessage(daemon, id)` (`mail/<daemon>/<id>`, detail
    pane).
- **Badges.** `MobileApp` shows the unread count on the bottom-bar Mail item
  and, newly, on rail items for both Inbox and Mail. On iOS:
  - `NativeNavigation` gets a `mailUnread` field.
  - `ShellController.specs` adds the fifth spec.
  - `MobileHost.kt`'s index mapping moves with it.
  - `ComposeHost` sets `tabBarItem.badgeValue` on the Mail tab.
  - `TabContainer.isList` already treats `root/` as list, so `mail/` routes
    land in the iPad split view's secondary column.
- **List** (`MailScreen`):
  - The top bar title is a mailbox dropdown (Inbox ▾ with counts), with
    search and filter actions.
  - Rows match the Mac content, with an unread dot instead of a bar.
  - Swipe actions follow Outlook mobile's defaults: swipe left to archive,
    right to toggle read. An undo snackbar follows each one.
  - Long-press enters multi-select.
  - Pull-to-refresh asks the core to resync stale machines.
- **Message** (`MailMessageScreen`):
  - The top bar has Archive, Delete and an overflow menu with Mark unread,
    Flag, Copy Markdown, Share, and Open conversation.
  - Share uses the platform sheet with the Markdown text. Android uses
    `ACTION_SEND` text/markdown; iOS uses `UIActivityViewController` through
    the host.
  - The header matches the Mac.
  - Body: `MarkdownDocument`. Workspace links push the existing
    `DocumentScreen` for that machine and path. External links open in the
    OS.
- **Tablets.** `TabStack` already gives list plus detail from 840 dp; the
  folder choice stays in the list header, so no third pane is needed. Between
  600 and 840 dp, phone navigation runs inside the rail layout.
- **Creation toggles:**
  - `CreationScreen`'s "Vault" section becomes **Access**, with two rows:
    "Allow vault access" and "Allow mail to you" (subtitle: "The agent may
    send you read-only reports in Mail"; `testTag("mail-access")`). The footer
    reads "Set only when creating."
  - `ScheduleEditor`'s Behavior group gets row 4, "Mail" ("Runs may send you
    reports"; `testTag("schedule-mail-access")`).
- **Store.** `MailModel` follows the `SchedulesModel` pattern:
  `observeAlways(Slice.SLICE_MAIL, "mobile-mail")` plus dispatch. It is built
  in `MobileStore` so the badge is live on every tab.

### 3.11 Notifications summary

| Platform | v1                                                                                                                            |
| -------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Mac      | Local notification per new message (core-planned), with tap routing and Mark read / Archive actions; Dock badge optional (D5) |
| Android  | Tab and rail badge only (no notification pipeline exists)                                                                     |
| iOS      | Tab and sidebar badge only                                                                                                    |

Mobile notifications need background sync, which Dieter doesn't have. That
is a separate project (§7).

### 3.12 Security and trust

- **One-way by construction.** Mail never enters a prompt and never starts or
  steers a turn. Agents can't read the mailbox, so mail is not a channel
  between agents or from an injected page into another conversation.
- **Capability, not isolation.** As with the vault, the flag guards against
  mistakes and records provenance; an agent with the user's file access could
  write `DIETER_HOME` directly. The threat model says so for the vault, and
  the mail section says the same.
- **No escalation** (§3.2). Turns cannot grant `mail_access` they don't hold.
- **Untrusted content.** Rendering never runs or fetches anything:
  - no HTML;
  - no remote images, which would be a tracking or exfiltration path from the
    reader's device;
  - only the profile's link schemes are clickable;
  - workspace links stay inside the sender's checkout;
  - a link's destination shows on hover or long-press.

  The Mac engine's diagram renderer is off in the read-only mail view.

- **Secrets.** Vault redaction applies to subject and body (§3.3).
- **Gateway.** Bodies travel only inside the end-to-end TLS tunnels; the
  gateway stores and sees nothing.
- **Agent restrictions.** Agents can't change trust or settings through mail.
  Every RPC except `SendMail` refuses a turn token.

### 3.13 Invariant impact

No invariant changes.

- Mail is owner-local conversation output, like transcripts and channels.
- It is not replicated, so peer register limits are untouched.
- It is never on the gateway.
- It goes through the daemon API under the writer lock with atomic writes.
- It has CLI parity on every route.
- Mail doesn't start turns, so "one active turn per conversation" and "agent
  messages never speak for the user" hold.

An ADR (0004, "Agent mail") records the decisions in §3.2–3.5. It also adds
one line to `invariants.md` under Execution: mail is one-way and never reaches
a prompt.

## 4. Plan

Each phase is releasable on its own and ships its tests and docs.

| Phase               | Scope                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Key files                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **0. Decide**       | Accept this proposal and ADR 0004; settle D1–D5; land the golden corpus and the profile table                                                                                                                                                                                                                                                                                                                                                                           | `docs/adr/0004-agent-mail.md`, `tests/fixtures/markdown/`                                                                                                                                                                                                                                                                                                                                |
| **1. Daemon + CLI** | `mail.proto` and `just generate`; `store/mail` (index, bounds, retention, Trash purge, revision); `MailService` handler and mounting; `mailCaller` and `capabilityCaller` (no escalation); `mail_access` on create, schedule and scheduler; `ChangesFrame` section; `MailInstructions`; vault redaction; `dieter mail send\|list\|show\|mark\|delete`, `--mail` on `card/chat create` and `schedule create/update`; `rpcCommand` mapping; CLI reference regen; SKILL.md | `api/proto/dieter/v1/{mail,cards,common,schedules,state}.proto`, `internal/store/mail/`, `internal/store/store.go`, `.golangci.yml`, `internal/api/{mail,service,conversation_snapshots,changes,changes_local,convert}.go`, `internal/engine/{conversation_creation,scheduler/scheduler}.go`, `internal/prompt/prompt.go`, `internal/cli/{commands,rpc_mail,rpc_cards,rpc_schedules}.go` |
| **2. Core**         | Replica ingestion, `MailProjection`, `MailRules`, outbox commands, body cache, `MailCommand`/`MailSlice`, `OpenTarget.Mail`, `MailArrived` notifications and settings, `CreationIntent.mail_access`, schedule draft field, capability gating                                                                                                                                                                                                                            | `core/{mail,sync,client,outbox,notifications,composition,schedules,navigation}/`, `client.proto`, `:core:apple` exports                                                                                                                                                                                                                                                                  |
| **3. Rendering**    | Core parser to the full profile AST, plus exports; Compose `MarkdownDocument` with table layout; `RichText` on top of it; Mac `MailMessageBody` and the two engine patches                                                                                                                                                                                                                                                                                              | `core/presentation/Markdown.kt`, `ui/…/design/{MarkdownDocument,RichText}.kt`, `apps/apple/mac/…/Features/Mail/Views/MailMessageBody.swift`, `third_party/swift-markdown-engine`                                                                                                                                                                                                         |
| **4. Mac**          | Section, sidebar badge, list, reader, window, keyboard menu, palette, menu bar row, creation and schedule toggles, flag chip, notification delegate and settings                                                                                                                                                                                                                                                                                                        | `apps/apple/mac/Sources/DieterMacKit/Features/Mail/`, `App/Store/*`, `Features/{Sidebar,Creation,Chats,Schedules,Settings}/`, `DieterKit/…/CorePlatformServices.swift`                                                                                                                                                                                                                   |
| **5. Compose**      | `MobileTab.MAIL`, routes, rail and bar badges, `MailScreen`, `MailMessageScreen`, swipe actions, share, creation and schedule toggles; iOS tab spec, badge and index mapping                                                                                                                                                                                                                                                                                            | `ui/…/{navigation,app,mail,creation,tools,store}/`, `apps/apple/ios/Host/…/ComposeHost.swift`, `ui/src/iosMain/…/MobileHost.kt`, Android share adapter                                                                                                                                                                                                                                   |
| **6. Docs + flows** | `site/content/docs/mail.md` (sending, the profile, limits, privacy); "Let agents send you mail" in the creation docs; vault doc cross-link; threat-model and architecture updates; seeded showcase mail for screenshots; Maestro flows                                                                                                                                                                                                                                  | `site/content/docs/`, `docs/{threat-model,architecture}.md`, `tests/maestro/{mac,mobile}/mail.yaml`, `tools/fixtures/`                                                                                                                                                                                                                                                                   |

Phases 1 and 2 can overlap after the proto lands. Phase 3 is independent of
both and can start at once. Phases 4 and 5 need 2 and 3.

## 5. Tests and verification

- **Go.**
  - Store: limits, idempotency, pruning order (unread and flagged survive),
    full mailbox refusal, Trash purge, orphan cleanup, revision.
  - API:
    - agent with and without access;
    - forged and expired tokens;
    - token after the turn ends;
    - agent refused on list, get, update and delete;
    - operator local and remote senders;
    - rate bounds across a restart;
    - redaction of a revealed vault secret;
    - no-escalation for card, chat and schedule creation;
    - `ChangesFrame` carries headers and removals.
  - Scheduler: copies `mail_access` and `vault_access`.
  - Prompt and contract tests (§3.6).
  - `TestGRPCAPIImplementsEveryDeclaredRPC` and the help-contract tests.
- **CLI e2e** (`-tags e2e`): one `assertMailCLI` helper for local, direct-TLS
  and relay routes (send as operator, list, show, mark, delete); an agent-path
  test with a real turn token; `--machine` refused inside a turn.
- **Kotlin.**
  - `MailRules` (groups, labels, counts, filters, display names).
  - Replica ingestion and removal.
  - An offline mark-read waits in the outbox and replays.
  - A catch-up frame doesn't notify.
  - Body cache bounds and digest invalidation.
  - Parser golden corpus.
  - `ClientApiEndToEndTest`: creating with `mail_access`, slice and commands
    against a real daemon.
- **Mac.** Unit tests for the `MailModel` fold and the table copy actions.
  Engine patch tests in the vendored package. A Maestro flow
  `tests/maestro/mac/mail.yaml` on a seeded fixture:
  - open Mail from the sidebar badge;
  - read a table report and scroll the table horizontally;
  - archive, flag, delete and restore;
  - open the conversation;
  - toggle Mail on a new card and on a schedule.
- **Compose.** `tests/maestro/mobile/mail.yaml` (Android emulator and iOS
  simulator): tab badge, list → message, the wide table scrolls without
  scrolling the page, swipe to archive and undo, the creation toggle.
- **Verification run:** `just check-changed --dry-run` first, then the
  selected suites once per phase.

## 6. Decisions

All five recommendations were accepted on 2026-10-25. For D5 the user added
that the phone and tablet apps show the unread count on the **Mail** tab.

| #   | Question                                             | Decision                                                                                                                                                                                                        |
| --- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Can scripts and cron (no turn) send mail?            | **Yes**, as an operator with `--from`. It is useful, and CLI parity tests over direct TLS and relay need it.                                                                                                    |
| D2  | Should the toggle be remembered between forms?       | **No**, as with vault. Off by default, chosen on purpose for each creation.                                                                                                                                     |
| D3  | Can mail access be switched on for an existing card? | **Not in v1.** Fixed at creation for cards and chats; editable on schedules.                                                                                                                                    |
| D4  | Naming                                               | Destination **Mail**, folders **Inbox / Archive / Trash** plus Flagged and Unread views; flag `mail_access` and `--mail`. "Inbox" inside Mail is scoped by the destination; the attention Inbox keeps its name. |
| D5  | Mac Dock badge with the unread mail count?           | **Optional setting, off by default.** The sidebar and menu bar already show it.                                                                                                                                 |

Where the implementation differs from the design above:

- **Mobile tabs.** The apps had gained a Channels tab the same day, so the tab
  bar shows six tabs: Inbox, Projects, Chats, **Mail**, Channels and Tools
  (decided 2026-10-25; the navigation will be reworked separately).
- **Sender names.** An agent whose card has no title and no schedule shows as
  "Agent on <machine>", not "Operator on <machine>".
- **Reader details** start with Card, Chat, Schedule or Operator.
- **Notification taps** while the workspace is still loading open the
  conversation once it arrives, following `OpenRequests`, instead of the Inbox.
- **Pruning** removes Trash messages whatever their state; outside the Trash,
  unread and flagged mail are never pruned.
- **`dieter mail list`** defaults to the Inbox; `--folder all` lists every
  folder.

## 7. Out of scope and follow-ups

- **Fix vault escalation** (§2.1) with the same `capabilityCaller` check.
- **Charts.** Vega-Lite and Mermaid in mail need a phone renderer or a
  daemon-side pre-render to an image. Revisit once attachments exist.
- **Attachments.** CSV and PDF files with a message, through the bounded
  file-transfer path.
- **Mobile notifications.** These need background sync and a push design that
  keeps the gateway free of content.
- **Mac transcript on the core parser.** Retire `ConversationMarkdownParser`
  for the shared AST, and give transcript tables content widths and
  horizontal scrolling.
- **Inbox rules for mail.** Auto-archive or auto-flag by sender, reusing the
  Inbox rule model in shared KV.
- **Threads.** A "living report" that a schedule updates instead of sending
  a new message each run (`--thread KEY`).
