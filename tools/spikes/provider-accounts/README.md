# Provider accounts spike

Spike code for
[docs/proposals/provider-accounts.md](../../../docs/proposals/provider-accounts.md).
It is evidence, not product code: nothing in the main module imports it.

`probe.mjs` runs the agent CLIs pinned in an installed Dieter harness runtime
(`DIETER_HOME/runtime/harness/<digest>`). Each run uses a throwaway `HOME`,
`CLAUDE_CONFIG_DIR` and `CODEX_HOME` and deletes them at the end. `BROWSER`
points at a logging hook, so no browser opens. **No probe completes a
sign-in**, and nothing touches the operator's own `~/.claude`, `~/.codex`
or Keychain.

| Probe                          | What it records                                                                                                                                                                |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `claudeLogin`                  | `claude auth status --json` for an empty config directory. `claude auth login` over plain pipes: the manual URL, the paste prompt, and the localhost URL handed to `$BROWSER`. |
| `claudeResumeAcrossConfigDirs` | A session created in config dir A, then resumed from dir B (`projects/` symlinked to A's) and dir C (isolated). Uses a bogus OAuth token.                                      |
| `codexProtocol`                | Generates the app-server JSON schema and lists the `account/login/start` variants and account server requests.                                                                 |
| `codexBrowserLogin`            | `account/login/start {type: "chatgpt"}`, then cancel: the auth URL, client ID and loopback callback, plus what `CODEX_HOME` holds.                                             |
| `codexDeviceCodeLogin`         | `account/login/start {type: "chatgptDeviceCode"}`, then cancel: the verification URL and user-code shape.                                                                      |

PKCE challenges, `state` values, user codes and local paths are redacted.
Starting a device-code login asks OpenAI for a code that nobody approves. The
resume probe sends one request that Anthropic rejects with 401. Apart from
those, the probes generate no provider traffic.

```sh
mise exec -- node tools/spikes/provider-accounts/probe.mjs \
  --runtime "$DIETER_HOME/runtime/harness/<digest>" \
  --out tools/spikes/provider-accounts/results/<date>-<platform>.json
```

`results/2026-11-13-darwin-arm64.json` is the run behind the proposal: Claude
Code 2.1.317 and Codex 0.166.0 from runtime digest `f42096d8…`.

The probes that need a real account (completing a login, token refresh inside
a turn, Sign in with ChatGPT) are listed under Phase 0 in the proposal. They
run only with the account owner's approval.

## Live scripts (Phase 0)

The `live/` scripts drove the Phase 0 checks on real accounts, with the
account owner completing each sign-in in a browser. They use throwaway
directories (`mode 0700`), and every login they create must be signed out
afterwards.

| Script       | What it does                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `holder.mjs` | Holds one official login open the way the daemon's login session would: `claude` (`claude auth login`), `codex` (app-server `account/login/start`, device code or browser) or `siwc` (Sign in with ChatGPT: dynamic registration or re-authorization with `id_token_hint`). It writes `challenge.json`, takes a pasted code or a forwarded loopback redirect from `DIR/input`, and writes `result.json`. |
| `turn.mjs`   | Runs one turn through `runner.mjs`'s adapters, local sandbox and `HarnessAgent`, with an explicit adapter `auth` (`--auth`, `--auth-from-env`) and optional resume, so account wiring and account switching can be checked.                                                                                                                                                                              |
| `usage.mjs`  | Reads `accountInfo()` and plan usage from the official Claude Code binary through a prompt-less SDK query.                                                                                                                                                                                                                                                                                               |
| `parity.mjs` | Lists the commands, agents and MCP servers a Claude config directory gives a session, to compare shadow and default directories.                                                                                                                                                                                                                                                                         |

`results/2026-11-14-phase0.json` is the redacted outcome. It contains no
tokens, email addresses or account IDs.
