# Changelog

Dieter ships one version across the daemon/CLI, gateway and native clients.
Nightly dev prereleases (`v0.7.N`) list their pull requests on the GitHub
release. A stable release promotes one tested dev build; before you promote it,
copy the **Unreleased** notes into a section named after that exact version
(for example `## 0.7.447`). Promotion fails without that section.

## Unreleased

Nothing yet.

## 0.7.457

### Added

- **Oh My Pi on your Claude and ChatGPT accounts, with an advisor.** Oh My Pi
  now runs on the same provider accounts as Claude Code and Codex. It no
  longer uses its own logins, models or configuration.
  - Choose a Claude or GPT-6 model; the account picker follows the model's
    provider. Model, thinking, advisor and account can change between turns.
  - Pick an **Advisor**: a second model, on either provider, that reviews the
    work and adds notes. Choose its thinking, and its account when it uses the
    other provider.
  - Claude logins need **Allow Oh My Pi to use this login** in **Settings ›
    Providers** (or `dieter provider omp-access ACCOUNT on`). It is off by
    default: Anthropic does not permit Claude.ai logins in third-party tools,
    and accounts used this way may be blocked. Dieter hands Oh My Pi only
    short-lived access tokens, and Claude Code keeps refreshing the login.
  - See [Agents › Oh My Pi](https://getdieter.com/docs/harnesses/#oh-my-pi) and
    [Providers › Oh My Pi access](https://getdieter.com/docs/providers/#oh-my-pi-access).

- **A code reviewer for your agents.** Choose a reviewer once for your
  account: a harness, model and depth in **Settings › Code reviewer**, or with
  `dieter reviewer update`. Then switch on **Code review** when you create a
  task, chat or schedule, or later in the conversation. When its change is
  complete, the agent asks this second model for a review, fixes the findings
  it agrees with and explains the ones it rejects.
  - Each review appears in the conversation. Findings come with severity,
    file and lines (open the diff in Changes) and a suggested fix.
  - A second review marks findings resolved, still open or new.
  - Choose **Review changes** in Changes, or run `dieter card review CARD --wait`,
    to start one yourself.
  - Reviews run on your machine, on your provider accounts, on a disposable
    snapshot of the workspace that the agent's work never touches. See
    [Code review](https://getdieter.com/docs/code-review/).

### Changed

- **Existing Oh My Pi conversations continue in a new Oh My Pi session.** Their
  earlier turns stay in Dieter's transcript. Custom models from
  `~/.omp/agent/models.yml` are no longer offered.

- **The Mac and iOS apps are built with Xcode 27.2** and link the iOS and macOS
  27.2 SDKs. Supported systems are unchanged: iOS 18 and macOS 26 or later.

## 0.7.455

### Changed

- **Android: the redesign shipped in 0.7.454 is withdrawn.** The app looks and
  moves as it did in 0.7.453 again: the docked transcript, the plain message
  card, the flat two-pane layout on foldables and the earlier transitions. The
  Inbox refresh fix and the updated dependencies of 0.7.454 stay.

### Fixed

- **Claude turns no longer strand on questions or background waits.** Claude
  sessions no longer get the question, monitor, scheduling and workflow tools
  Dieter cannot answer or keep alive, so an agent asks in its reply and waits
  in the foreground instead of pausing the turn or ending the chat. A Claude
  subagent that is resumed shows up as a subagent again.

## 0.7.454

### Changed

- **A more alive Android app.** Pages slide and settle into place, tabs pass
  each other in order, cards and buttons give under your finger, the chosen
  tab pops, and list rows and board cards move into place instead of
  jumping. The creation sheet rises in, and empty pages settle their tile in.
- **A clearer chat window on Android.** A run of tool calls is one card with a
  rail: each call shows what it does (read, search, edit, shell, web, agent,
  git) and whether it is running, done or failed. The agent's reasoning sits
  behind **Thinking**. Your messages are bubbles with a tail and a soft
  gradient. While the agent works, typing dots and a shimmering activity line
  replace the spinner, the message field glows, and a **New output** pill
  brings you back when you scrolled away.
- **Foldables and tablets** show a list and what you open from it as rounded
  panels on a darker canvas, in light and dark, portrait and landscape. The
  glass navigation floats under the list panel.
- **Android desktop layout**: the conversation panel uses the floating message
  card, and panes and sheets ease in. Project avatars carry a light, and board
  cards show a coloured rail while they run, wait or fail.
- **The Inbox refreshes as soon as you open the app.** Coming back from the
  background, Android and iPhone could reuse a network connection that had
  died while the app was away, so the Inbox kept showing what it knew when you
  left until that connection timed out. Every reconnect now starts on fresh
  connections and needs fewer round trips before your machines answer.
- **Rows say when they are refreshing.** Until its machine has answered, an
  Inbox row shows a small spinning mark next to its time and light sweeps
  across its second line. A row whose machine is offline or not responding
  says so instead. The Mac and the Android desktop shell show the same mark.
- **Codex subagents appear in the Subagents tab**, with their task, model,
  status and results.
- **Worktree conversations work in empty repositories**: the first work
  becomes the repository's first commit (squash, fast-forward or merge), and
  Changes shows initial commits.
- Codex conversations whose earlier provider history is missing after the
  provider-account change continue on a fresh thread and say that earlier
  context is unavailable, instead of failing.
- OMP 19 ends processes an agent started in the background with `&` when its
  session ends.
- Updated dependencies: Go 1.27.4, Claude Code 2.1.332, Codex 0.172.0, OMP
  19.2.1, Pi 1.6.1, the AI SDK harness adapters, Bun 1.4.5, Gradle 9.9.2,
  Android Gradle Plugin 9.5.3, Compose 1.13, SwiftNIO 2.105 and SwiftProtobuf
  1.41, Fastlane 2.242 and the build tools.

## 0.7.452

### Fixed

- **Android: swiping along the navigation no longer closes the app.** The
  selection lens grew with every move of your finger until the app crashed,
  even on an accidental swipe. It now keeps its size and stops at the first
  and last tab.
- Android: wide badges such as "99+" on More are no longer cut off, and a
  coloured row passing under the glass bar no longer tints the selected tab.

## 0.7.451

### Changed

- **Android navigation floats as liquid glass.** The tabs float above the
  page in a glass bar, with the page's main action (New task, New chat) as a
  round button beside it. On an unfolded foldable the bar stays under the list,
  so a conversation's message field reaches the bottom of its pane; in
  landscape it stands on the left edge. Drag along the bar to slide between
  tabs; it shrinks while you scroll down. **Settings › Appearance ›
  Navigation** offers Lens (the default), Dock, Island and Classic.
- **A clearer message field on Android**: it floats above the reply as a
  raised card with the agent, the context in use and send inside it, and its
  outline takes the accent colour while you type. **Settings › Appearance ›
  Chat input** offers Card (the default), Glass and Classic.
- **One list style on phones and tablets**: Inbox, Chats, Projects, Mail,
  Channels, Terminals, Schedules, Folders, the iPhone More page and Devices
  share the Inbox's look: small titles with a status line, a search button
  instead of permanent search fields, slim section headers and full-width
  two-line rows. Pausing a schedule, removing a device, restoring from a
  folder's trash and resolving a folder conflict moved into the row's
  long-press menu.
- Long-press menus on Inbox rows open where you pressed instead of against the
  screen edge.
- Changes update live: the daemon pushes them as they happen instead of every
  open view polling. New `dieter workspace watch-changes` streams them.
- A worktree conversation's Changes list the commits its branch made and line
  counts for every file, so committed work no longer looks like "no changes".
- Review comments belong to the version of the file they were written on;
  once the file changes they are counted as outdated.
- `dieter workspace run` pins exactly the files it acts on (`--expect
PATH=REVISION`, automatic by default); `workspace diff` and `workspace
comment` no longer take a changeset revision. `--project p_…` no longer
  looks up every project first.
- Compatibility floors are `0.7.449`: update every daemon and app together.

### Fixed

- **Changes in every conversation.** A conversation that works in the project
  directory now shows its changes in place on the Mac, iPhone, iPad and
  Android (and with `dieter workspace changes CARD`), labelled **Shared
  checkout**. Before, Android and iOS failed with "project-directory changes
  are project-scoped" and the Mac showed a redirect. Chats get Changes on
  mobile too.
- **Changes keep working while agents write.** Diffs no longer fail because
  another file changed. Staging, unstaging and discarding fail only if a file
  you picked changed, and say which; a commit takes exactly the staged changes
  you reviewed. While an agent works in a shared checkout, Changes says
  **Agent working · changes update live**; only discarding and updating the
  branch wait for it.
- Worktree reviews on Android and iOS no longer show a false "conflicts with
  main" banner.

## 0.7.448

### Changed

- **Inbox**: every platform lists the same sections, Needs you, Running, Pinned
  and Recent, newest first within each. A pinned conversation that needs you or
  is running stays in that section with its pin and returns to Pinned once it
  is idle. Failed agents now count as needing you (in the Inbox, the badges,
  widgets, the Mac island and the menu bar) until you retry them, finish the
  card or archive it, and the Inbox can finish a failed card.
- **Inbox on Android, iPhone and iPad**: two-line rows with the project, title,
  time, what the agent is doing or said last and one status mark, under slim
  section headers. The count tiles and the usage strip are gone; the filter
  menu shows All, Needs you, Running, Pinned and Review with their counts, and
  plan usage stays under More › Providers.
- **Inbox on the Mac**: one line per conversation with its status, title,
  working subagents, project and age; count segments above the timeline; pin
  and finish on hover; search with ⌘F.

## 0.7.447

### Added

- **Provider accounts**: sign in to several Claude and ChatGPT subscriptions
  from the Mac, iPhone and Android apps or the CLI, for any of your machines,
  and choose the account each chat, card and schedule runs on (or a default per
  provider). Settings › Providers lists every account with each machine's
  sign-in state and its plan usage: the 5-hour and weekly windows, reset times,
  credits and the tokens Dieter's own turns used. Sign-in uses the provider's
  own login (Claude Code for Claude; Codex device code or Sign in with ChatGPT
  for ChatGPT); open the link on any device and paste the code back. Accounts,
  sign-in state and usage sync between your machines; credentials never leave
  the machine that signed in, and Dieter never reads Claude credentials. From
  the CLI: `dieter provider list|add|login|usage|default …` and `--account` on
  card, chat and schedule commands. See the
  [provider accounts guide](site/content/docs/providers.md).

### Changed

- Release line 0.7: the gateway's compatibility floors are `0.7.0-dev.0`.
  Update every daemon and app before the gateway; 0.6 daemons and apps are
  refused once the gateway runs 0.7.
- Plan usage now comes from each account instead of the gateway: the gateway
  stores no provider data, and the old Usage pages are replaced by Settings ›
  Providers.
- Existing logins keep working: a machine's own `~/.claude` and `~/.codex`
  logins are adopted as accounts. Codex turns now keep their state in
  `DIETER_HOME/codex`, so Codex conversations started before 0.7 start a new
  session on their next message.

### Fixed

- Quick task titles work again for new cards; since late October they kept
  their fallback title because Codex rejected the title request.

## 0.6.446

### Added

- **Synced folders**: named directories that Dieter keeps the same on your
  machines and phones. Daemons sync with each other through the gateway's
  encrypted carriers; Android phones and iPhones sync with one daemon, in the
  background on a schedule you choose (interval, Wi-Fi only, power, storage
  limit, automatic download size). Concurrent edits keep a conflict copy, a
  replaced or deleted file goes to the folder's trash on every daemon, and a
  mass deletion waits for confirmation. Macs keep a copy through their daemon;
  the Mac app manages folders and reveals the copy in Finder. A folder linked to
  a project tells that project's agents its path. From the CLI:
  `dieter folder create|attach|status|trash …` and `dieter file cp --folder`.
  See the [synced folders guide](site/content/docs/synced-folders.md).

### Changed

- Daemons below 0.6.446 are refused: they cannot read synced folder records.
- Coding agents can automatically create, start and continue Strix scans.
  Direct channel messages with `--wake` can start idle scans within the normal
  wake budget, and failed admission leaves the request pending. Worktree-only
  execution, model credential handling and the headless no-steering limit
  remain in place.

## 0.6.445

### Added

- **Strix security scans.** The new **Strix** harness runs the open-source
  [Strix](https://github.com/usestrix/strix) pentesting agent against a card's
  worktree: its agent team, tool calls, todo list and validated findings appear
  in the conversation, and a completed scan ends with its report. A follow-up
  message continues the same scan. It needs Docker on the execution machine and
  a vault item with the model API key (named `strix` by default); Dieter
  installs the pinned Strix 1.7.1 on first use. Scans run only in worktrees,
  stop at a budget (default $10), and only a person can start or message one:
  agent turns and channel messages cannot. See
  [Agents & models](https://getdieter.com/docs/harnesses/#strix).

### Changed

- File transfers between machines are much faster. `dieter file cp` and
  `dieter file sync` keep eight chunks of each file in flight instead of one,
  the WebRTC route negotiates an 8 MiB window instead of 256 KiB, and relayed
  transfers send full 64 KiB frames. Over a TURN path with a 54 ms round
  trip, a 64 MiB copy went from about 2 MiB/s to 33 MiB/s up and 44 MiB/s
  down. Both machines need this release; relayed transfers also need the
  updated gateway. The native apps keep their current WebRTC window.

### Fixed

- Downloads no longer sync every chunk to disk or copy the finished file
  again, and a damaged partial download now restarts on the next run instead
  of asking you to delete it.
- Go 1.26.11 (the gateway image builds with Go 1.27.4) fixes GO-2026-6859, an
  HTTP server crash.

## 0.6.442

### Added

- **Delete worktrees when archiving**, a project setting that is off by
  default, on the Mac, Android, iPhone and iPad. From the CLI:
  `dieter project update --delete-worktrees-on-archive=true PROJECT`. When a
  conversation is archived, the machine that runs it removes its clean, idle
  worktree; turning the setting on also cleans up existing archives. Branches
  and conversation history stay, and restoring recreates the committed files,
  but ignored files, dependencies and build output are deleted. Worktrees with
  uncommitted or in-progress work are kept.
- Projects are ordered by their latest chat or card activity. On the Mac, drag
  a project in the sidebar or use **Move up** and **Move down** in its menu to
  keep your own order; the Projects header's order menu returns to **Recent
  activity**.

### Changed

- Agent channels are always on: every project has a channel and every agent
  turn can use it. The opt-in switches are gone: **Settings → Experimental →
  Agent channels** on the Mac, Android, iPhone and iPad, the project and board
  overrides, and `dieter channel settings`.
- The Inbox on Android, iPhone and iPad leads with running work, followed by
  Pinned, Needs you, Review and Recent. Tiles at the top count running work,
  replies that need you and cards ready for review, and filter to them. Swipe
  a card right to mark a reply read, finish a review or pin it, and left to
  archive it (with undo) or stop a running agent. The Android desktop Inbox
  uses the same order.

### Fixed

- Queued messages on Android, iPhone and iPad stay pinned above the input
  while the conversation scrolls. **Send now**, **Edit** and **Remove** wait
  until the machine has the message, and the queue shows when a message is
  waiting, sending, stopping the agent or failed.
- A synced record that a machine cannot verify, such as one signed by a
  machine that never joined the device roster, no longer stalls every later
  change from that peer. That stall could leave a project missing on one
  machine and create a duplicate when it was opened there. Such records are
  held, checked again every sync round and listed under `held` in
  `dieter peer status`.
- **Run on** no longer lists checkouts of machines that left the account.

## 0.6.441

### Fixed

- Screen-sharing keyboards suppress autocomplete on Android and inline
  predictions on iOS, preserving the text sent to the remote desktop.

## 0.6.440

### Changed

- Updated the bundled Claude Code, Codex, Pi and OMP agents and their adapters.
  Managed Bun is now 1.4.4, supporting the updated OMP executable.
- Updated shared Kotlin libraries, networking dependencies and build tools.

### Fixed

- Cancelling a relay connection discards queued writes so its endpoints can
  close cleanly.

## 0.6.439

### Fixed

- **Workspace file links open in the mobile apps.** On Android, iPhone and
  iPad, file links in conversations and Markdown previews now open through
  Files in the owning workspace. Relative links resolve from the document's
  folder, and image and PDF links open native previews automatically.
- Conversations show the latest file or page an agent explicitly presents.
  iOS also reports failures to open links or attachments.

## 0.6.438

### Fixed

- **Screen sharing works from Ubuntu and other GNOME Wayland desktops.**
  Connecting to a Linux machine running a current desktop portal (Ubuntu 26.04,
  GNOME 50) failed every time with "portal did not return a session handle".
  The host now shows the desktop's approval prompt on its own screen; approve it
  once there, and Dieter asks the portal to remember it so later connections
  can start without a prompt.
- **The first connection to a Mac screen no longer fails** with "Unknown native
  stream" when you take control. Connecting again used to work; now the first
  attempt does.
- Linux screen shares keep the desktop's aspect ratio instead of stretching it
  to the viewer's window, so clicks land where you see them.

## 0.6.437

### Added

- **Android on a desktop.** In Samsung DeX, Android desktop windowing and on a
  connected display, the Android app switches to a desktop layout modelled on
  the Mac app. A sidebar holds Inbox, Mail, Channels, Chats and Terminals, your
  projects with their running work, and your machines and quotas. Boards show
  every lane side by side with the open task beside them and a tab for each of
  its panes. Lists, menus and dialogs are denser; rows react to the pointer,
  right-click opens a card's menu, and cards drag between lanes. Ctrl+K searches
  tasks, chats, projects and commands; Ctrl+N starts a task, Ctrl+1 to Ctrl+5
  switch sections, Ctrl+B shows or hides the sidebar and Ctrl+W closes the open
  task. **Settings → Appearance → Interface** chooses Automatic, Desktop or
  Touch.

### Changed

- The Android app keeps its screen when its window is resized, moved to
  another display or switched into DeX, instead of starting it over.
- Android's More sheet shows four equal tiles in one row: Channels,
  Terminals, Devices and Settings. Provider usage stays on the Inbox (and in
  the More page's list), so no tile is taller than the others.

### Fixed

- **The Mac app no longer burns a CPU core while agents work.** Each working
  agent's machine streams its progress several times a second, and every one of
  those updates rebuilt the whole account view and compared it with the last
  one card by card. With many cards the app ran at 100–150% CPU and could stop
  responding. Updates now reach the views at most four times a second, cards
  that did not change are not compared again, and machines send a working
  agent's progress at most four times a second. The Android and iPhone apps
  share this code and use less battery while agents work.
- The working indicator at the end of a running conversation animates at up to
  30 frames a second instead of at the display's refresh rate.

## 0.6.433

### Changed

- **Mail** is back in the navigation bar on Android, iPhone and iPad, next to
  Inbox: Inbox, Mail, Projects, Chats and More. Its badge counts unread mail;
  More's counts unread channel messages.
- On Android tablets and unfolded foldables, drag the handle between the list
  and the open page all the way to one side to hide that pane on every screen.
  Without the list, whatever you open fills the screen (a conversation hides
  the navigation bar, as on a phone) and back returns to the list; without the
  open page, the list fills the screen until you open something. The handle
  stays at the edge to pull the pane back, a double-tap restores both panes,
  and the app remembers the choice.

## 0.6.432

### Changed

- Android, iPhone and iPad navigate with four destinations: **Inbox**,
  **Projects**, **Chats** and **More**. On Android, More slides up a sheet above
  the navigation bar with Mail, Channels, Terminals, Usage, Devices, Settings
  and every machine (with a screen shortcut); on iPhone and iPad it is a tab
  with the same entries. Its badge counts unread mail and channel messages, and
  iPhone now reaches Channels too.
- Tools open where their scope is, so they never show whichever project was
  opened last. A project's page opens its Files, Changes and Schedules; tapping
  one of its checkouts opens that machine's copy, and a **Checkout** menu
  switches between checkouts. Their titles name the project and machine. A
  machine's page shows its screen, its terminals (with **New terminal** on that
  machine) and the projects checked out on it, and Terminals in More groups
  shells by machine.
- Android tablets and unfolded foldables such as the Galaxy Z Fold show lists
  beside their detail from 600 dp wide. Drag the handle between the panes to
  resize them or double-tap it to reset; the app remembers the split.

### Fixed

- Pins and other navigation edits made on a phone reach your other devices
  again. Edits now go to the next machine that is up to date when the first one
  the phone tries is behind or busy, instead of waiting on it indefinitely.
- Tapping a channel message in a conversation opens the channel above the
  conversation on every device, including iPhone.
- A task's Processes pane lists the processes of the task's own project.

## 0.6.431

### Fixed

- Mail charts on the Mac and iPhone now blend with the reader in light and dark
  appearance. Charts with an explicitly white background keep that background,
  and selected Mac mailbox rows remain readable.
- Mac Mail and Files keep chart text and paths sharp in large reports. Bounded
  parallel rendering, faster source lookups and cached chart reuse reduce
  rendering time and speed up reopening messages.
- Wide tables in Mac Mail stay below their headings when charts finish loading,
  including after scrolling, changing appearance and reopening a message.
- Android Mail keeps its reader background stable during fast scrolling, and
  the Inbox title now aligns with the toolbar actions.

## 0.6.430

### Added

- Mail reports render Mermaid diagrams and inline-data Vega-Lite and Vega
  charts on the Mac, Android, iPhone and iPad, using the same bundled offline
  renderer as the Mac Files preview. Graphics fit narrow screens and follow
  the app's light or dark appearance; Mac PDF and HTML exports keep them as
  static graphics.
- Invalid or unsupported diagrams keep readable source without hiding the
  rest of the report. Remote images, external chart data and scripts remain
  blocked; charts use inline data and their controls are read-only.

## 0.6.429

### Added

- **Mail**: agents can send you read-only Markdown reports, such as a nightly
  audit or a finished migration, and you read them in a new mailbox on the Mac,
  Android, iPhone and iPad. Agents send with `dieter mail send` from cards,
  chats and schedules created with mail access (`--mail`, or **Allow mail** in
  the new-task, chat and schedule forms); a conversation without it can't send
  or grant it. Mail stays on the machine that received it, with unread, flag,
  archive and trash state, search and filters, and Mac notifications whose tap
  opens the message. Reports render rich tables that scroll sideways; see the
  [Mail guide](https://getdieter.com/docs/mail/).
- Notification clicks on the Mac now open the card or chat they belong to.

### Changed

- Android, iPhone and iPad have a **Mail** tab with unread badges. The iPhone
  tab bar keeps five tabs, so the experimental Channels tab is not shown there
  for now.
- Chats and cards you reopen show their messages at once and mark themselves
  **Refreshing** until the owning machine has caught up.

## 0.6.428

### Added

- Agent channels (experimental) are account-wide: a project has one channel,
  shared by all your machines. Messages, delivery receipts, pins and file
  claims travel between machines with peer sync, end to end encrypted; the
  gateway stores none of it. Each machine delivers to the agents it runs, and
  another machine's claims show as advisory ("also being changed … on machine
  M"), since they block writes only in their own checkout.
- `@here`: a person's post with `dieter channel post --here`, or **@here** in
  the composer, interrupts every running agent of the project on every
  machine.
- Android and iOS have a **Channels** tab with an unread badge. It lists the
  project channels; a channel shows the agents' messages live, with a composer
  for Everyone, @here or picked agents, and an info sheet with member agents,
  claims (with Release) and pinned decisions. **Settings → Experimental** has
  the switch.
- Android and iOS highlight a channel message that joined an agent's turn, like
  the Mac, with its author, channel and a link to open it, and label a turn
  that a channel message started **From agent channels**.

### Changed

- A channel post without recipients no longer interrupts running agents; they
  read it when their next turn starts (posts from the last 24 hours). Direct
  messages and @here still reach running agents at once. Done and archived
  cards are no longer channel members.
- `dieter channel inbox` marks messages delivered only on the machine that
  runs the card; on another machine, add `--peek` or `--machine`.
- Turning agent channels on or off saves on the next reachable machine when
  one cannot, for example when this device is not yet trusted there.

## 0.6.427

### Changed

- Updated the bundled agents: Claude Code 2.1.310 (Agent SDK 0.3.310), Codex
  0.164.0, Oh My Pi 18.12.6, Pi 1.4.0 and DSH 0.2.1-rc.2. The AI SDK harness
  adapters move to the newest releases that start (harness 1.0.158); the newer
  Claude Code, Codex and ACP adapters were published without a file their
  setup reads and stay held back until a fixed release.
- A machine stays responsive while many agent turns run at once: running turns
  write to the daemon's storage only when their state changes, and repeated
  reads share a small cache. The Homebrew service now uses Standard instead of
  Background scheduling; `brew services restart dieter` applies it after an
  upgrade (this restarts the daemon).

### Fixed

- DSH lists its models again. Model discovery looked for DSH in the wrong
  directory, so apps showed only a default model.
- A late or duplicate quota reply no longer disconnects a machine's control
  connection.

## 0.6.426

### Changed

- Agents get shorter, precise instructions on every turn, the same for every
  harness. They name the card or chat and the daemon's own `dieter` binary by
  absolute path, so an older `dieter` earlier on the `PATH` can no longer run
  instead, and send agents to `dieter --help` for everything beyond the
  essentials. Nothing is said twice any more, and the follow-up card command
  now includes its required `--title` and `--workspace`. When a harness has not
  loaded the presentation or background process tools, their instructions name
  the equivalent `dieter` command, and they ask agents to open a file in the
  workspace pane when you want to see it instead of printing it.
- Prompt templates you have not changed follow each release's defaults; saving
  settings no longer freezes the defaults of the release you saved them with.
  `dieter prompt update --reset template|board-skill|chat-skill` restores a
  replaced default, and `dieter prompt preview --card CARD` shows a
  conversation's exact instructions.

### Fixed

- Turning agent channels on in the app lists the project's channel right away;
  before, the list could stay empty for up to a minute.
- `dieter chat` help shows `dieter chat … CHAT` instead of the card commands,
  and chats no longer offer `start`, `labels`, `--lane` or `--labels`.
  `dieter chat list --project` now filters by project instead of being ignored.
- CLI help names the flags machine actions need (`--name`, `--confirm`), the hex
  format of `board label --color`, what `card context` and `card archive` do,
  and the `--direct-network` option of `daemon start`; the `project`, `board`,
  `workspace`, `screen resolution`, `kv` and `peer` help is corrected.
  `card context` also returns the card title, and `board label list` prints
  `[]` for a board without labels.

## 0.6.425

### Added

- Agent channels (experimental, off by default): agents working in the same
  project on one machine share a channel. They post notes, requests, done
  messages and decisions, and Dieter delivers them into a running agent's turn
  or ahead of an idle agent's next prompt. A direct message can wake an idle
  agent, within a budget of 4 wakes per agent per hour. Files an agent changes
  are claimed until its turn ends: Codex is stopped before it writes another
  agent's claimed file or commits it, and other agents are warned right after.
  Turn it on in **Settings › Experimental** on the Mac, and override it per
  project in **Project context** and per board in board settings. The
  setting syncs to every machine. The Mac app has a **Channels** section with
  the messages, claims, member agents and pinned decisions; the CLI has
  `dieter channel`. See [Agent channels](https://getdieter.com/docs/channels/).

## 0.6.423

### Fixed

- Returning to the Android or iOS app no longer marks every Inbox row's
  machine as not responding while the app reconnects. A machine is only
  reported offline or not responding for what happens while the app is
  connected.
- An open conversation keeps updating across reconnects. Before, it could
  stop refreshing without saying so after the app returned from the
  background, until you reopened it.
- Android keeps its connection when the screen rotates or the theme changes,
  and iOS keeps it while Control Center, the app switcher or a system prompt
  covers the app.
- The Mac app exports Markdown to PDF and renders Mermaid and Vega diagrams
  again. Markdown files open in Files and conversation tabs reload when they
  change on disk; unsaved edits stay and offer **Reload from Disk** or
  **Overwrite Disk**.
- Go 1.26.10 fixes GO-2026-6809 in `crypto/x509`.

## 0.6.421

### Added

- Inbox rules show or hide conversations by project and label. Open **Inbox
  rules** from the filter button on the Mac or the filter menu on Android and
  iOS. A rule hides the matching conversations or shows only them, can require
  a project and a label together or accept either, and can be switched off
  without deleting it. A conversation matching any hiding rule is left out;
  while a showing rule is on, only matching conversations are listed. Rules
  sync across your account, apply to the Inbox, widgets, island and menu bar,
  and the Inbox says how many conversations they hide.

### Fixed

- Saving a project or board on Android no longer fails: the project sheet now
  edits the project's agent instructions (it showed the template override
  before), and the prompt template override is a separate, validated field
  that is sent only when you change it.
- On the Mac, the project context sheet saves your instructions without
  waiting on workspace settings you did not change and shows a failed save in
  the sheet. Project and board prompt overrides in Settings explain what the
  daemon rejects before you save.
- Claude turns that stop on an expired sign-in resume once after the token
  refreshes instead of failing.

## 0.6.420

### Changed

- Inbox cards on Android and iOS lead with their project's color and
  initial and carry a status badge: a pulsing dot while the agent works, a
  dot for replies, an eye for review, a check for finished work and a cross
  for failures. Cards that need you, are running or wait for review are
  tinted in their status color, and **Mark done** is a compact chip beside
  the status.
- Pin Inbox cards to keep them in a **Pinned** section at the top on Mac,
  Android and iOS. Pins follow your account through shared KV and sync once
  a machine is reachable; search and project filters still apply.
- Updated the bundled agent tools (Claude Agent SDK, Codex, Oh My Pi and the
  AI SDK harnesses), WebRTC M155 on Apple and Android, and the Go, Swift,
  Kotlin, npm and Ruby dependencies.

### Fixed

- The Mac app refreshes its sync when you switch back to it, and Inbox rows
  no longer keep stale content after they move to another section.

## 0.6.418

### Fixed

- Large Markdown files on Mac open as fully editable source, avoiding expensive rich layout and keeping multi-megabyte documents usable in Files and conversation tabs.
- Syntax highlighting limits work for large files and unusually long lines, cancels stale requests, and avoids repeated work when switching tabs.
- File navigation preserves selection and undo history; reloaded files refresh their highlighting. Opening a Markdown context menu no longer renders rich clipboard content unnecessarily.

## 0.6.416

### Fixed

- Screen sharing on Mac and Android recovers automatically when the initial
  signaling connection is interrupted, without requiring a second Connect.
- Connecting to a Mac desktop gives a cold capture helper enough time to wake
  the display before reporting a startup error.
- Active screen sharing keeps its video connection while signaling reconnects.

## 0.6.415

### Fixed

- Task creation remembers your project, board, workspace, checkout and agent
  choices, including when you close the form without creating a task. Submitting
  immediately after changing an option uses the latest selection, and an explicit
  Default effort stays selected.
- Android option pickers use readable, scrollable dialogs that mark the current
  selection instead of narrow dropdown menus.

## 0.6.413

### Changed

- New `dieter file cp` and `dieter file sync` commands copy files and
  synchronize directories one way between your computer and a project checkout
  or conversation workspace. They use the same authenticated routes as every
  other CLI command, verify all content with SHA-256, and handle binary files of
  up to 64 GiB.
- The Mac app is faster throughout. Switching chats takes about 40% less work,
  browsing changes about 30% and switching sections about 20%. Streaming
  replies, typing, the board, the sidebar, the Inbox, terminals and the file
  editor redraw only what changed.
- The Changes view wraps every line to the pane, side by side too, so long
  Markdown paragraphs and code lines no longer scroll sideways. Diffs of
  thousands of lines open, scroll and resize smoothly.

### Fixed

- A Mac reconnects promptly after it wakes from sleep. It used to stay
  "Connected" with every machine offline for minutes. A daemon likewise
  reconnects to the gateway as soon as it notices a sleep, instead of waiting
  about 45 seconds.
- The Mac app's **Show reasoning** setting now follows changes to the
  preference, for example from another device.

## 0.6.410

End-to-end encryption between your devices. This release starts the 0.6 line
and is a clean break: nothing migrates, and every machine and app pairs again
after the upgrade.

### Upgrading

0.5 and 0.6 cannot talk to each other, so update everything in one go:

1. **Gateway.** Deploy the 0.6 gateway. Its minimum client and daemon releases
   are `0.6.0-dev.0`, so it rejects 0.5 apps and daemons.
2. **First machine.** Update the daemon on the host itself (`brew upgrade dieter`
   on macOS; `dieter machine update --confirm UPDATE` or `install.sh` on
   Linux), then run `dieter setup`. It starts your account's device roster and
   prints a recovery key once. Store it offline.
3. **Other machines.** Update each one the same way and run `dieter setup`. It
   prints a one-time code; approve it on the first machine with
   `dieter device approve CODE`.
4. **Apps.** Update each app and open it. It shows a one-time code; type it on a
   trusted device: `dieter device approve CODE` on a machine, or
   **Devices → Add a device** in an app that is already trusted.

### Security

- Every remote call now runs mutually authenticated TLS 1.3 between the calling
  device and the daemon, on every route: direct TLS, WebRTC and the gateway
  relay. The relay is an opaque tunnel, so the gateway forwards bytes it can
  neither read nor change: chats, terminals, files, executions, Git, vault
  content, peer records and screen signaling. It still sees metadata (devices,
  presence, routes, tunnel timing and sizes, provider quota snapshots) and can
  deny service.
- Every machine and app has its own key in the account's device roster, an
  append-only list in which every change is signed by a trusted device. The
  gateway stores the list but cannot add a device or remove one. A new device
  shows a one-time code; typing it on a trusted device adds it. Only type a code
  you see on your own new device.
- App keys live in the Secure Enclave (Mac, iPhone, iPad) or the Android
  Keystore and cannot be exported. The Mac app keeps its key in its user-only
  data folder, never in the Keychain.
- Gateway tokens are bound to the calling device, so a session or token without
  the device key reaches no machine. The gateway's daemon CA now only
  authenticates daemons to the gateway; clients pin keys from the roster.

### Changed

- New `dieter device` commands: `status`, `roster`, `sync`, `init`, `requests`,
  `approve`, `revoke` and `recover`. `init` and `recover` run only on the
  machine itself, and agent turns cannot change device trust.
- `dieter setup` starts the device roster on an account's first machine, or
  prints the code that a new machine waits with.
- `dieter daemon unenroll` also removes the machine from the trusted devices and
  deletes its key. Enrolling it again creates a new machine that a trusted
  device approves.
- The apps show a pairing screen until the device is trusted, and a Devices
  screen (**Tools › Devices** on Android, iPhone and iPad; **Settings › Devices**
  on Mac) to add, list and remove devices.
- Vault commands that return decrypted content now work over the gateway relay
  too, and the vault audit records which device asked.
- Claude Code, Codex and OMP now run at the latest versions Dieter ships with
  instead of the versions the AI SDK adapters pin: Claude Code 2.1.296 (Claude
  Agent SDK 0.3.296), Codex 0.162.1 and OMP 18.10.1. Updates follow each release.
- Release daemons no longer need npm. The prebuilt harness runtime now includes
  the Claude Code, Codex and OMP command-line tools, and an agent's first turn
  links them instead of installing them with npm. Only the DeepSeek Harness
  (DSH) still installs from npm, and daemons built from source still install
  their runtime with npm. The runtime download grows accordingly, to about
  600 MB on macOS and about 1 GB on Linux.
- OMP and DSH conversations started before this update cannot continue: the
  updated agent adapter no longer accepts their saved session. Start a new
  conversation for them.

### Fixed

- The iOS app no longer crashes when it opens a conversation that contains a
  fenced Markdown code block. Only optimized release builds were affected.

## 0.5.405

### Changed

- Release daemons no longer install their harness runtime with npm. Each release
  publishes a prebuilt runtime per daemon platform
  (`dieter-harness-runtime-<os>-<arch>.tar.gz`); the daemon downloads the one
  whose SHA-256 its binary pins on first use and during updates, and verifies
  it before installing. Hosts still need Node.js 22.19+, npm (for agent provider
  bridges) and Git. Daemons built from source keep installing with npm.
- The daemon's storage (`internal/store`) is split into one package per
  aggregate (projects and cards, conversations, schedules, workspaces, the peer
  replica, …) with a lint-enforced dependency order. Files on disk do not
  change.

### Fixed

- `brew uninstall --zap dieter-app` removes the Mac app's data under its
  current identifier, `com.getdieter.mac`.

## 0.5.404

The open-source foundation release. It is a clean break: reinstall the daemon
and apps; nothing migrates from 0.4.

### Upgrading

0.4 and 0.5 cannot talk to each other, so update everything in one go:

1. **Gateway.** Deploy the 0.5.404 gateway bundle. Its signature now comes from
   `.github/workflows/release.yml`, so a deployment controller that pins signer
   workflows must trust that identity first. The new gateway rejects 0.4 apps
   and daemons.
2. **Daemons.**
   - macOS: run `brew upgrade dieter`, then `dieter setup` to register the
     service and privacy helper under the new identifiers.
   - Linux: run `dieter machine update` on the host, or reinstall with
     `install.sh`.
3. **Apps.**
   - macOS: `brew install --cask dbpprt/tap/dieter-app`, or download
     `Dieter-macOS-arm64.zip`.
   - iOS: the TestFlight build.
   - Android: install `Dieter-Android.apk`. It is a new app
     (`com.getdieter.android`), so remove the old one.

   Sign in again on every app.

### Breaking

- **Identifiers.** Every app and helper moves to `com.getdieter.*`:
  - `com.getdieter.mac`, `com.getdieter.ios` and `com.getdieter.android`;
  - `com.getdieter.daemon`, `com.getdieter.capture` and `com.getdieter.privacy`.

  Android and macOS installs are new apps. Sign in again on every device, and
  re-register the macOS privacy helper (`dieter setup`).

- **Apple team.** Signed binaries, the privacy helper and the installer trust
  only team `FNGU8JFNPL`.
- **iOS sign-in** uses the `dieter-ios://` callback. The gateway must allow it
  (the deployment renders it).
- **Daemon API.** `dieter.v1` is one service per domain (`CardService`,
  `ConversationService`, `ScreenService`, …) instead of one `DieterService`.
  - RPC paths change, so clients, daemons and gateways below 0.5 cannot talk to
    0.5.
  - The gateway's minimum client and daemon version is `0.5.0-dev.0`.
- **Release signing.** Checksums and the gateway deployment bundle are signed
  only by `.github/workflows/release.yml@refs/heads/main`.
- **Removed.** The private OMP/Pi model routes (Tailscale GLM, Box Qwen) are
  gone from the default catalog.

### Changed

- **Repository layout.**
  - `apps/kotlin` is one Gradle build: core, Compose UI and the Android app.
  - `apps/apple` holds `DieterKit`, the Mac app and the iOS app.
  - `native/macos` is a SwiftPM package for the daemon helpers.
  - Vendored code moved to `third_party/`, the website to `site/`, and the
    gateway deployment files to `deploy/`.
- **Daemon.** The startup wiring moved out of the CLI into `internal/daemon`,
  with one configuration loader and per-domain API handlers.
  - Unknown server errors are reported as `Internal`, so clients retry them
    instead of dropping the command.
- **Schemas.** All `.proto` files live in `api/proto`. `just generate` runs buf
  for Go and Swift and fails CI on drift; Kotlin generates from the same files.
- **Builds.**
  - Fastlane builds, signs and distributes using its built-in actions.
  - The Mac app now has an Xcode project, built with `build_mac_app`.
  - Plain `go`, `gradlew` and `swift` commands work without Fastlane.
- **CI.**
  - Pull requests run only the affected checks, behind one required `ci-ok`
    check.
  - Failures show as annotations, every job writes a summary, and every test
    runner reports JUnit.
  - Dev releases are cut nightly, not on every push.

### Fixed

- **Installer.** It verified the old Apple team, so it rejected current
  releases.
- **Privacy helper.** It authorized clients signed by the old team only.
- **Local daemon on a random port.** `dieter serve --addr 127.0.0.1:0` now
  records the port it actually bound, so the CLI can reach it.
- **Fixture gateways.** They no longer reinstall the harness runtime for every
  test fixture.
