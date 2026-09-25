---
title: "Quick start"
linkTitle: "Quick start"
description: "Install a host, register a Git checkout, and run your first task."
group: "Start here"
weight: 11
slug: "quickstart"
---

You need a Git repository, a configured agent account on the host, and access to
a Dieter gateway. A gateway operator must allow your numeric GitHub account ID;
installing Dieter does not grant access to somebody else's gateway. You can
[run your own](/docs/gateway/).

## 1. Install the host

On Apple Silicon macOS:

```sh
brew install dbpprt/tap/dieter
dieter setup --gateway https://dieter.example.com
```

Replace `https://dieter.example.com` with **your gateway origin**. Sign in with
GitHub, then check and approve the machine name and enrollment code in the
browser. Setup starts the managed service and guides supported host permissions.

For a Linux host, follow the [Linux installation steps](/docs/installation/#linux).

## 2. Register a checkout

```sh
dieter project open ~/Development/my-project
dieter doctor
dieter harness list
```

Use an existing Git working tree on this machine. `setup` enrolls the machine;
`project open` registers the repository. They are separate operations.
Verify that your chosen [harness](/docs/harnesses/) has working credentials on the
host before starting work.

## 3. Open a client

```sh
brew install --cask dbpprt/tap/dieter-app
open -a Dieter
```

Sign in to the same gateway. On Android, install the
[release APK](https://github.com/dbpprt/dieter/releases/latest/download/Dieter-Android.apk)
and sign in to that origin instead. Your shared projects appear across clients.

## 4. Create a task

Open a project and its board, then add a task. Give the agent a concrete request,
such as “Explain the test setup and identify a small missing test.” Choose a
provider, model, and available reasoning level.

Choose **New worktree** for a separate branch and working directory, or **Project
directory** to work in the registered checkout as it stands. On a project with
several checkouts, choose where the work should execute.

Save to **Todo** to start later, or use **Run task** to begin immediately.
Watch the transcript, tool activity, and result in the same conversation.

## 5. Review and continue

Open files or the Changes surface to inspect the result. Send a follow-up to
continue the same conversation; messages sent during an active turn wait in its
queue. Closing the client leaves the agent running on its host.

Moving a card to Review is workflow state, not a Git merge or publication.
See [projects and tasks](/docs/projects/) for delivery settings.

## The same task from the CLI

Use the exact IDs returned by the list commands:

```sh
dieter project list --format jsonl
dieter board list --project PROJECT_ID --format jsonl
dieter card create --project PROJECT_ID --board BOARD_ID \
  --lane running --title "Explain the tests" \
  --prompt "Explain the test setup and identify a small missing test." \
  --workspace worktree --format id
dieter card context CARD_ID
```

`PROJECT_ID`, `BOARD_ID`, and `CARD_ID` are placeholders. Creation returns as
soon as the turn is admitted; use `card context` or `card watch` to follow it.

If something does not connect, start with [troubleshooting](/docs/troubleshooting/).
