---
title: "A tour of Dieter"
linkTitle: "Product tour"
description: "See agents working across machines on a shared board, a task beside its changes, native terminals, screen sharing, and the Android, iPhone, and iPad app."
group: "Overview"
weight: 2
slug: "tour"
---

Run agents on an always-on Mac or headless Linux host. Follow their work from
your laptop or phone. Closing a client does not stop the agent on another host;
that execution host must stay powered on and awake.

These are real native captures from October 2026. The demo workspace runs real
daemons for two Mac minis, plus a MacBook Pro that is offline, with four
projects, Git checkouts, and scripted agent turns. The captures illustrate the
interface, not model quality or performance. Android, iPhone, and iPad share one
app. Open any image to inspect it at full size.

## One board, work across machines

A board organizes tasks through **Todo → Running → Review → Done**. Each card
keeps one durable conversation, its execution machine, and its workspace choice.
Lane and agent status are separate: an idle agent can leave a card in Running
until the work is ready for review.

{{< screenshot src="macos-board.png" width="1380" height="870" alt="Atlas API Roadmap board with fifteen labeled tasks across four lanes, four projects in the sidebar, and Home mini and Office mini as execution machines" caption="Fifteen tasks on one roadmap. Three agents are working, on two machines." >}}

**Home mini** and **Office mini** each have a checkout of the shared Atlas API
project. Their cards appear together, with the execution machine named on each
card. The capture runs both daemon identities on one physical Mac to exercise
real ownership and routing without a production account.

Use **Quick task** to capture an idea or open a standalone chat for work that does
not need a board card. [Learn about projects, tasks, and worktrees →](/docs/projects/)

## Follow a task and review its changes

Open a card to follow its conversation. The reply, tool activity, and the
agent's plan update while the turn runs, and messages you send meanwhile join
its queue. **Split conversation and workspace** keeps the Git changes beside the
conversation, where you can stage, discard, and commit.

{{< screenshot src="macos-conversation.png" width="1380" height="870" alt="A running Atlas API task on Office mini: the reply with a rate-limit table and plan progress on the left, the limiter.go diff in Changes on the right" caption="The agent is still running its race tests while the diff it has written waits for review." >}}

[Explore files and the conversation workspace →](/docs/workspace/)

## Open a terminal on the host

Choose **Terminals** and the machine doing the work. Run an interactive shell,
inspect the output, and reconnect later. Leaving the client does not close its
host-owned terminal session.

{{< screenshot src="macos-terminal.png" width="1380" height="870" alt="Native terminal on Office mini in the Atlas API checkout, showing Git history, working-tree status, and passing Go race tests" caption="A real shell in the Atlas API checkout on Office mini. Project and machine navigation stay within reach." >}}

For unattended commands, registered background processes retain bounded stdout,
stderr, and exit state. For recurring work, a schedule runs on its owning daemon.
[Understand processes, terminals, and schedules →](/docs/automation/)

## See the visual result

Agents and terminals work without a desktop. When a host does have an active
graphical session, **Screens** lets you view it and take control from the native
client. Media travels directly between peers or through TURN; the Dieter gateway
relays the encrypted signaling without being able to read it.

{{< screenshot src="macos-screens.png" width="1380" height="870" alt="Dieter Screens connected to Studio Mac, displaying a live Orbit demo dashboard with native control and connection status" caption="A live screen stream in the native Mac viewer, captured in September 2026 with the earlier Mac design. That capture limited its source to an owned demo window; standard screen hosting shares a display." >}}

The sample dashboard is a disposable visual target, not another Dieter interface.
Its sample metrics are not agent results. [Use a remote screen →](/docs/screens/)

## Review files in their project

Open a project's **Files** surface, choose its checkout, and read the actual file
on that host. Markdown supports rich editing and source modes, revision-checked
saves, and PDF/HTML export.

{{< screenshot src="macos-files.png" width="1380" height="870" alt="Atlas API Files on Office mini with docs/rate-limits.md open in the native Markdown editor, showing a plan table and a 429 response example" caption="The project's real files, read from the Office mini checkout." >}}

## Check the machine behind a task

