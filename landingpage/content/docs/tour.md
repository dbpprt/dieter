---
title: "A tour of Dieter"
linkTitle: "Product tour"
description: "See boards, conversations, document review, background processes, and machine tools in the native apps."
group: "Overview"
weight: 2
slug: "tour"
---

Start with a task on your Mac. Follow its conversation from your phone. The agent
runs on the machine that owns the checkout, even when you close a client.

These are real native captures from September 2026, using disposable projects and
a mock agent. They illustrate the interface, not model quality or performance.
Open any image to inspect it at full size.

## Give the work a home

A board organizes tasks through **Todo → Running → Review → Done**. Each card
keeps one durable conversation, its execution machine, and its workspace choice.
Lane and agent status are separate: an idle agent can leave a card in Running
until the work is ready for review.

{{< screenshot src="macos-board.png" width="1380" height="870" alt="Dieter Mac board for the demo Orbit project, with tasks in Todo, Running, and Done" caption="The Mac board: four sample tasks, one project, and an explicit execution machine on each card." >}}

Use **Quick task** to capture an idea or open a standalone chat for work that does
not need a board card. [Learn about projects, tasks, and worktrees →](/docs/projects/)

## Keep the result beside the conversation

On Mac, enable **Settings → Experimental → Show the workspace side panel**.
The panel is off by default. Once enabled, a file link opens the actual workspace
file beside the conversation; an agent can also present a deliverable directly.

{{< screenshot src="macos-workspace.png" width="1380" height="870" alt="A Mac card conversation beside the native Markdown editor showing an onboarding plan and decision table" caption="Review an onboarding plan without leaving its conversation. This capture has the experimental workspace panel enabled." >}}

Markdown has rich editing and source modes, revision-checked saves, and PDF/HTML
export. Other tabs hold code, images, web previews, terminals, and Git review.
[Explore the conversation workspace →](/docs/workspace/)

## See what a command did

Registered background commands appear in **Processes** with their command,
running or exit state, and separate output streams. Leaving the conversation
does not cancel them. Stop is an explicit action.

{{< screenshot src="macos-processes.png" width="1380" height="870" alt="The Mac Processes tab beside a conversation, showing git ls-files completed with exit code zero and its standard output" caption="A real, harmless command in the disposable project. The output and exit status stay available after it completes." >}}

[Understand processes, terminals, and schedules →](/docs/automation/)

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
