# Native TURN testing

Use disposable gateway/daemon state and a dedicated coturn instance. The native
tests exercise the real signed RTC configuration, ICE negotiation, encrypted
data channel and video paths. They assert the selected route, so a successful
direct connection cannot pass a forced-TURN test.

## Fixture configuration

Create a private directory and a mode-0600 JSON file outside the repository:

```json
{
  "urls": ["turn:TURN_FIXTURE_HOST:3478?transport=tcp"],
  "sharedSecret": "REPLACE_WITH_THE_DISPOSABLE_COTURN_SECRET"
}
```

Set `DIETER_TEST_TURN_CONFIG` to its absolute path. The file accepts one to three
`turn:`/`turns:` URLs and a secret of at least 32 bytes. Coturn must receive the
same secret bytes in `static-auth-secret`. Never copy production credentials
into this fixture. The loader rejects public permissions, unknown JSON fields,
trailing data and files larger than 64 KiB without printing credentials.

Both `scripts/isolated-gateway` and `scripts/screens-fixture` read this file.
The API fixture uses the gateway's normal credential generator. The screen
fixture generates coturn REST credentials and signs its RTC configuration with
the disposable fixture identity. Production binaries do not load this file.

Select one URL per test to prove each transport independently. A TCP-only SSH
forward is useful for an isolated VM, but proves TCP relay behavior only. TLS
qualification needs the real hostname, trusted certificate and SNI path. A
successful raw TURN probe does not replace a native API or screen test.

The relay test exposed an ICE setup race: coturn rejected a private host
candidate before the later relay candidate arrived, and immediate peer teardown
prevented recovery. Both screen clients retain their existing bounded recovery
watchdog for failed/disconnected ICE while continuing trickle signaling. The
Android journey exercises repeated disconnect/reconnect, route failures, session
expiry, capture-helper recovery and cancellation during backoff on this path.

## macOS

With no conflicting native app or test process, run the normal canonical-cache
recipes. Preserve the operator daemon and use fresh fixture storage:

```sh
DIETER_TEST_TURN_CONFIG=/absolute/private/turn.json \
DIETER_TEST_FORCE_TURN=1 just mac screens-test
```

For API coverage, start `scripts/isolated-gateway` with
`DIETER_TEST_CONTROL_WEBRTC=1` and `DIETER_TEST_TURN_CONFIG`, using a fresh
`--home` and `--addr 127.0.0.1:0`. Capture its environment output into a private
file. Then run:

```sh
DIETER_CONTROL_FIXTURE=/absolute/private/fixture.env \
DIETER_TEST_FORCE_TURN=1 \
just mac test controlWebRTCRoutesNativeRPCAndReportsSelectedMode
```

The policy exists only in debug builds. The API test requires `WebRTC · TURN`
before and after reconnect; the screen test requires `Relayed media` while
checking decoded frames and input/session behavior. Stop the exact fixture
process afterward. A skipped opt-in test does not count as a pass.

## Android

Use the visible emulator under the shared device lease. The screen recipe uses
`com.dbpprt.dieter.screenfixture`; it refuses a running fixture and preserves the
normal Dieter application:

```sh
DIETER_TEST_TURN_CONFIG=/absolute/private/turn.json \
DIETER_TEST_FORCE_TURN=1 just android screens-test
```

When the TURN URL points at host loopback, create a separate, temporary ADB
reverse mapping for that TCP port on the explicitly selected emulator and remove
it afterward. The recipe owns only the screen service's reverse mapping.

For API coverage, install only the `screenFixture` app/test APKs, select
`IsolatedGatewayIntegrationTest#webRTCControlCarriesRPCAndReportsICEPath`, and
provide instrumentation arguments `isolatedControlWebRTC=1`, `forceTURN=1`,
`isolatedGatewayHost`, `isolatedGatewayPort` and the disposable
`isolatedGatewayToken`. Use the same opted-in API fixture described above and
map its random loopback port to the emulator. Never let Gradle select an attached
physical phone. The instrumentation sets and restores the debug-only TURN policy;
both API connection attempts must report `WebRTC · TURN`.

## Evidence and capacity

Retain source revision and any uncommitted patch identity, fixture image digest,
selected transport, test counts/skips, route assertions, frame/input statistics,
logs and screenshots. Record operator PID preservation and fixture cleanup.
The Android screen report includes `mediaRoute` alongside its decode statistics.

Run these functional tests before the concurrent API/screens/peer-sync workload.
The separate allocation soak measures allocation lifetime and cleanup at the
candidate quotas. Neither short native tests nor allocation counts establish
30-minute native throughput, public TLS reachability or production acceptance.