Open a machine in the Mac sidebar to inspect its availability, route, and live
host telemetry without losing your board.

{{< screenshot src="macos-machines.png" width="1380" height="870" alt="Office mini machine details over the Atlas API board, showing its local route, CPU, memory, and Apple M4 GPU telemetry" caption="The execution host stays a click away. Telemetry is the fixture host's actual load at capture time, not a benchmark." >}}

## Pick up the thread on your phone

**Inbox** is the starting point on Android, iPhone, and iPad. It brings task and
chat activity together so you can find recent work without first choosing a
board. Next to it are [**Mail**](/docs/mail/), **Projects** and **Chats**.
**More** holds everything else: **Channels**, **Terminals**, your machines,
[**Providers**](/docs/providers/) (your Claude and ChatGPT accounts with their
plan usage), **Devices** and **Settings**. On Android, More slides up as a sheet
above the bar; on iPhone and iPad it is a tab. Its badge counts unread channel
messages.

Every platform lists the Inbox in the same four sections:

- **Needs you:** questions waiting for your answer, completed replies you have
  not viewed, and failed agents.
- **Running:** agents at work.
- **Pinned:** pinned conversations that are idle.
- **Recent:** everything else.

Within a section the newest comes first. A conversation moves up when a turn
starts or ends, not on every step of the agent. Opening the latest reply clears
it from Needs you on every client. A failure stays there until you retry the
agent, finish its card or archive it. The Inbox tab's badge counts what needs
you.

On Android, iPhone and iPad each conversation is a two-line row. The first line
holds its project avatar, title and time. The second holds the project and what
the agent is doing or said last, plus one mark: **?** waits for your answer, a
dot is an unread reply, **!** failed, an eye is ready for review, a pin is
pinned. A running agent's avatar has a spinning ring. The filter menu shows
**All**, **Needs you**, **Running**, **Pinned** or **Review**, each with its
count. It also filters by project and opens Inbox rules.

When you open the app, the Inbox shows what it knew when you last left it, and
refreshes each row as its machine answers. Until then a small mark spins next
to the row's time and light sweeps across its second line. A row whose machine
is offline or not responding says so instead.

Swipe a row right to mark a reply read, finish a reviewed or failed card, or pin
it. Swipe it left to archive it or stop a running agent; an archive can be
undone. Touch and hold a row for all its actions.

On the Mac each conversation is one line: its status, title, working subagents,
project and age. The segments above the timeline filter by status, and the
filter button holds search (⌘F), the project, the timeline range and Inbox
rules. Hover a row to pin or unpin it, or to finish a card waiting for review or
a failed one.

A pinned conversation that needs you or is running stays in that section and
keeps its pin; it returns to **Pinned** once it is idle. Pins sync across your
account through shared KV, and offline edits sync when a machine is available.
Search and project filters still apply to pinned conversations.

Inbox rules decide which conversations the Inbox lists. Open **Inbox rules**
from the filter button on the Mac or the filter menu on Android and iOS, then
add a rule that hides or shows only the conversations of some projects and
labels. A rule can require a project and a label together or accept either, and
you can keep several rules and switch each on or off. A conversation matching
any hiding rule is left out; while a showing rule is on, only conversations
matching one are listed. Rules sync across your account like pins. The end of
the Inbox and the Inbox rules menu item say how many conversations they hide.

{{< shots >}}
{{< screenshot src="ios-inbox.png" kind="phone" width="1206" height="2622" alt="iPhone Inbox with replies that need you and running tasks" caption="Inbox on iPhone." >}}
{{< screenshot src="android-board.png" kind="phone" width="1080" height="2400" alt="Android Atlas API Roadmap board filtered to its four running tasks, each with its machine, branch, and agent" caption="A board on Android." >}}
{{< /shots >}}

A task conversation shows the same reply, tool activity, and plan as on Mac,
and exposes its **Changes** and **Subagents**. A standalone chat stays separate
from the board. Messages sent during an active turn join its queue; closing the
app leaves the host working.

