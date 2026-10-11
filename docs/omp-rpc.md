# Native OMP RPC

Dieter runs pinned OMP 18.4.4 with `--mode rpc-ui` and negotiates native protocol
v2. No native-client code, schema, or question UI is added. Streaming text,
reasoning, tool calls/results, token usage, subagent progress and todo phases use
the existing conversation protocol. Dieter host tools are registered with
`set_host_tools`; they do not replace OMP's configured MCP servers.

OMP's ACP factory disables local MCP discovery and expects the client to supply
the server list. This explained why BrowserOS Neo was available in ordinary OMP
on mini-home but absent from Dieter. Native RPC uses OMP's normal discovery.

## Configuration and plugins

Configure OMP on the conversation's execution host. Dieter inherits `HOME`,
`PI_CODING_AGENT_DIR`, `OMP_PROFILE`, and `PI_CONFIG_FILES`, and lets OMP resolve
user/project settings, `mcp.json`, enabled/disabled MCP servers, skills,
extensions and installed plugins. A configured OpenViking OMP plugin is
discovered through the same mechanism; its service must be available to that
host and the plugin must support OMP's RPC environment. Dieter does not translate
Codex or Claude plugin packages into OMP plugins.

The model and thinking effort come from the conversation selection. Dieter's
small settings overlay retains long provider stream timeouts and disables native
asynchronous/background execution, because durable background processes belong
to Dieter's process manager. Tool approval mode remains Dieter's existing
allow-all policy. Other OMP settings and discovery stay enabled. Extra
provider/plugin environment variables can be explicitly forwarded with
`DIETER_HARNESS_ENV` on the daemon host; named MCP environment entries remain
OMP-owned.

OMP owns provider authentication locally. Existing OMP logins continue to work;
this change does not import or copy Codex/Claude credential stores. Automatically
reusing those foreign logins would require a separate credential integration.

## Questions and commands

Native select, confirm, input and editor dialogs appear as text in the existing
chat. The provider waits on the original RPC request between human messages.
Reply with an option number/exact label, yes/no, or the requested text. Invalid
answers keep the question pending. `/cancel` answers with native cancellation;
the conversation Cancel operation stops the provider process. Archiving a card
also stops a pending question. Native dialog timeouts are respected; if a question
expires, the next message continues the saved conversation.

OMP's built-in `ask` can issue multiple sequential dialogs (including multi-select
and custom input); each is answered through chat. Notifications, command output,
and native extension messages also appear in the transcript. Terminal widget
layout, editor decorations and custom terminal components are not client UI
features; OMP itself does not expose arbitrary terminal components over RPC.

`/compact` and `/handoff` use their native RPC commands, whose responses arrive
after work finishes. Other supported text-mode slash commands use native prompt
dispatch. Synchronous `agentInvoked: false` responses finish without waiting for
a `prompt_result`. Agent turns wait for the correlated result and, when needed,
`session_settled`, rather than treating `agent_end` as completion.

## Persistence and process ownership

Native OMP session files and private bridge state live under the conversation's
central Dieter runtime root. An authenticated Unix socket connects the worker to
an owned bridge process. The bridge has its own process group, including OMP,
stdio MCPs and tool subprocesses; cleanup verifies its identity before signaling
that group. No public listener or gateway credential storage is introduced.

The bridge fsyncs native events before forwarding them. Worker suspension stores
the original request identity, stream state and replay cursor. Reattachment
replays events and does not resubmit inference. If that bridge is lost, restart
recovery fails explicitly; a later human turn can resume saved provider history.
Pending question bridges survive daemon startup cleanup, while cancel, failure
and archive cleanup remove them.

Native frames are bounded to 1 MiB per physical line and 64 MiB after v2 chunk
reassembly. Invalid/interrupted chunks fail the turn. The replay journal is
bounded to 128 MiB/100,000 events; the worker queue to 128 MiB/4,096 events.
Large tool inputs/results have explicit bounded transcript previews; OMP retains
their full contents in its session. Large text frames are emitted as bounded UI
chunks. Retention overflow fails rather than dropping events or replaying work.

Completed ACP conversations reopen their exact saved OMP identity via native
`--resume`. Dispatched ACP turns keep their pinned worker and transport until
completion, preserving release-restart recovery. The next human message uses RPC.

## Verification

The ordinary harness suite runs deterministic native process fixtures for host
tools, argument validation, questions, invalid answers, replay without repeated
inference, cancellation, native settlement, local commands, compaction responses,
usage/progress and corrupt/oversized protocol frames:

```sh
mise exec -- just pipeline check component:portable operation:harness_test
```

The opt-in live gate uses the real Go worker, pinned Bun/OMP and the configured
`tailscale/glm-5.3-flash-exl3` route. It discovers an isolated packaged MCP server,
a disabled server, extension tools and a task agent; checks host tools, built-in
and extension questions, session history, progress, local commands, suspension,
reattachment and cancellation. A daemon API test exercises normal chat answers
and archive cleanup through the unchanged Connect/protobuf interface:

```sh
DIETER_TEST_OMP_RPC_E2E=1 mise exec -- go test -v ./internal/harness ./internal/server \
  -run 'TestSubprocessRunnerOMPNativeRPC|TestOMPNativeRPCConversationEndToEnd' -count=1
```

Set `DIETER_TEST_OMP_MODEL` to another configured OMP selector when appropriate.
Tests use private Dieter roots and projects and leave the operator daemon and
system configuration running. They require Node, npm, network access and the
execution host's configured model. They do not install OpenViking or navigate
BrowserOS; the investigation separately verified BrowserOS MCP initialization
and its 22 advertised tools on mini-home.
