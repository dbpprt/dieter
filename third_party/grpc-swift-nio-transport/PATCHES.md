# Dieter patches

Vendored from grpc/grpc-swift-nio-transport 2.9.0 at commit `2ca31f0`.
Upstream: https://github.com/grpc/grpc-swift-nio-transport/tree/2.9.0
License: Apache-2.0 (see `LICENSE` and `NOTICES.txt`; keep both when updating
the snapshot).

Used by `apps/apple/DieterKit` and `apps/apple/mac` as a local package.

## Patches

1. **Nanosecond sleeps (Swift #81771).** The three duration-based `Task.sleep`
   calls use the nanosecond overload (`GRPCChannel.swift`, twice, and
   `LoadBalancers/Subchannel.swift`). The generic duration overload can abort
   in `swift_task_dealloc` in optimized builds made with the current Apple
   Swift toolchain during connection backoff; see
   [swiftlang/swift#81771](https://github.com/swiftlang/swift/issues/81771).
2. **Ed25519 daemon certificates.** The Posix client TLS configuration exposes
   NIOSSL's verification signature algorithms
   (`ClientTLSConfig.verifySignatureAlgorithms` in `Config+TLS.swift`, applied in
   `NIOSSL+GRPC.swift`). Dieter uses it to enable Ed25519 for daemon
   certificates.

Remove patch 1 and return to the remote package once the release toolchain
passes `unreachableEndpointSurvivesConnectionBackoffAndShutdown` (in
DieterMacTests) without it; patch 2 then needs an upstream equivalent.
