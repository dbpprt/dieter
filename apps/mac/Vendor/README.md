# Vendored Swift packages

`grpc-swift-nio-transport` is based on upstream 2.9.0 (`2ca31f0`). Nauclio carries
two narrow compatibility patches:

- For [swiftlang/swift#81771](https://github.com/swiftlang/swift/issues/81771),
  the three duration-based `Task.sleep` calls use the nanosecond overload. The
  generic duration overload can abort in `swift_task_dealloc` in optimized
  builds made with the current Apple Swift toolchain during connection backoff.
- The Posix client TLS configuration exposes NIOSSL's verification signature
  algorithms. Nauclio uses it to enable Ed25519 for daemon certificates.

Keep the upstream `LICENSE` and `NOTICES.txt` when updating the snapshot. Remove
the patch and return to the remote package once the release toolchain passes
`unreachableEndpointSurvivesConnectionBackoffAndShutdown` without it.
