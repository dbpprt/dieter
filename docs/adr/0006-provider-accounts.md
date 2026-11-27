# ADR 0006: Provider accounts (Claude and ChatGPT sign-in per machine)

- Status: accepted, implemented 2026-11
- Proposal: [docs/proposals/provider-accounts.md](../proposals/provider-accounts.md);
  build plan: [provider-accounts-implementation.md](../proposals/provider-accounts-implementation.md)

## Context

Agent turns used whatever Claude Code or Codex login the daemon host had. A
person set it up by hand on each machine (`claude auth login`, `codex login`),
every turn on that machine used the same login, and no app could see or change
it. Users asked to sign in from any app, keep several accounts per provider,
choose the account per chat, and see the same accounts on every machine.
Plan usage came from a separate pipeline: daemons read the tools' OAuth tokens,
called the providers' usage endpoints and sent normalized quota snapshots to
the gateway, which stored them per account.

Two facts constrain any design:

- **Anthropic's terms.** Third-party developers "may not collect, store, or
  intermediate Claude.ai credentials or session tokens — sign-in to a Claude
  account must complete through Anthropic's own flow". An end user may sign in
  to the unmodified Claude Code binary, also where a platform hosts it.
- **Rotating refresh tokens.** Claude, Codex and Sign in with ChatGPT all
  rotate refresh tokens. Two machines holding a copy of one login race at
  refresh, and the loser's login dies: Claude Code wipes it, Codex reports
  `refresh_token_reused`. OpenAI says "Do not share the same file across
  concurrent jobs or multiple machines".

The spike behind the proposal also found that the bundled Claude adapter read
and refreshed Claude Code's OAuth token itself and passed an 8-hour access
token without a refresh token into the turn, the cause of the 401s at the
8-hour boundary.

## Decision

Accounts synchronize; credentials do not.

- **No Claude credentials in Dieter.** Dieter never reads, stores, refreshes,
  replicates or injects Claude.ai credentials. Claude Code owns each login: it
  signs in with its own `claude auth login` against Anthropic's pages, into its
  own store, inside a per-account config directory
  (`DIETER_HOME/provider-accounts/<id>/claude`). On macOS that store is a
  Keychain item named after the exact directory path; on Linux it is
  `.credentials.json` in the directory. The daemon starts the login process on
  its machine and relays its URL and the code a person pastes, as a terminal
  running the same command would. Turns get the directory as
  `CLAUDE_CONFIG_DIR` and the runner passes `auth: {}` to the adapter, so
  Claude Code refreshes its own token, also in the middle of a turn. The
  directory links the user's shared Claude configuration (`projects/`,
  `settings.json`, skills, agents, commands, plugins) from `~/.claude`, so a
  conversation can change account between turns and keep its session.
  _Superseded in part by [ADR 0007](0007-oh-my-pi-managed-accounts.md):_ for
  an Oh My Pi turn on a Claude account with Oh My Pi access, the daemon reads
  the login's access token (never the refresh token) from Claude Code's store
  and serves it to that turn; Claude Code stays the only refresher.
- **One login per account and machine.** Every machine signs in to an account
  on its own and holds the only copy of that login, so each login has exactly
  one refresher. The apps' "Sign in on all machines" sheet walks through the
  machines, one approval each.
- **ChatGPT, two methods.** Codex's own login (device code, or a browser with
  the loopback callback forwarded) keeps its tokens in a per-account Codex auth
  home that no turn uses. Sign in with ChatGPT, OpenAI's program for
  open-source and locally hosted apps, keeps one session per machine in
  `siwc.json`, with a host ID derived from the daemon's roster key. Every
  Dieter Codex process uses one Dieter-owned `CODEX_HOME`, `DIETER_HOME/codex`,
  whose rendered `config.toml` declares the token provider globally; the
  account only changes the access token the daemon hands the turn.
- **Existing logins are adopted, not copied.** A machine's own CLI logins
  (`~/.claude` or `CLAUDE_CONFIG_DIR`, `~/.codex` or `CODEX_HOME`) and provider
  API keys in the daemon's environment appear as `host` and `environment`
  accounts. They are used in place, and Dieter never signs them out.
- **Replicated records, no secrets.** Account metadata (`provider-accounts`),
  the default per provider (`provider-account-defaults`) and each machine's
  login state with its usage observations (`provider-logins`, key
  `<account>.<daemon>`, written only by that daemon) are KV records. They
  replicate between the account's daemons over the same mutually
  authenticated, end-to-end encrypted carriers as other peer records, and are
  never stored on the gateway. Go validates them strictly (at most 16 usage
  windows, 8 KiB per value); the public KV API and the generic peer-write path
  refuse them, so only `ProviderAccountService` writes them.
