# ADR 0007: Oh My Pi on Dieter's managed Claude and ChatGPT accounts

- Status: accepted 2026-11-27, implemented on the `omp-managed-accounts` branch
- Proposal: [docs/proposals/omp-managed-accounts.md](../proposals/omp-managed-accounts.md);
  it replaces the credential, model and advisor parts of
  [managed-oh-my-pi.md](../proposals/managed-oh-my-pi.md)
- Supersedes in part: [ADR 0006](0006-provider-accounts.md), its rule "Dieter
  never reads, stores, refreshes, replicates or injects Claude.ai
  credentials", for one case: Oh My Pi turns on Claude accounts with Oh My Pi
  access

## Context

Oh My Pi (OMP) ran from Dieter's pinned runtime on the operator's own
`~/.omp/agent`: its logins in `agent.db`, its `models.yml` and `config.yml`,
and `OMP_PROFILE`. The catalog showed three fixed Codex models. The advisor was
a boolean option that passed `--advisor` and used whatever
`modelRoles.advisor` said in `~/.omp`, so Dieter could neither show nor choose
it. Users asked to run OMP's implementation model and its advisor on the
Claude and ChatGPT accounts Dieter already manages
([ADR 0006](0006-provider-accounts.md)), chosen in the apps like the account
of a Claude Code or Codex chat, and possibly on two different providers.

The spike behind the proposal (§2 and §7.1) used the pinned OMP 19.2.1 and
found:

- **OMP needs no login of its own.** A `models.yml` `apiKey: "!command"` beats
  any login stored in the agent directory. OMP runs the command with
  `/bin/sh` and a 10-second limit, caches its output per process, and reruns
  it after a 401. One process holds one credential per provider, so the main
  model and the advisor can run on two providers' accounts at once.
- **Unpinned roles leak.** OMP routes auxiliary requests (skill-description
  hints, titles, commit messages) through chat roles. An unpinned role falls
  back to the main model or, through OMP's own priority chains, to the other
  provider's account.
- **Launch flags break resume.** The ACP adapter hashes the launch arguments
  and the forwarded environment names into a session's identity. Changing
  `--model`, `--thinking` or `--advisor` between turns makes resume fail. A
  resumed session takes a new advisor from a settings overlay but keeps its
  stored model and thinking level; those change through ACP config options.
