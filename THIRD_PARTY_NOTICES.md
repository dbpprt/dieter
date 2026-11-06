# Third-party notices

Dieter's own code is licensed under the [MIT license](LICENSE). It includes or
redistributes the third-party components below, each under its own license. The
license texts named here are kept in this repository next to the component and
travel with the builds that include it.

## Vendored source (`third_party/`)

Each package keeps its upstream license and a `PATCHES.md` describing Dieter's
changes.

| Component                                                                    | Version                    | License    | Files                                                                                                                                                                                   |
| ---------------------------------------------------------------------------- | -------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport) | 2.9.0 (`2ca31f0`), patched | Apache-2.0 | [LICENSE](third_party/grpc-swift-nio-transport/LICENSE), [NOTICES.txt](third_party/grpc-swift-nio-transport/NOTICES.txt), [PATCHES.md](third_party/grpc-swift-nio-transport/PATCHES.md) |
| [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)  | 0.12.0, patched            | Apache-2.0 | [LICENSE](third_party/swift-markdown-engine/LICENSE), [PATCHES.md](third_party/swift-markdown-engine/PATCHES.md)                                                                        |
| [HighlighterSwift](https://github.com/smittytone/HighlighterSwift)           | 3.1.0 (`fe7aae9`), patched | MIT        | [LICENCE.md](third_party/HighlighterSwift/LICENCE.md), [PATCHES.md](third_party/HighlighterSwift/PATCHES.md)                                                                            |

## Copied or modified source elsewhere

| Component                                                                                                                                                                                                          | Where                                                             | License                                   | Files                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WebRTC Android SDK ([webrtc-sdk/webrtc](https://github.com/webrtc-sdk/webrtc), `io.github.webrtc-sdk:android:150.7871.01`), four modified and two added Java sources rebuilt into the Android app's WebRTC library | `apps/kotlin/android/webrtc`                                      | BSD-3-Clause with the WebRTC patent grant | [LICENSE](apps/kotlin/android/webrtc/LICENSE), [PATENTS](apps/kotlin/android/webrtc/PATENTS), [upstream.json](apps/kotlin/android/webrtc/upstream.json) |
| Material icons (vector definitions from the Android Open Source Project's Compose Material icons)                                                                                                                  | `apps/kotlin/ui/src/commonMain/kotlin/com/getdieter/mobile/icons` | Apache-2.0                                | [LICENSE.txt](apps/kotlin/ui/src/commonMain/kotlin/com/getdieter/mobile/icons/LICENSE.txt)                                                              |

## Fonts

| Component                                                   | Where                                                                                                                                                               | License                                                                                                                                       |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| [Sora](https://github.com/sora-xor/sora-font) variable font | `assets/brand/assets/fonts` (single source), bundled with the website, the Mac app and the shared mobile UI (`apps/kotlin/ui/src/commonMain/composeResources/font`) | SIL Open Font License 1.1: [OFL-Sora.txt](assets/brand/assets/fonts/OFL-Sora.txt) (copy: [LICENSE-Sora.txt](apps/kotlin/ui/LICENSE-Sora.txt)) |

## Bundled binaries and generated bundles

| Component                                                                                                      | Where it comes from                                                                           | License information                                                                                                                        |
| -------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| WebRTC for Apple platforms ([stasel/WebRTC](https://github.com/stasel/WebRTC) M151 binary framework)           | SwiftPM binary target in `apps/apple/DieterKit/Package.swift`                                 | BSD-3-Clause (WebRTC project); shipped inside the macOS and iOS apps                                                                       |
| Mac Markdown preview JavaScript bundle (markdown-it, Mermaid, Vega/Vega-Lite, Turndown and their dependencies) | Built from `apps/apple/mac/MarkdownPreview` (`package-lock.json`)                             | `build.mjs` generates `LICENSES.txt` with every bundled package's license; it ships in the app at `Resources/MarkdownPreview/LICENSES.txt` |
| Harness runtime packages (agent bridges, OMP, DSH, Bun)                                                        | Installed by the daemon from `internal/harness/runtime/package-lock.json` and pinned versions | Each package's own license, as published in its registry metadata                                                                          |

## Dependencies by manifest

Libraries resolved by the package managers are listed, with exact versions, in
their manifests and lock files. Their licenses are those published by each
project.

| Language                            | Manifests                                                                                                                                                                                              |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Go                                  | [go.mod](go.mod), [go.sum](go.sum)                                                                                                                                                                     |
| Kotlin and Android                  | [apps/kotlin/gradle/libs.versions.toml](apps/kotlin/gradle/libs.versions.toml) and the module build files in `apps/kotlin`                                                                             |
| Swift                               | `Package.swift` and `Package.resolved` in [apps/apple/DieterKit](apps/apple/DieterKit) and [apps/apple/mac](apps/apple/mac); `Package.swift` in `apps/apple/ios/Host` and [native/macos](native/macos) |
| JavaScript                          | [internal/harness/runtime/package-lock.json](internal/harness/runtime/package-lock.json), [apps/apple/mac/MarkdownPreview/package-lock.json](apps/apple/mac/MarkdownPreview/package-lock.json)         |
| Python (gateway deployment tooling) | Standard library only; pinned tools in [deploy/gateway/tools.lock.json](deploy/gateway/tools.lock.json)                                                                                                |

The Linux screen-capture helper (`native/linux-capture`) links the host's
GStreamer, GLib/json-glib and X11 libraries dynamically and reaches PipeWire
through the desktop portal; none of them is redistributed.
