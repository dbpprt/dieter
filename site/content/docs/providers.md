---
title: "Provider accounts (Claude & ChatGPT)"
linkTitle: "Provider accounts"
description: "Sign your machines in to Claude and ChatGPT from any app, choose the account per chat, and follow plan usage."
group: "Start here"
weight: 12
slug: "providers"
---

Claude Code and Codex turns run on your own Claude and ChatGPT subscriptions.
A **provider account** is one Claude or ChatGPT login that agents may use:
Claude Code runs on Claude accounts, Codex on ChatGPT accounts. You add an
account once for your whole Dieter account, and every app and machine shows
the same list. Each machine then signs in to the account on its own, and you
choose the account per chat.

Pi, Oh My Pi, DSH and Strix keep using their own configuration on the
execution machine; see [Agents & models](/docs/harnesses/).

## Accounts and machines

An account has a provider, a label you choose ("Work", "Personal") and, from
its first sign-in on, the login it belongs to: email, organization or
workspace, and plan. Its page lists every machine of your account with its
state: **Signed in**, **Not signed in**, **Sign-in expired**, or a failure with
its reason.

A turn runs on the machine that owns the conversation, so the account a chat
uses must be signed in on that machine.

### Why every machine signs in separately

- **Anthropic's terms.** Anthropic does not allow apps such as Dieter to
  store, copy or pass on Claude sign-ins; you must sign in through Claude Code
  itself, on Anthropic's page. Dieter starts Claude Code's own sign-in on the
  machine and shows you its page and code field. The login stays with Claude
  Code on that machine, and Dieter never reads it.
- **Renewing logins.** Claude and ChatGPT replace a login's refresh token each
  time it renews. If two machines shared one copy, the first to renew would
  silently sign the other one out.

So the accounts, their usage and each machine's sign-in state sync between
your machines, but a login never leaves the machine that signed in, and no
provider data reaches the gateway. **Sign in on all machines** keeps the extra
approvals quick.

## Add an account

- **Mac:** **Settings › Providers**, then **Add account**.
- **iPhone, iPad and Android:** the **Providers** section of **Settings**, then
  **Manage providers** and **Add account**. iPhone and iPad also list
  **Providers** under **More**.

