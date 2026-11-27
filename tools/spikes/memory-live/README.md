# Agent memory live test

Real agent turns against the agent memory implementation: two enrolled
working-tree daemons on one Mac, Claude Code (Sonnet) on the host's own login.
Results: [results/2026-11-27.md](results/2026-11-27.md).

| File                 | Purpose                                                                                                        |
| -------------------- | -------------------------------------------------------------------------------------------------------------- |
| `gateway/main.go`    | Loopback gateway copy (`internal/testkit/topology`) that enrolls each `NAME=DIETER_HOME` with one test account |
| `serve.sh NAME PORT` | Runs `bin/dieter serve` on `/tmp/dieter-mem-live/NAME` with the real HOME and an empty `CODEX_HOME`            |
| `d.sh NAME ARGS`     | The working-tree CLI against that daemon only                                                                  |

## Recipe

```sh
go build -o bin/dieter ./cmd/dieter
go build -o /tmp/dieter-mem-live/gateway ./tools/spikes/memory-live/gateway
/tmp/dieter-mem-live/gateway -addr 127.0.0.1:47620 -root /tmp/dieter-mem-live/gateway-state \
  alpha=/tmp/dieter-mem-live/alpha beta=/tmp/dieter-mem-live/beta   # background process
serve.sh alpha 47613; serve.sh beta 47614                            # background processes
d.sh alpha device init                     # first machine starts the roster
d.sh beta device status                    # shows a pairing code
d.sh alpha device approve CODE
d.sh alpha provider list                   # host Claude login adopted (method host)
```

Safety:

- **Never the operator's daemon or `DIETER_HOME`.** Homes, ports
  (47613/47614/47620) and the gateway are throwaway.
- **Claude credentials.** The real HOME lets the accounts engine adopt the
  host's Claude Code login as a `host` account. Turns get `auth: {}` with the
  token variables masked, so Claude Code alone reads and refreshes its login;
  Dieter never touches it. Without enrollment there is no daemon ID, no
  adoption and no account, and the adapter's own discovery (which can refresh
  the token itself) must not be used.
- **Codex.** `CODEX_HOME` points at an empty directory, so the stale host
  Codex login is never adopted or refreshed.
- **Cleanup.** Stop the daemons and the gateway, then remove
  `/tmp/dieter-mem-live` and its Claude session folders under
  `~/.claude/projects/-private-tmp-dieter-mem-live-*`.
