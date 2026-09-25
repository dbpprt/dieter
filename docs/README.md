# Documentation index

Start with the [public documentation](https://getdieter.com/docs/) or its
[Markdown source](../landingpage/content/docs/_index.md). User guides are maintained
in `landingpage/content/docs`; the root README is a short project introduction.
This directory holds implementation references and historical evidence.

## Practical guides

- [Installation](../landingpage/content/docs/installation.md) and [first task](../landingpage/content/docs/quickstart.md)
- [Product tour](../landingpage/content/docs/tour.md) and [screenshot provenance](screenshots/README.md)
- [Projects and tasks](../landingpage/content/docs/projects.md), [conversation workspace](../landingpage/content/docs/workspace.md), [automation](../landingpage/content/docs/automation.md)
- [Machines](../landingpage/content/docs/machines.md), [screens](../landingpage/content/docs/screens.md), [self-hosting](../landingpage/content/docs/gateway.md)
- [CLI](../landingpage/content/docs/cli.md), [agents and models](../landingpage/content/docs/harnesses.md), [troubleshooting](../landingpage/content/docs/troubleshooting.md)
- [Architecture](../landingpage/content/docs/architecture.md), [security](../landingpage/content/docs/security.md), [configuration](../landingpage/content/docs/configuration.md)
- [Contributing](../CONTRIBUTING.md), [development](../landingpage/content/docs/development.md), [website maintenance](../landingpage/README.md)

## Technical references

- [Native test catalog and runner](../tests/e2e/README.md)
- [Application contract and compatibility](api-contract.md)
- [Shared project identity, causal records, and ownership](peer-store.md)
- [Portable navigation settings and offline synchronization](client-navigation-folders.md)
- [Native document editing, presentation, and capture routing](conversation-workspace.md)
- [Screen protocol, clipboard, diagnostics, and qualification](screen-sharing.md)
- [WebRTC API transport](webrtc-control-transport.md)
- [Linux runtime and feature dependencies](linux-support.md)
- [Homebrew service activation and rollback](homebrew-service-runtime.md)
- [DeepSeek integration background and operational notes](deepseek-dsh-harness.md)
- [Isolated native TURN integration](gateway-native-turn-testing.md)
- [Apple release signing and TestFlight](apple-release-signing.md)

Other component references: [RPC schema](../api/proto/README.md),
[gateway deployment](../deploy/gateway/README.md), [Mac](../apps/mac/README.md),
[Android](../apps/android/README.md), [iOS](../apps/ios/README.md),
[Android WebRTC](../native/android-webrtc/README.md), and [brand assets](../assets/brand/README.md).

## Historical investigations and validation

These are dated engineering records, not the current installation manual or a
list of promised features. Their observations, benchmarks, and validation limits
are retained. Paths are stable so existing issue and PR links continue to work.

- [Lean native test framework proposal](native-test-framework-plan-2026-09-25.md)
- [Native test framework implementation](native-test-framework-implementation-2026-09-25.md) — Android runner, retired scripts, platform boundaries, and validation.
- [Gateway domain migration and acceptance](gateway-domain-migration-2026-09-22.md)
- [Gateway administration assessment](gateway-admin-assessment-2026-09-22.md), [design brief](gateway-admin-design-brief-2026-09-22.md), and [implementation plan](gateway-admin-implementation-plan-2026-09-22.md)
- [Documentation refresh and validation](documentation-refresh-2026-09-22.md)
- [Chat scrolling assessment and fix plan](chat-scroll-assessment-2026-09-18.md)
- [Mac chat scrolling fix](chat-scroll-implementation-2026-09-18.md)
- [Native conversation workspace: implementation and validation](conversation-workspace-validation-2026-09-12.md)
- [Dieter gateway and VPS deployment plan](gateway-vps-deployment-plan-2026-09-21.md)
- [gateway-vps-implementation-plan-2026-09-21](gateway-vps-implementation-plan-2026-09-21.md)
- [gateway-vps-plan-assessment-2026-09-21](gateway-vps-plan-assessment-2026-09-21.md)
- [iOS remote screen access plan](ios-remote-screen-plan-2026-09-18.md)
- [Porting Dieter to Linux (Garuda on box) — assessment](linux-port-assessment-2026-09-16.md)
- [Linux screen-sharing assessment and implementation plan](linux-screen-sharing-plan-2026-09-18.md)
- [Mac app performance and Changes assessment](mac-app-assessment-2026-09-07.md)
- [Mac Changes implementation and validation](mac-app-changes-validation-2026-09-07.md)
- [mac-board-performance-2026-09-08](mac-board-performance-2026-09-08.md)
- [mac-code-quality-refactoring-proposal-2026-09-08](mac-code-quality-refactoring-proposal-2026-09-08.md)
- [Mac navigation and action feedback audit — 8 September 2026](mac-navigation-responsiveness-2026-09-08.md)
- [mac-refactoring-implementation-2026-09-09](mac-refactoring-implementation-2026-09-09.md)
- [mac-responsiveness-assessment-2026-09-08](mac-responsiveness-assessment-2026-09-08.md)
- [mac-responsiveness-implementation-2026-09-08](mac-responsiveness-implementation-2026-09-08.md)
- [One project, many machines](multi-machine-projects-plan-2026-09-19.md)
- [Account peer settings sync after WebRTC implementation](peer-settings-sync-reassessment-2026-09-20.md)
- [Performance implementation — 21–22 September 2026](performance-implementation-2026-09-21.md)
- [Dieter performance investigation — 21 September 2026](performance-investigation-2026-09-21.md)
- [Provider account quota plan](provider-account-quota-plan-2026-09-18.md)
- [Dieter screen sharing assessment — 13 September 2026](screenshare-assessment-2026-09-13.md)
- [Image/file clipboard and persistent screen recovery](screenshare-clipboard-recovery-2026-09-17.md)
- [Hardware HEVC screen sharing](screenshare-hevc-implementation-2026-09-17.md)
- [Hardware HEVC screen-sharing plan](screenshare-hevc-plan-2026-09-17.md)
- [Native Mac screen sharing implementation — 14 September 2026](screenshare-implementation-2026-09-14.md)
- [Screen-sharing latency implementation — 17 September 2026](screenshare-latency-2026-09-17.md)
- [Screen bitrate response and Mac presentation scheduling](screenshare-latency-implementation-2026-09-17.md)
- [Screen performance implementation and evidence](screenshare-performance-implementation-2026-09-18.md)
- [Screen-sharing performance investigation — 18 September 2026](screenshare-performance-investigation-2026-09-18.md)
- [Screen-sharing performance implementation plan](screenshare-performance-plan-2026-09-18.md)
- [Screen reference recovery and adaptive FEC — 2026-09-17](screenshare-recovery-implementation-2026-09-17.md)
- [Mac screenshare blur during window resizing](screenshare-resize-scaling-2026-09-19.md)
- [Mac screen-share windows and cursor ownership](screenshare-undocked-window-2026-09-17.md)
- [WebRTC for Dieter control connections](webrtc-control-research-2026-09-19.md)

- [Relay fallback investigation](investigations/2026-09-21-relay-fallback.md)
- [Local screen qualification manifest](screenshare-qualification-local.json)