- **Credentials never leave the machine that signed in.** Claude Code's store,
  the Codex auth homes and `siwc.json` (mode 0600) stay under that machine's
  `DIETER_HOME`. They never enter KV, the vault, a client or the gateway.
  Clients see sign-in URLs, device codes and the code a person pastes, never a
  token.
- **Selection per turn.** `HarnessSelection.account_id` names the account. It
  may change between turns (the catalog's `account-selection` capability at
  `between-turns` for Claude Code and Codex) and resolves on the
  conversation's owner daemon: the explicit choice, then the conversation's
  last account, the provider's default, and the only account signed in on that
  machine. An account that is not signed in there fails admission with
  `FailedPrecondition`.
- **Agents cannot manage accounts.** Every `ProviderAccountService` mutation
  (adding, renaming, removing, defaults, sign-in, sign-out, resets) refuses a
  turn token. Agents may list accounts and pass `--account`, because accounts
  are not secrets.
- **Usage lives on the accounts.** Each machine reads the plan usage of its
  signed-in logins through the providers' own tools (Claude Code's usage call
  in the Agent SDK, Codex app-server rate limits), adds the limits reported
  during turns and Dieter's own token totals, and writes them into its login
  record. Machines skip a probe that another machine ran recently. The gateway
  quota pipeline (its RPCs, link frames, tables and the daemon's
  `internal/providerquota`) is deleted.

### Alternatives considered

| Option                                                               | Why not                                                                                                                                                                                                                                     |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sync OAuth credentials through the vault                             | Claude forbids it ("store, or intermediate"). For both providers, rotating refresh tokens make the copies on different machines invalidate each other.                                                                                      |
| One `claude setup-token` per account, distributed through the vault  | It is a one-year, inference-only token that cannot be revoked. Anthropic documents setting it wherever you authenticate, but Dieter storing and distributing it is "store". Its scope also lacks `user:profile`, which reading usage needs. |
| A custodian daemon that refreshes logins and hands out access tokens | For Claude, that is intermediating. For ChatGPT, it is a single point of failure that defeats per-host attribution and revocation, and Sign in with ChatGPT expects one session per host.                                                   |
| Keep the gateway quota pipeline beside the accounts                  | Usage belongs to an account, and the accounts already replicate between daemons. Joining gateway rows to accounts needed a correlation key and kept provider account metadata on the gateway, which the end-to-end design otherwise avoids. |

## Consequences

- Each machine signs in to each account once. A machine that joins later shows
  **Sign in** on every account it lacks. That costs a few extra approvals and
  buys compliance and logins that never race each other.
- The gateway stores no provider data: its provider tables are dropped and its
  quota RPCs and link frames are gone. The release that ships this raises the
  client and daemon floors.
- `docs/invariants.md` states the provider-login rules, and the
  [threat model](../threat-model.md) lists the per-account login directories,
  Codex auth homes, `siwc.json` and the token ledger as assets.
- The relayed Claude code is useless without the PKCE verifier, which never
  leaves the Claude Code process, and Dieter never logs it. Whether Anthropic
  counts relaying the login URL and the pasted code as "intermediating" is not
  settled by its text. The apps never present a Dieter-branded Claude sign-in:
  the action reads "Sign in to Claude Code on ‹machine›", and the page is
  Anthropic's.
- An agent that reads `DIETER_HOME` directly can still read the Codex and Sign
  in with ChatGPT token files and run `claude` with an account directory, the
  same residual risk as `~/.claude` and `~/.codex`. A turn on a Sign in with
  ChatGPT account can fetch its own account's current access token
  (`GetProviderTurnToken`), because Codex's provider command needs it to renew
  1-hour tokens inside long turns.
- Login records carry no owner signature. A malicious peer can forge another
  machine's login state and show a wrong picture, but it cannot obtain a
  credential; machines of one account already trust each other.
- Removing a machine from the roster leaves its provider logins on that host.
  Sign it out of its accounts while it is still reachable.
- Dieter's Codex conversations live in `DIETER_HOME/codex`. The user's own
  Codex history stays in `~/.codex`, untouched, and Dieter Codex threads
  created under `~/.codex` before this change do not resume.
- Chats on a Sign in with ChatGPT account have no web search and no hosted
  tools, because the plan route refuses them.
- Claude Code's login output and flags can change between releases. The
  runtime lockfile pins the CLI, so such a change arrives only with a runtime
  update, and the login driver is checked against it then.
