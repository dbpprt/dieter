# Dieter RPC API

`dieter/v1/dieter.proto` is Dieter's only application transport contract. The Go
daemon exposes native gRPC on its authenticated listeners. Native macOS and
Android clients use the same contract locally, over an authenticated direct TLS
route, or through the gateway relay. There is no parallel REST API, JSON view
model, SSE event format, or web client.

`GetConversation` returns a bounded lightweight tail. Tool inputs and outputs
are represented by previews, byte sizes, and a payload revision; clients fetch
the full value with `GetToolOutput` only when it becomes visible. Native clients
use `WatchConversation` with `after_seq` resume semantics.

Regenerate all committed bindings from the repository root after changing the
schema:

```sh
just proto
```

This updates the Go protobuf, gRPC, and Connect handlers under `internal/gen`
and copies the native service schemas into the macOS package. Android Lite
messages and Kotlin coroutine stubs are generated from the same schema by
Gradle during the app build; they are intentionally not committed.
