---
title: "A tour of Dieter"
linkTitle: "Product tour"
description: "See headless agents across machines, a busy shared board, native terminals, screen sharing, and mobile conversations."
group: "Overview"
weight: 2
slug: "tour"
---

Run agents on an always-on Mac or headless Linux host. Follow their work from
your laptop or phone. Closing a client does not stop the agent on another host;
that execution host must stay powered on and awake.

These are real native captures from September 2026, using disposable projects and
a mock agent. They illustrate the interface, not model quality or performance.
The Mac set uses the **Electric Blue** design in dark appearance, with the
conversation workspace side panel disabled. Open any image to inspect it at full size.

## One board, work across machines

A board organizes tasks through **Todo → Running → Review → Done**. Each card
keeps one durable conversation, its execution machine, and its workspace choice.
Lane and agent status are separate: an idle agent can leave a card in Running
until the work is ready for review.

{{< screenshot src="macos-board.png" width="1380" height="870" alt="Orbit Product launch board with 17 labeled tasks across four lanes, five projects in the sidebar, and Studio Mac and Build Mac execution owners" caption="Five projects. Seventeen tasks on one board. Two connected machine identities, with three mock turns active at capture." >}}

**Studio Mac** and **Build Mac** each have a checkout of the same shared Orbit
project. Their cards appear together, with the execution owner visible on each
card. The capture uses two isolated daemon identities on one physical Mac to
exercise real ownership and routing without involving a production account.

Use **Quick task** to capture an idea or open a standalone chat for work that does
not need a board card. [Learn about projects, tasks, and worktrees →](/docs/projects/)

## Open a terminal on the host

Choose **Terminals** and the machine doing the work. Run an interactive shell,
inspect the output, and reconnect later. Leaving the client does not close its
host-owned terminal session.

{{< screenshot src="macos-terminal.png" width="1380" height="870" alt="Native terminal on Build Mac showing Python source, eight passing demo tests, and Git working-tree status" caption="A real shell on Build Mac, running a small disposable project's tests. Project and machine navigation stay within reach." >}}

For unattended commands, registered background processes retain bounded stdout,
stderr, and exit state. For recurring work, a schedule runs on its owning daemon.
[Understand processes, terminals, and schedules →](/docs/automation/)

## See the visual result

Agents and terminals work without a desktop. When a host does have an active
graphical session, **Screens** lets you view it and take control from the native
client. Media travels directly between peers or through TURN; the Dieter gateway
handles signaling.

{{< screenshot src="macos-screens.png" width="1380" height="870" alt="Dieter Screens connected to Studio Mac, displaying a live Orbit demo dashboard with native control and connection status" caption="A live screen stream in the native Mac viewer. This isolated capture limits its source to an owned demo window; standard screen hosting shares a display." >}}

The sample dashboard is a disposable visual target, not another Dieter interface.
Its sample metrics are not agent results. [Use a remote screen →](/docs/screens/)

## Review files in their project

Open a project's **Files** surface, choose its checkout, and read the actual file
on that host. Markdown supports rich editing and source modes, revision-checked
saves, and PDF/HTML export.

{{< screenshot src="macos-files.png" width="1380" height="870" alt="Orbit project Files surface with launch-plan.md open in the native Markdown editor, including a workstream and execution-host table" caption="The full Files workspace, with the conversation side panel disabled. The launch plan connects each workstream to its execution host." >}}

An optional experimental workspace panel can also keep files, previews, processes,
and Git review beside a conversation. [Explore files and the conversation workspace →](/docs/workspace/)

## Check the machine behind a task

Open a machine in the Mac sidebar to inspect its availability, route, and live
host telemetry without losing your board.

{{< screenshot src="macos-machines.png" width="1380" height="870" alt="Build Mac information popover over the Orbit board, showing online status, gateway route, CPU, memory, and GPU telemetry" caption="The execution host stays visible. Telemetry is an actual capture-time snapshot from the fixture host, not a benchmark." >}}

## Pick up the thread on Android

**Activity** is the Android starting point. It brings task and chat activity
together so you can find recent work without first choosing a board. The bottom
navigation keeps **Boards**, **Chats**, and **Tools** nearby.

{{< screenshot src="android-activity.png" kind="phone" width="1080" height="2424" alt="Android Activity feed showing sample onboarding tasks with runtime and machine information" caption="Activity brings recent work into one native feed." >}}

A standalone chat stays separate from the board. A task conversation also exposes
its **Changes**, **Comments**, and **Subagents**. Messages sent during an active
turn join its queue; closing the app leaves the host working.

{{< screenshot src="android-chat.png" kind="phone" width="1080" height="2424" alt="Android standalone conversation with an onboarding request and a starting mock agent" caption="A standalone chat, captured as the fixture starts its mock agent." >}}

{{< screenshot src="android-task.png" kind="phone" width="1080" height="2424" alt="Android task conversation with its Running lane, review request, and Changes, Comments, and Subagents tabs" caption="A board task keeps its conversation and review context together." >}}

## Know where the work runs

Open **Tools → Machines** to inspect enrolled hosts and their availability.
Clients check compatibility before connecting and reject a mismatched
application contract. The fixture below also includes an intentionally
incompatible host.

{{< screenshot src="android-machines.png" kind="phone" width="1080" height="2424" alt="Android Machines screen with an online compatible host and an intentionally incompatible test host" caption="Machine discovery makes availability and compatibility visible." >}}

Open a compatible host to inspect its route and live CPU, memory, and supported
GPU telemetry. These values describe the host, not the phone displaying them.

{{< screenshot src="android-telemetry.png" kind="phone" width="1080" height="2424" alt="Android machine detail with connection route, CPU utilization, memory usage, and Apple GPU telemetry" caption="Native machine tools show the state of the host doing the work. Values are a capture-time snapshot, not a benchmark." >}}

[Connect more machines →](/docs/machines/) · [Use a remote screen →](/docs/screens/)

## Try it with your project

Follow the [installation guide](/docs/installation/), then
[run your first task](/docs/quickstart/). The screenshots use demo data;
your available models, tools, and machine capabilities come from your own hosts.
