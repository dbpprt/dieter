---
title: "Code review (a second model checks the agent's work)"
linkTitle: "Code review"
description: "Give a task a code reviewer: a separate, Dieter-managed harness reviews the agent's changes, and the findings appear in the conversation."
group: "Workflows"
weight: 28
slug: "code-review"
---

A conversation can have a **code reviewer**. A second model, on a harness you
choose once for your account, reviews the agent's changes and reports bugs,
security problems and significant performance problems. The agent asks for a
review when its change is complete, fixes what it agrees with, and tells you
which findings it rejects and why. You see every review in the conversation,
and you can start one yourself at any time.

## Choose the reviewer

One setting covers all your machines and apps:

- **Mac:** **Settings › Code reviewer**.
- **Android, iPhone and iPad:** **Settings › Conversations › Code reviewer**.
- **CLI:**

```sh
dieter reviewer show
dieter reviewer update --harness claude-code --model opus --depth quick
dieter reviewer update --harness codex --model gpt-5.5 --account Work
dieter reviewer update --instructions "We care about lock ordering and error paths."
dieter reviewer update --ignore "gen/**" --ignore "*.snap"
```

The setting holds:

- **Harness, model and effort.** Any harness in your catalog except Strix.
  Claude Code and Codex reviewers run on a [provider account](/docs/providers/):
  the one you pick, or the provider's default.
- **Depth.** **Quick** (the default) reviews the change in one pass and reads
  the code only to settle a doubt; it usually takes a minute or less. **Thorough**
  confirms every finding in the code first; it takes several minutes and uses
  more tokens, and finds more of the subtle problems.
- **Limits.** At most this many findings per review (default 6), a minimum
  confidence, and how many reviews the agent may request per task (default 3).
- **Extra instructions** for every review, and **ignored paths**. Lock files,
  minified files and generated code are always left out.

Until you save a setting, the reviewer is Claude Code with Opus, quick.

The model matters more than anything else: in our tests the strongest models
found every planted bug, while smaller models found far fewer and sometimes
reported problems that did not exist.

## Give a task the reviewer

- **Mac:** switch on **Code review** in the New Card sheet, or **Review** when
  you start a standalone chat, or later choose **Code review** in the **More**
  (⋯) menu of the conversation's header. A **Code review** badge shows next to
  the conversation's title while it is on.
- **Android, iPhone and iPad:** switch on **Code review** under **Access** when
  you create a task or chat, or later choose **Code review** in the
  conversation's menu. Schedules have the same switch.
- **CLI:**

```sh
dieter card create --project P --board B --title "Add retries" --workspace worktree --code-review
dieter chat create --project P --title "Fix the parser" --workspace project --code-review
dieter card reviewer CARD_ID on      # or off; takes effect at the next turn
dieter schedule create ... --code-review
```

With the reviewer on, the agent gets a `request_code_review` tool and short
instructions: request a review when a change is complete and before reporting
the task done, fix the findings it agrees with, explain the ones it rejects,
and request another review after substantial fixes.

## Read the findings

Each review appears in the conversation as a card: the reviewer and depth, a
summary of the change, and the findings, most severe first. Each finding has a
severity, the file and lines, an explanation of when the problem happens, and
often a suggested fix. Select a file to open its diff in the Changes pane. A
second review of the same task marks findings as **still open** or **new**, and
counts the ones that are **resolved**.

To review the changes yourself, choose **Review changes** in the Changes pane
(on Android, iPhone and iPad it is in the Changes menu), or run:

```sh
dieter card review CARD_ID --wait            # waits and prints the findings
dieter card review CARD_ID --focus "the retry loop" --depth thorough
dieter card reviews CARD_ID                  # every review of the conversation
```

The agent sees a review you started with your next message.

## What gets reviewed, and where

A review covers everything that differs from the workspace's base, committed or
not, including new files that aren't ignored by Git:

- In a **worktree**, the change since the worktree left its base branch.
- In the **project directory**, the uncommitted work.

The review runs on the conversation's own machine. Dieter takes a snapshot of
the workspace into a temporary checkout under `DIETER_HOME`, runs the reviewer
there with no access to Dieter's tools, and deletes the snapshot afterwards.
The agent's workspace, its index and its branch are never touched, and changes
the agent makes while the review runs don't affect it. Nothing leaves your
machine except the reviewer's own model requests, through your provider
account, exactly as for the agent's turns.

The reviewer's rubric is adapted from the open-source
[PR-Agent](https://github.com/The-PR-Agent/pr-agent) reviewer (MIT).
