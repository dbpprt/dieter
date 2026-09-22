# Design brief: Gateway Admin in Dieter for Mac

Prepared 22 September 2026 · Ready for wireframe work

## Product goal

Give the gateway administrator a clear answer to three questions:

1. Is the gateway reachable, and which machines are connected to it?
2. Which connections carry Dieter traffic, in which direction, and over which
   route: gateway relay, direct TLS, direct WebRTC or TURN?
3. What explains an offline machine, stale measurement or saturated relay?

This is a native Mac destination inside Dieter. There is no web dashboard. The
first release is read-only. Fleet visibility does not grant access to another
user's projects, conversations, screens or machine controls.

The [assessment](gateway-admin-assessment-2026-09-22.md) explains current source
data. The [implementation plan](gateway-admin-implementation-plan-2026-09-22.md)
defines proposed fields, limits and delivery increments. **A** means gateway
foundation; **B** needs new endpoint reporting/history or TURN collection. Neither
increment is implemented by these documents. Annotate wireframes accordingly.

## Navigation and frame

Add **Gateway Admin** as a global destination near the app's existing global
navigation. Show it only after the selected gateway confirms the current signed-in
human is an administrator. Do not hardcode a user ID in the app or nest this view
inside a project or a machine popover.

Persistent context: gateway name/origin, signed-in identity, observation time and
connection/freshness indicator. Keep the scope visible when multiple gateways
are configured. Switching gateway/account clears the previous fleet immediately.
The view remains useful when all daemons are offline.

Recommended subnavigation: **Overview**, **Connections**, **Machines**,
**Accounts**. Machine/edge details use an inspector or compact sheet rather than
opening the owner's workspace. Match Dieter's existing type, spacing, sidebar,
theme and native controls; exact layout is for the design team to resolve.

Design a wide workspace around 1440×900 and a compact window around 900×650.
These are wireframe targets, not fixed app minimums. Adapt below those widths
with a list and sheet; never make the canvas the only way to inspect connections.

## Screen requirements

| Surface | Content | Main interactions | Availability |
| --- | --- | --- | --- |
| Overview | Gateway build/release, reachable state, uptime, connected/enrolled machine counts, active relay RPCs, gateway payload In/Out, capacity/error indicators and coverage | Open Connections filtered to an issue; open Machines by status | A, new instrumentation required for rates/uptime/capacity |
| Connections | Topology canvas and equivalent sortable table; account, route, status and machine search filters; legend, fit/reset controls | Select node/edge; inspect directional rates; switch canvas/table without losing selection | A gateway links/relay legs; B direct/RTC/TURN |
| Machines | Name/ID, account, gateway connection state, last seen, platform when known, release/API, advertised capabilities, measured relay In/Out | Search, account/status filters, sort, open inspector; revoked filter | A; B adds other measured routes |
| Machine inspector | Identity, owner, enrollment/generation, certificate expiry, tunnel activity, safe route summary, connected/recent edges, directional rates with source | Select related edge; copy public ID; navigate to filtered table | A; B extends history/direct reports |
| Edge inspector | Endpoints, route/purpose, evidence source, active/recent/stale state, both directional rates, interval, layer, availability and safe error | Highlight logical path and associated legs; inspect series when available | A current relay values; B history/direct |
| Accounts | Numeric GitHub ID, last-known login or “Not yet observed,” allowed/admin status, enrolled/connected machine counts, unexpired native sessions | Filter machines/connections to account | A; session count is not online user count |

Do not fill overview cards with invented uptime percentages, WAN speed, monthly
cost, latency percentiles, global token usage, task counts or backup success.
Gateway process/relay health is distinct from optional infrastructure health.
TURN collection unavailable is not the same as TURN down.

Provider quota service freshness/error counts can be a secondary health detail.
Do not duplicate the existing personal quota panel, reveal cross-account provider
emails/amounts by default, or imply that provider quota consumption is traffic.

## Canvas specification

Use an account-scoped view by default, with a fleet summary/account grouping for
the global view. The gateway is a distinct node. Enrolled machines show name,
platform when available and gateway presence. Native clients start as a grouped
account node; they are not identified machines. TURN is a separate service node
even on the same VPS as the gateway.

There are two different kinds of visual relationship:

- **Availability:** an authenticated machine tunnel to the gateway. A quiet
  connected tunnel is still connected and can have an observed zero rate.
- **Traffic path:** one or more observed directional legs or an endpoint-reported
  direct connection. Route candidates alone must never draw a traffic edge.

Selecting A → gateway → B highlights one logical relay flow and its two legs.
Selecting direct A → B must not light up a gateway data path. Separate control
and screen/media routes when they differ. A TURN credential being issued is
insufficient to draw a live TURN connection.

Use arrows with clear endpoint labels and paired values, for example:

```text
Studio Mac → Build Linux    240 KiB/s
Build Linux → Studio Mac     12 KiB/s
Gateway relay · Payload bytes · Measured by gateway · Updated 3s ago
```

