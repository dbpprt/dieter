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
board. Next to it are **Projects** and **Chats**. **More** holds everything
else: [**Mail**](/docs/mail/), **Channels**, **Terminals**, your machines,
**Usage**, **Devices** and **Settings**. On Android, More slides up as a sheet
above the bar; on iPhone and iPad it is a tab. Its badge counts unread mail and
channel messages.
Completed replies that you have not viewed appear under **Needs you**. Opening
the latest reply clears that state across clients; questions waiting for your
answer continue to need attention.

Use the small pin button on an Inbox card to keep it in the **Pinned** section
at the top on Mac, Android, and iOS. Tap it again to unpin. Pins sync across
your account through shared KV; offline edits sync when a machine is available.
Search and project filters still apply to pinned cards.

Inbox rules decide which conversations the Inbox lists. Open **Inbox rules**
from the filter button on the Mac or the filter menu on Android and iOS, then
add a rule that hides or shows only the conversations of some projects and
labels. A rule can require a project and a label together or accept either, and
you can keep several rules and switch each on or off. A conversation matching
any hiding rule is left out; while a showing rule is on, only conversations
matching one are listed. Rules sync across your account like pins, and the
Inbox says how many conversations they hide.

{{< shots >}}
{{< screenshot src="ios-inbox.png" kind="phone" width="1206" height="2622" alt="iPhone Inbox with four replies that need you, provider quotas, and running tasks" caption="Inbox on iPhone." >}}
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
resize the list, or double-tap it to reset the split; the app remembers it.

{{< screenshot src="ipad-conversation.png" kind="tablet" width="2048" height="2732" alt="iPad with the Atlas API board on the left and a running task's reply, rate-limit table, and plan on the right" caption="The board and a running task, side by side on iPad." >}}

[Connect more machines →](/docs/machines/) · [Use a remote screen →](/docs/screens/)

## Try it with your project

Follow the [installation guide](/docs/installation/), then
[run your first task](/docs/quickstart/). The screenshots use demo data;
your available models, tools, and machine capabilities come from your own hosts.