Choose **Claude** or **ChatGPT** and a label. For ChatGPT, also choose how it
signs in: **Codex sign-in** (the default) or **Continue with ChatGPT**
([Sign in with ChatGPT](#sign-in-with-chatgpt)). The app then opens the
sign-in sheet for a machine: on a Mac with its own daemon, that Mac; otherwise
the machine you pick. Until the first sign-in, the account reads **Not signed
in yet**.

## Sign a machine in

On the account, choose **Sign in** next to a machine. The sheet is titled
**Sign in to Claude Code on ‹machine›** or
**Sign in to Codex on ‹machine›**: the provider's own tool signs in on that
machine, and the page you sign in on is always Anthropic's or OpenAI's.

### Claude

1. Choose **Open**. Anthropic's sign-in page opens in your browser. Sign in
   and choose **Authorize**.
2. Anthropic shows a code. Copy all of it, paste it into the sheet and choose
   **Continue**.

When the app runs on the machine it signs in (the Mac app and its own daemon),
the browser hands the sign-in straight to Claude Code and the sheet finishes
without a code. Claude Code waits 30 minutes for the code; after that, start
again.

### ChatGPT with Codex sign-in

The sheet starts with a **device code**:

1. Copy the code (for example `ABCD-EFGHI`) and choose **Open**. OpenAI's
   device page opens.
2. Enter the code, sign in and approve. The sheet finishes by itself.

A code is valid for 15 minutes; the sheet replaces an expired one with a new
code. Device codes must be enabled for your ChatGPT account in its security
settings, and for a Business workspace by an admin. Without them, use the
**browser** sign-in: **Open**, sign in, and the browser returns to Codex on the
machine. Only one browser sign-in can run on a machine at a time, because
Codex always uses port 1455 for it.

### When the browser can't reach the machine

A browser sign-in ends by sending your browser to an address on the machine
that signs in, such as `http://localhost:54545/callback?code=…` (Claude Code)
or `http://127.0.0.1:1455/auth/callback?code=…` (Codex). When the browser runs
on another device, that page does not load. Copy the whole address from the
address bar and paste it under **Paste the address your browser couldn't
open**. The machine hands it to its own sign-in and finishes. The address works
only for that sign-in, once.

### Sign in on all machines

**Sign in on all machines** appears while an online machine lacks a sign-in. It
walks through those machines one after another in the same sheet, with one
approval each: **Authorize** and a code for Claude, the device code for Codex.
A machine that comes online later, or joins your account later, shows **Sign
in** on every account it lacks.

### The login must match

The first sign-in decides whose account it is. If another machine later signs
in with a different login, for example as bob@… while the account is
alice@…, Dieter signs that machine out again at once and reports the
mismatch. Sign in with the account's login, or add the other login as an
account of its own.

## Choose the account for a chat

When you create a task, chat or schedule, the **Account** menu next to
**Provider** (Mac) or the **Account** row in the agent settings (iPhone, iPad
and Android) lists the accounts of the chosen provider. Each shows whether it
can run on the machine that will do the work: signed in, not signed in there,
sign-in expired, or machine offline, and you can't send until the chosen
account is ready. The Mac conversation header and the mobile composer show the
account in use.

If you don't choose, Dieter uses, in this order:

1. the account the conversation used last;
2. the provider's **default** account;
3. the only account of that provider signed in on that machine.

Each provider has one default; set it on the Providers page. The apps also
remember the account you last chose per provider for new work.

**Switching.** You can choose another account of the same provider before any
message. The next turn runs on it and continues the same conversation, with
its history. A running turn keeps its account. The provider itself stays fixed
after the first message.

**When an older Codex thread is unavailable.** Dieter retries a missing-thread
resume once on a new Codex thread and adds a notice to the conversation. Your
history remains visible in Dieter, but Codex does not receive that earlier
context. If your latest message depends on it, the agent asks for the missing
details. Later messages resume the new thread. Other provider errors are
reported without this retry.

**When the account can't run.** The chat shows a notice such as **Work isn't
signed in on box**, with **Sign in** (the sheet for that machine) and **Choose
account**. If a provider rejects a login during work and it cannot be renewed,
the machine's row turns **Sign-in expired** and the chat offers **Sign in
again**. A scheduled run whose account isn't signed in fails and says why in
the schedule's history.

## Usage

Every account shows its plan usage as the provider reports it:

- **Windows.** The 5-hour and weekly windows with the share left and when each
  resets. Claude can add per-model limits and extra-usage spend, ChatGPT its
  credits. An allowance is low at 30% or less and critical at 10% or less.
- **Freshness.** "Updated N min ago". A machine where the account is signed in
  reads usage every few minutes, and turns report new limits as they run; your
  machines share one reading instead of each asking. **Refresh** reads it now.
  Claude Code reports usage itself, without a prompt and without Dieter
  touching its login; Codex reports its rate limits the same way.
- **Dieter's tokens.** The tokens that Dieter's own turns used on the account
  in the last 5 hours and 7 days, summed over your machines. Use outside
  Dieter (claude.ai, ChatGPT, your own CLI) counts against the windows but not
  here. Token counts are what the provider reported, not a cost estimate.
- **Summary.** The Inbox and the Mac and Android desktop sidebars show, per
  provider, the tightest window among the accounts with **Include in summary**
  on. Separate accounts are never added up or averaged. Turn the switch off for
  an account you rarely use.
- **Reset credits (ChatGPT).** When OpenAI grants a rate-limit reset credit,
  the account offers **Reset usage limits**. After you confirm, it spends one
  credit on a machine where the account is signed in and tells you the result:
  limits reset, nothing to reset, no credit left, or already redeemed.

Usage can be stale or missing, for example while no machine with the account
is online.

## Logins and keys already on a machine

Each machine adopts what it already has, when it starts and every 30 minutes:

- A signed-in Claude Code login (`~/.claude`, or `CLAUDE_CONFIG_DIR` when the
  daemon sets it) or Codex login (`~/.codex`, or `CODEX_HOME`) becomes a
  **host login** account named after its email, or joins the account that
  already has that login. Dieter uses it in place: nothing is copied, Dieter
  never signs it out, and your own `claude` and `codex` keep working with it.
- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `CODEX_API_KEY` in the daemon's
  environment becomes an **API key** account of that machine.

So a machine you already used with Claude Code or Codex works on day one. A
host login is also renewed by your own CLI on that machine; an account you add
in Dieter avoids sharing a login that way.

Removing a host login or API key account only hides it until the machine
adopts it again. To stop using one, sign the CLI out on that machine
(`claude auth logout`, `codex logout`) or remove the key from the daemon's
environment.

Dieter's Codex turns use their own Codex home, `DIETER_HOME/codex`, whatever
the account. Its configuration follows your `~/.codex/config.toml` (MCP
servers, features, trusted projects), and your own Codex history stays in
`~/.codex`.

## Sign in with ChatGPT

Sign in with ChatGPT is OpenAI's sign-in for open-source and locally hosted
apps. Choose **Continue with ChatGPT** when you add a ChatGPT account.

- Turns use your ChatGPT plan (Plus or Pro). The composer shows **Using ChatGPT
  plan** with **Manage usage**, which opens OpenAI's usage page.
- Each machine holds its own session and signs in with the browser, so paste
  the address when the browser runs on another device. Machines after the
  first often need no further prompt.
- **No web search** and no hosted tools (image generation, file search, code
  interpreter, hosted MCP servers) on this route. Use a Codex sign-in account
  for chats that need them.
- Usage comes only from what turns report; **Manage usage** shows the rest.
- If OpenAI does not grant plan usage to the sign-in, the account shows that
  plan usage isn't available.

## Sign out and remove

**Sign out** on a machine's row ends that machine's login and deletes it there;
other machines stay signed in. **Remove** on the account signs it out on every
machine and deletes its files there; a machine that is offline does this when
it comes back. Chats that used it ask for another account at their next
message.

Removing a machine from your account does not sign it out of anything. Sign it
out of its accounts first, while it is still reachable.

## Troubleshooting

| Problem                                         | What to do                                                                                                                                                               |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Device codes are disabled                       | Enable device code sign-in in your ChatGPT security settings (for a Business workspace, ask its admin), or use the browser sign-in.                                      |
| Port 1455 is in use                             | Another Codex browser sign-in runs on that machine, perhaps your own `codex login`. Finish or cancel it, or use the device code.                                         |
| The login doesn't match                         | The browser was signed in to a different Claude or ChatGPT login. Sign out there, or use a private window, and sign in again; or add the other login as its own account. |
| Sign-in expired                                 | The provider rejected the login and it could not be renewed, for example after you signed out of all devices or changed your password. Sign in again on that machine.    |
| The sign-in sheet gave up                       | A Claude sign-in waits 30 minutes for its code, and a device code lives 15 minutes before the sheet replaces it. Start again.                                            |
| The page after signing in doesn't load          | It is an address on the machine. [Paste it into the sheet](#when-the-browser-cant-reach-the-machine).                                                                    |
| "Add a Claude account in Settings › Providers"  | No account of that provider can run there. Add one, or sign the machine in.                                                                                              |
| "Work isn't signed in on box"                   | Sign that machine in, or choose another account for the chat.                                                                                                            |
| A ChatGPT chat says web search isn't authorized | The account uses Sign in with ChatGPT, which has no web search. Switch the chat to a Codex sign-in account.                                                              |

## From the CLI

```sh
dieter provider list                                 # accounts, machines, usage
dieter provider add claude --label Work
dieter provider add chatgpt --label Personal         # Codex sign-in
dieter provider add chatgpt --label Plan --method siwc
dieter provider login Work                           # sign this machine in
dieter --machine box provider login Work             # sign another machine in
dieter --machine box provider login Personal --browser
dieter provider check Work
dieter provider logout Work
dieter provider rename Work "Work Max"
dieter provider default Work
dieter provider exclude Personal                     # leave it out of summaries
dieter provider include Personal
dieter provider usage --refresh
dieter provider reset Personal --confirm RESET       # spend a ChatGPT reset credit
dieter provider remove Personal --confirm REMOVE
```

`ACCOUNT` is an account ID (`pa_…`) or a unique label. `add`, `rename`,
`include`, `exclude`, `default` and `remove` change the account on every
machine. `login`, `logout`, `check`, `usage --refresh` and `reset` act on one
machine: this one, or the one global `--machine` names.

`provider login` prints the page to open and, for ChatGPT, the device code,
then waits. For a Claude code it prompts on the terminal without echo, and it
also accepts the address your browser couldn't open. `--device-code` and
`--browser` choose the ChatGPT flow; `--code CODE` and `--callback URL` pass
the input without a prompt. Ctrl-C cancels the sign-in.

Choose the account for work with `--account ID|LABEL`:

```sh
dieter card create --project PROJECT_ID --board BOARD_ID --provider claude-code \
  --account Work --lane running --prompt "Explain the test setup"
dieter card send CARD_ID --account ACCOUNT --message "Continue on this account"
dieter chat create --project PROJECT_ID --provider codex --account Personal \
  --prompt "Trace the failure"
dieter schedule update --account Work SCHEDULE_ID
```

The account must belong to the conversation's provider. Agents may list
accounts and pass `--account` to the work they create, but they cannot add,
rename or remove accounts, change defaults, sign in or out, or spend reset
credits. The [CLI reference](/docs/cli-reference/) lists every option.