The numbers above are illustrative, not live measurements. Show bytes per second
consistently; do not mix B/s with bit/s without an explicit unit. “In” on a selected
machine means toward that machine; “In” on the gateway means toward the gateway.

Make observation source readable in the inspector: **Measured by gateway**,
**Reported by machine**, or **Reported by TURN service**. Keep transport and
evidence visually distinct; a dashed line should not simultaneously mean direct,
offline and unverified. Use a stable legend, line styles/icons and text in
addition to color. Optional width can represent a rate, with a documented scale;
do not suggest a capacity percentage when no capacity measurement exists.

Keep positions stable as samples update. Allow pan, zoom, fit, selection and
keyboard equivalents. No automatic perpetual graph simulation. Respect Reduce
Motion; flow animation is optional, not evidence of real packets. A selected
node/edge remains selected during refresh or becomes explicitly “No longer
observed.” Large graphs are grouped/filtered and show omitted counts; do not
silently hide edges or freeze the app.

## Time, coverage and missing data

A shows current rates over a valid measurement interval and cumulative counters
since the current gateway epoch. B may add 15m/1h/24h selectors when the backend
advertises the corresponding retention. Do not design a promised 30-day history
or make unavailable ranges look like empty zero charts. After restart, label
the time from which measurements are available.

| State | Example copy / rendering |
| --- | --- |
| Healthy, quiet, measured | `0 B/s · Updated 3s ago`; ordinary connected appearance |
| Source absent | `Not measured`; no numeric zero, no filled chart |
| Recent source now stale | `Stale · Last report 2m ago`; preserve historical value with explicit age, stop live animation |
| Gateway disconnected | Connection notice with last snapshot time; no claim that every machine is offline |
| Machine tunnel disconnected | `Gateway disconnected · Last seen …`; direct endpoint reports may independently be stale or recent |
| Partial telemetry | `Partial coverage · 18 edges omitted`; retain trustworthy observed totals separately |
| Contract mismatch | Explicit incompatible state and versions; do not silently fall back to an old contract |
| Gateway restarted | `Measurements available since …`; chart gap/reset, no counter spike |
| Permission lost / session expired | Clear fleet data, leave the admin destination, offer normal sign-in path if applicable |
| No enrolled machines | Calm empty state explaining enrollment; no fake network |
| Filter has no matches | Preserve filters, show “No matching machines/connections” and clear-filter action |
| TURN integration absent | `TURN telemetry not configured`; do not mark TURN unhealthy |

Connection state and metric freshness are separate. Latency appears only when
available, with its kind (RPC response time or transport RTT). Do not sum screen
pipeline timings into “end-to-end latency.” Graph/table/inspector must use the
same source and interval.

## Wireframe scenarios and deliverables

Use clearly labeled synthetic data:

| Scenario | Fixture story | Required design evidence |
| --- | --- | --- |
| Small fleet | Two accounts; admin account has Studio Mac, Build Linux and an offline laptop; another account has one daemon | Native entry, account grouping, gateway presence, inventory and read-only inspector |
| Mixed traffic | Studio Mac exchanges metadata with Build Linux directly; a grouped client uses gateway relay; another flow uses TURN | Independent paths; accurate source labels; no invented client-to-daemon identity |
| Partial rollout | One machine reports direct traffic, another only gateway presence; TURN collector absent | “Not measured” and partial coverage without misleading totals |
| Operational failure | Gateway reachable, one tunnel disconnected, one slow relay overflow, history begins after restart | Distinct issue states and a route from overview to the relevant detail |
| Large fleet | 200+ machines with graph projection limit reached | Grouping/search/table fallback, pagination and visible truncation |
| Authorization change | Nonadmin user, expired session, gateway/account switch | No admin entry/data leak; state clearing and sign-in recovery |

Return:

1. An annotated navigation map and wide/compact wireframes for Overview,
   Connections (canvas and table), Machines, Accounts and both inspectors.
2. Variants for loading, empty, stale, partial, offline, permission-loss and
   incompatible-contract states; light/dark and keyboard focus treatment.
3. Canvas legend, source/unit/time labels, selection behavior, stable updating,
   accessible table alternative and Reduce Motion behavior.
4. A field map tying every visible value to a backend field/source and A or B.
   Flag desired new data rather than inventing populated examples as a promise.
5. A clickable prototype or interaction notes for overview → filtered graph →
   edge inspector → machine inspector, plus a table-only keyboard journey.

Acceptance: a reviewer can tell what is measured, what is merely available,
what direction bytes travel, where the gateway is bypassed, and how fresh and
complete the result is. No chart counts one logical relay transfer twice. No
admin view opens another user's workspace or offers destructive actions.

The implementation team then binds the agreed wireframes to generated APIs and
fixture payloads, verifies layout/accessibility in the native app, and runs the
authorization and route tests in the backend plan. This brief is prepared for
handoff; sending it to the design team is a separate communication action.
