# DeepSeek Harness (`dsh`) integration

Status: implemented and validated against `@deepseek-ai/dsh` `0.1.2-rc.1`.

## Proposal and decision

Dieter treats DeepSeek Harness as a generic ACP agent. DSH owns provider
routes, credentials, models, defaults, and reasoning configuration. Dieter
owns only the durable conversation, catalog projection, model selection,
stream translation, task-plan projection, and process lifecycle.

The integration therefore:

1. starts the official `dsh --profile acp` application through
   `@ai-sdk/harness-acp`;
2. asks that same ACP application for its standard `model` session option;
3. shows only the model values DSH advertises;
4. sends the selected opaque value back through ACP without interpreting the
   provider configuration; and
5. never imports another harness's configuration or writes a provider profile.

This keeps deployment policy where DSH defines it. A machine that should offer
one local model configures one model in DSH; Dieter then displays that one
model. Another DSH installation can expose a different catalog without a
Dieter rebuild.

## Research findings

### DSH has the required public control surface

The `acp` profile is DSH's automation-only ACP v1 application. It supports
session create, list, resume, close, prompt, cancel, MCP attachment, model
selection, and reasoning selection. `session/new` returns `configOptions`.
DSH's standard `model` select option groups models by provider and assigns each
choice an opaque JSON string containing `[provider, model]`.

The value is intentionally opaque at the ACP boundary. Dieter decodes it only
to create a readable `provider/model` catalog ID, preserves the original bytes
as `runtimeModel`, and returns those bytes unchanged when selecting the model.
The currently selected DSH route is ordered first and becomes Dieter's dynamic
default.

Primary sources:

- [DSH ACP package contract](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.1.2-rc.1/packages/acp/acp/README.md)
- [DSH model-control implementation](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.1.2-rc.1/packages/acp/acp/src/model-control.ts)
- [DSH ACP control-surface E2E](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.1.2-rc.1/apps/cli/tests/profiles/acp/tests/control-surface.e2e.ts)
- [DSH ACP application profile](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.1.2-rc.1/packages/bundle/acp-app/cordis.patch.yml)

### Provider configuration belongs to DSH

DSH composes a profile from shipped bundle patches, the profile patch,
`$DSH_HOME/cordis.patch.yml`, and launch patches, in that order. Its base
bundle mounts a direct DeepSeek adapter and a dormant multi-provider `pi-ai`
adapter. `$DSH_HOME/settings.yaml` can configure provider routes, while
`$DSH_HOME/.credentials.yaml` or referenced environment variables provide
credentials.

The multi-provider adapter explicitly supports installed provider catalogs and
declared OpenAI-compatible or self-hosted gateways. Its `models` list replaces
a route's catalog. Consequently, narrowing a deployment to one model is native
DSH configuration and needs no Dieter code.

Primary sources:

- [DSH CLI profile and configuration precedence](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.1.2-rc.1/apps/cli/reference/README.md)
- [DSH base bundle composition](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.1.2-rc.1/packages/bundle/base/cordis.patch.yml)
- [DSH multi-provider adapter](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.1.2-rc.1/packages/llm/llm-pi-ai/README.md)

### The AI SDK branch supports native per-turn model selection