- **Claude Code can be asked to refresh.** Its prompt-less usage probe (the
  Agent SDK's account and usage call, which Dieter already runs per account)
  makes Claude Code renew a due login and write its own store.
  `claude auth status` does not refresh.
- **Live checks passed.** L1 to L5 ran on real Claude Max and ChatGPT Pro
  logins: both providers in either role, a refresh of an expired Claude login
  by Claude Code in about one second, and a Claude Code turn and an OMP turn
  on one login at the same time, with the Keychain item untouched by OMP.

ChatGPT needs no rule change: Dieter already reads, refreshes (through Codex's
app-server) and serves Codex access tokens to turns. Two facts make Claude a
policy decision rather than a technical one:

- **Anthropic's terms.** Third-party developers may not "route requests
  through Free, Pro, or Max plan credentials on behalf of their users" or
  "collect, store, or intermediate Claude.ai credentials or session tokens"
  ([legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)).
  ADR 0006 built the provider accounts around that text.
- **OMP impersonates Claude Code.** Its Anthropic requests carry Claude Code's
  user agent, its billing header and "You are Claude Code, Anthropic's
  official CLI for Claude." as the system prompt. That is what makes
  subscription tokens work for OMP. Anthropic can detect or block it at any
  time, and an account used this way can be blocked or suspended, server-side
  and without notice.

## Decision

The owner accepts the Claude risk for accounts that opt in (decision D1,
2026-11-27). OMP runs only on Dieter's provider accounts, with access tokens
the daemon serves to each turn, and holds no login of its own.

### Claude: access tokens only, per account and opt-in

- **Oh My Pi access.** A Claude account has an `ompAccess` flag: "Allow Oh My
  Pi to use this login" in Settings › Providers, or
  `dieter provider omp-access ACCOUNT on|off`. It is off by default. A person
  turns it on, after the apps state Anthropic's terms and the account risk.
  Changing it is a `ProviderAccountService` mutation, which refuses a turn
  token, so an agent cannot turn it on. ChatGPT accounts have no flag, and the record
  schema refuses one.
- **What the daemon reads.** Only for an OMP turn on an account with Oh My Pi
  access, the conversation's owner daemon reads the access token and its
  expiry from Claude Code's own store for the account's config directory. On
  macOS that is the login Keychain item `Claude Code-credentials` for the host
  login, or `Claude Code-credentials-<sha256(dir)[:8]>` for a per-account
  directory, named after the exact `CLAUDE_CONFIG_DIR` string; on Linux it is
  `.credentials.json` in the directory. It decodes only the access token and
  its expiry. The refresh token is never decoded, used or stored, and the
  daemon never writes the store (`internal/engine/accounts/exec_claude_token.go`).
- **Claude Code stays the only refresher.** When the access token expires
  within five minutes (Claude Code's own refresh window), the daemon runs the
  account's usage probe with its `CLAUDE_CONFIG_DIR`, under the account lock.
  Claude Code renews the login before that request and writes its own store;
  the daemon then reads the store again. If the token is still not valid, the
  daemon marks the login expired and refuses the turn
  (`internal/engine/accounts/omp.go`).
- **Where the token goes.** Only to the OMP process of the turn that runs on
  the account, through the token helper below. Never into a file, an
  environment variable, the vault, a KV record, a log, a client or another
  machine.
- An Anthropic API key account (the daemon's `ANTHROPIC_API_KEY`) serves its
  key the same way and needs the same flag.

### ChatGPT: Codex logins

- OMP's `openai-codex` provider talks to the ChatGPT Codex backend, which
  accepts ChatGPT logins only. Codex sign-in accounts and host Codex logins
  qualify. Sign in with ChatGPT accounts and API key accounts
  (`OPENAI_API_KEY`, `CODEX_API_KEY`) are refused.
- The daemon reads the access token from the account's Codex auth home. When
  it is due, Codex's app-server refreshes it (`account/read` with
  `refreshToken: true`) under the account lock, as for Codex turns. OMP
  derives the ChatGPT account header from the token itself.

### The token helper

- Every Dieter OMP process uses the managed agent directory
  `DIETER_HOME/omp/agent` (`PI_CODING_AGENT_DIR`). The daemon renders its
  `models.yml`, which is the same for every turn and holds no secret:

  ```yaml
  providers:
    anthropic:
      apiKey: "!'<dieter>' provider token --turn --provider claude"
    openai-codex:
      apiKey: "!'<dieter>' provider token --turn --provider chatgpt"
  ```

- `dieter provider token --turn --provider claude|chatgpt` calls
  `GetProviderTurnToken` with the turn's `DIETER_TURN_TOKEN`, on the local
  route only; `--machine` is refused. The daemon accepts a provider only from
  an OMP conversation and returns the token of that turn's own account for the
  provider: the implementation account or the advisor account. A provider the
  turn has no account for fails at once, without a refresh, so OMP's startup
  discovery and any role Dieter did not pin cannot reach another account.
- Admission resolves the accounts and makes their tokens fresh before the
  turn starts, so the helper is a plain read inside OMP's 10-second limit. A
  401 in the middle of a turn makes OMP rerun the helper, which asks the
  provider's tool to refresh when the token is due.

### Accounts and the advisor

- The implementation account is `HarnessSelection.account_id` (`--account`).
  Its provider follows from the model prefix: `anthropic/` runs on Claude
  accounts, `openai-codex/` on ChatGPT accounts. A conversation that moves to
  the other provider's models drops its previous account, and the usual
  fallback picks one: the provider's default, then the only account signed in
  on the owner machine.
- The advisor is OMP's own advisor role: a second model that reviews the
  implementation model's work and adds notes. Three mutable provider options
  set it: `advisor_model` (`off` or one of the seven OMP models),
  `advisor_effort` (`low`, `medium`, `high`, `xhigh` or `max`; default
  `medium`) and `advisor_account` (an account ID).
- An advisor on the implementation model's provider runs on the
  implementation account, because OMP holds one credential per provider;
  `advisor_account` is then not used. An advisor on the other provider runs on
  `advisor_account`, else that provider's default, else the only account of
  that provider signed in on the machine; an `advisor_account` of another
  provider, left from an earlier advisor model, counts as empty. Admission
  records the resolved account in `advisor_account`, so later turns keep it.
- Both accounts must be signed in on the owner daemon, and a Claude account
  needs Oh My Pi access. Otherwise admission fails with `FailedPrecondition`.

### Managed models, home and launch identity

- **Clean break.** Dieter no longer uses `~/.omp`, `OMP_PROFILE`, OMP's own
  logins, its `config.yml`, `models.yml` or custom models. The managed
  directory holds no login and is never replicated. The OMP worker's
  environment drops `OMP_PROFILE`, `PI_AGENT_DIR`, `CLAUDE_CONFIG_DIR`,
  `CLAUDE_CODE_OAUTH_TOKEN`, the AI Gateway credentials and every
  `ANTHROPIC_*`, `OPENAI_*` and `CODEX_*` variable, also when
  `DIETER_HARNESS_ENV` names one (`internal/harness/omp_home.go`).
- **Managed models.** The catalog lists seven models without discovery:
  Claude Opus 5.5, Sonnet 5.5, Haiku 5.5 and Fable 5.2, and GPT-6 Sol, Astra
  and Luna, with thinking from low to max. Model, thinking and account may
  change between turns.
- **Constant launch.** OMP starts as `omp acp --config <overlay> --hook <hook>`,
  both at fixed per-conversation paths under the runtime's `harness-config`
  directory, with a fixed list of forwarded environment names (among them
  `DIETER_HOME`, `DIETER_CARD_ID` and `DIETER_TURN_TOKEN`). The ACP identity
  therefore stays the same when the model, thinking, advisor or account
  changes.
- **Per-turn values.** The model reaches OMP through the ACP `model` config
  option on every turn. Dieter's capabilities hook applies the thinking level
  from a per-conversation turn file at the start of each prompt. The overlay
  carries Dieter's runtime settings, pins every chat role (`default`, `smol`,
  `slow`, `vision`, `plan`, `commit`, `tiny`, `memory`, `task`, `widget`) to
  the implementation model, and either sets the advisor (`modelRoles.advisor`
  with its effort, `reviewMode: agent-end`, `syncBacklog: strict`) or turns it
  off.
- **Earlier conversations.** An OMP session started under `~/.omp` cannot
  resume in the managed directory. The conversation's next message starts a
  new OMP session, and Dieter tells the agent that it lacks the earlier
  context, as for a lost Codex thread.

### Sync and compatibility

`ompAccess` is a field of the replicated `provider-accounts` record, omitted
while off and valid only on Claude accounts. The release line stays at 0.7.
Records without the opt-in read as before. A daemon older than this change
cannot read a record that has it; it holds that record, unmerged, until it
updates.

### Alternatives considered

| Option                                                                                   | Why not                                                                                                                                                                                                                                                          |
| ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Static environment tokens (`ANTHROPIC_OAUTH_TOKEN`, `OPENAI_CODEX_OAUTH_TOKEN` per turn) | Works, but cannot refresh inside a turn: a Claude access token lives 8 hours, and a turn that outlasts it fails. The token also sits in the worker's environment for the whole turn.                                                                             |
| Dieter as OMP's auth broker (`omp auth-broker` protocol: snapshot and refresh endpoints) | The same outcome as the helper, for far more code tied to an internal OMP protocol of about 5,700 lines that changes with OMP releases.                                                                                                                          |
| OMP's own logins (`omp login` per account, driven from Settings › Providers)             | Still a Claude login in a third-party tool, so the same terms issue. It adds a second sign-in per account and machine and a second rotating grant that OMP refreshes, which can race or be revoked. One agent directory cannot hold different accounts per role. |
| Keep the operator's `~/.omp` models and endpoints next to the managed ones               | Credentials and endpoints outside Dieter's accounts would reach turns again, and the operator's `config.yml` would beat Dieter's settings. It can return later as an explicit "extra providers" setting.                                                         |
| No Claude for OMP (managed-oh-my-pi D1)                                                  | Keeps the invariant, but not what the owner asked for: Claude models would need an API key, and Opus on a subscription a cross-harness advisor run by Claude Code.                                                                                               |

## Consequences

- [invariants.md](../invariants.md) states the Claude credentials rule with
  this one exception and its limits. Every login still has exactly one
  refresher, and for Claude logins that stays Claude Code.
- Accounts with Oh My Pi access are exposed to Anthropic's enforcement. Each
  OMP release may change its Claude Code imitation, so OMP stays pinned
  exactly, and a bump re-runs the probes against the fake upstream
  (proposal, Appendix A).
- The agent inside an OMP turn can run the helper itself, because it has the
  turn token, and so read its own turn's access tokens: hours for Claude,
  days for ChatGPT, never a refresh token. A Sign in with ChatGPT turn could
  already do this. The [threat model](../threat-model.md) records it.
- OMP turns count against the same plan usage that Claude Code and Codex
  turns show. An advisor adds a second model's usage; pinned roles and a
  review at the end of the run keep that bounded.
- OMP turns need a signed-in account on the owner machine, like Claude Code
  and Codex turns. OMP no longer runs model discovery.
- A tuned `~/.omp` (custom models, endpoints, profiles) no longer applies in
  Dieter; `omp` run outside Dieter keeps it. Existing OMP conversations
  continue in a new OMP session without the old session's context.