{{< shots >}}
{{< screenshot src="ios-conversation.png" kind="phone" width="1206" height="2622" alt="A running task on iPhone with its reply, rate-limit table, plan progress, and the test command in flight" caption="A running task on iPhone." >}}
{{< screenshot src="android-chats.png" kind="phone" width="1080" height="2400" alt="Android Chats with a pinned chat and standalone chats grouped by project" caption="Standalone chats on Android." >}}
{{< /shots >}}

A project's page opens its **Files**, **Changes** and **Schedules**. Changes
shows a project's shared checkout, with the same staging and diff review as the
desktop. Tap a checkout to browse that machine's copy; with several checkouts,
the **Checkout** menu switches between them, and the title always names the
project and machine. **More** lists your enrolled machines and their
availability. A machine's page shows its screen, its terminals and the projects
checked out on it. Clients check compatibility before connecting and reject a
mismatched release compatibility policy.

{{< shots >}}
{{< screenshot src="ios-changes.png" kind="phone" width="1206" height="2622" alt="iPhone Changes for the Storefront checkout with an inline diff of CartSummary.tsx and a new ShipmentGroup.tsx" caption="Project changes on iPhone." >}}
{{< screenshot src="android-machines.png" kind="phone" width="1080" height="2400" alt="Android Machines with Home mini and Office mini online through the relay and MacBook Pro offline" caption="Machines on Android." >}}
{{< /shots >}}

On iPad, and on Android tablets and unfolded foldables, a list and what you
open from it sit side by side. On Android, drag the handle between them to
resize the list. Drag it all the way to one side to hide that pane: with the
list hidden, whatever you open fills the screen (back returns to the list);
with the open page hidden, the list fills the screen until you open something.
The handle stays at the edge to pull the pane back, a double-tap restores both,
and the app remembers your choice.

{{< screenshot src="ipad-conversation.png" kind="tablet" width="2048" height="2732" alt="iPad with the Atlas API board on the left and a running task's reply, rate-limit table, and plan on the right" caption="The board and a running task, side by side on iPad." >}}

On Android the tabs float above the page in a glass bar, and the page's main
action, such as **New task** or **New chat**, sits beside it as a round button.
On an unfolded foldable the bar stays under the list, so a task's message
field reaches the bottom of its own pane. In landscape the bar stands on the
left edge. Drag along the bar to slide between tabs; while you scroll down a
page, it shrinks to the current tab and comes back when you stop. The message
field floats above the reply
as a card, with the agent, the context in use and send inside it.
**Settings → Appearance → Navigation** offers **Lens** (the default), **Dock**
(labels on every tab), **Island** (a compact pill) and **Classic** (the docked
bar). **Chat input** offers **Card** (the default), **Glass** and **Classic**.

### Android on a desktop

In Samsung DeX, in Android's desktop windowing and on a connected display, the
Android app switches to a desktop layout modelled on the Mac app. A sidebar holds
Inbox, Mail, Channels, Chats and Terminals, your projects with their live work,
your machines, and the usage of your provider accounts. A board shows every
lane side by side, and an open task sits beside it with a tab for each of its
panes. Rows react to the pointer, and a right-click opens a card's menu. Drag
the gaps between panes to resize them.

With a keyboard:

| Keys                  | Action                                     |
| --------------------- | ------------------------------------------ |
| Ctrl+K                | Search tasks, chats, projects and commands |
| Ctrl+N / Ctrl+Shift+N | New task / new chat                        |
| Ctrl+1 … Ctrl+5       | Inbox, Mail, Channels, Chats, Terminals    |
| Ctrl+,                | Settings                                   |
| Ctrl+B                | Show or hide the sidebar                   |
| Ctrl+W                | Close the open task                        |
| Ctrl+R                | Refresh                                    |
| Alt+←                 | Back                                       |

**Settings → Appearance → Interface** chooses the layout: **Automatic** (the
desktop layout only on a desktop), **Desktop** (also on a large tablet window)
or **Touch**. Windows narrower than 720 dp always use the touch layout.

[Connect more machines →](/docs/machines/) · [Use a remote screen →](/docs/screens/)

## Try it with your project

Follow the [installation guide](/docs/installation/), then
[run your first task](/docs/quickstart/). The screenshots use demo data;
your available models, tools, and machine capabilities come from your own hosts.