AI SDK PR [vercel/ai#19958](https://github.com/vercel/ai/pull/19958), branch
`fa/allow-per-turn-update-of-harness-model`, moved ACP model selection from
launch-time resolution to per-turn `HarnessAgent` settings and static
`modelMapping` metadata. It merged as `8961fdeac49c6bf150eb91f79440d5da204692b8`
and shipped in `@ai-sdk/harness-acp` `1.0.32`. Dieter's pinned `1.0.40`
contains that work.

Dieter maps `HarnessAgent.model` to DSH's standard `model` session option. A
model can change between completed turns while the DSH session and conversation
history remain intact.

The current AI SDK ACP adapter does not expose the agent's configuration
catalog as a host API. For discovery, Dieter uses the adapter's public
`prepareSandboxForHarness` bootstrap recipe to install the exact same pinned
DSH implementation, then performs the minimal standard ACP handshake directly:

```text
initialize
  -> session/new
     <- configOptions[model]
  -> session/close
```

This is a read-only catalog probe, not a second execution integration. All
actual turns, resume, cancellation, tool events, and stream output remain on
the AI SDK harness path.

## Runtime design

```text
Dieter catalog refresh
  -> pinned AI SDK ACP bootstrap
  -> configured DSH `acp` profile
  -> `session/new.configOptions[model]`
  -> dynamic Dieter models

Dieter turn
  -> HarnessAgent(model = DSH opaque selector)
  -> @ai-sdk/harness-acp modelMapping
  -> DSH persistent ACP session
  -> DSH-configured provider/model
```

The release registry contains only a `Configured default` compatibility entry
with an empty runtime model. It allows a turn to defer completely to DSH when
discovery is unavailable and keeps existing conversations valid. After a
successful refresh, the compatibility entry is hidden and only discovered DSH
models are returned to clients.

Discovery uses a five-minute cache. The first probe may install the pinned DSH
package; later probes reuse the AI SDK bootstrap marker. A global `dsh`
installation is unnecessary. Discovery starts only after `DSH_HOME` (default
`~/.dsh`) exists, so an uninitialized machine does not download a harness merely
because a client opened a model picker.

The probe disables telemetry and overrides DSH's session and storage rows with
Dieter-owned catalog-only paths. It therefore does not add a catalog-only
conversation to the operator's DSH session history. The child receives the
same filtered environment as a normal Dieter worker. Additional provider
variables must be named explicitly in `DIETER_HARNESS_ENV`.

## Turn behavior

- The DSH package version is exact because the upstream release is a developer
  preview and may make breaking changes.
- DSH's persistent ACP session ID is stored in Dieter's provider continuation
  envelope and resumed on later turns.
- Cancellation and daemon suspension use the same bounded ACP lifecycle as the
  existing ACP harness.
- DSH-owned tools are provider-executed dynamic tools. This prevents AI SDK UI
  conversion from validating them against Dieter's host-tool catalog.
- `todo_write` becomes Dieter's versioned task-plan snapshots.
- DSH does not advertise Dieter's subagent capability because standard ACP
  does not expose enough nested-agent lifecycle detail for that claim.

## Deliberate limits

DSH's ACP response does not attach context-window metadata to model choices, so
Dieter does not invent it. Context usage remains available when DSH reports it
during a turn.

DSH exposes reasoning as a second, model-dependent ACP option. The pinned AI
SDK adapter maps one `HarnessAgent.model` value to one ACP operation, so Dieter
currently maps the model and leaves reasoning at DSH's configured default.
Exposing reasoning would require upstream support for applying multiple typed
session options per turn; generating a provider patch in Dieter would violate
the ownership boundary above.

## Configuration

Initialize and configure DSH independently, using its Web Models page or its
documented files under `DSH_HOME`. Then request Dieter's harness catalog again.
If a provider credential is referenced through a nonstandard environment
variable, opt that variable into the worker environment:

```sh
export DIETER_HARNESS_ENV=LOCAL_MODEL_API_KEY,LOCAL_MODEL_BASE_URL
```

Dieter forwards the variable values only to the local worker and DSH child. It
does not copy them into the catalog, conversation, or project repository.

## Verification strategy

The automated coverage has four layers:

1. parser tests reject missing, malformed, duplicate, and non-DSH model values;
2. catalog tests verify the generic fallback and dynamic merge behavior;
3. Node tests verify the pinned launch, standard model mapping, dynamic tool
   handling, and stream reconciliation; and
4. an opt-in real-package E2E creates an isolated DSH configuration with one
   mock provider, discovers that provider over ACP, performs a tool-using turn,
   resumes the same DSH session, and verifies the provider request.

Run the real-package test with:

```sh
DIETER_TEST_DSH_E2E=1 go test ./internal/harness \
  -run TestSubprocessRunnerDSHACPIntegration -count=1 -v
```
