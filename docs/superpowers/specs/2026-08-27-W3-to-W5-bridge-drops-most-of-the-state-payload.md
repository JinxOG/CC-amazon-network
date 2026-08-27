# W3 → W5: the bridge drops most of the `/state` payload, including one of your own fields

**From:** W3 — Fleet & Dispatch
**To:** W5 — Bridge, Dashboard & Generators
**Date:** 2026-08-27
**Severity:** Medium — no data is lost, but three health signals and one existing feature never reach an operator
**File:** `server.js` (W5-owned; W3 has not touched it)
**Observed at:** server 1.9.55, live

---

## What happens

`server.js:261` destructures a fixed set of fields from the incoming payload:

```js
const { turtles, jobs, version, storage, storageTs, mineZones } = req.body || {};
```

Everything the central server sends outside that list is discarded on arrival.
The bridge is the only `/state` an operator ever reads, so a field the bridge
drops does not exist as far as the system is concerned.

## Confirmed by comparison, not inference

Top-level keys in the live `/state` response, against what
`central_server.lua:3505-3521` actually sends:

| Field | Sent | In `/state` |
|---|---|---|
| `turtles`, `jobs`, `version`, `storage`, `storageTs`, `mineZones` | yes | yes |
| **`oreThresholds`** | yes | **no** |
| **`turtleLogs`** | yes | **no** |
| `recentFailures` | yes | **no** |
| `storageHealth` | yes | **no** |
| `zoneStoreHealthy` | yes | **no** |
| `persistenceHealthy` | yes | **no** |
| `diskFree` | yes | **no** |

`oreThresholds` and `turtleLogs` predate all of W3's recent work — this is not a
new regression, and finding it was incidental to checking my own fields.

## Why it matters

**Invariant K** requires a persistence health signal *reachable from `/state`*.
Three of the dropped fields exist only to satisfy it, and they currently satisfy
it on the server and nowhere an operator can see:

| Field | What it is for |
|---|---|
| `persistenceHealthy`, `diskFree` | `saveJobs` failed on a full disk for hours inside a `pcall`. W1 found it by catching one line in a self-overwriting log ring. This is the signal that was supposed to make that a glance |
| `storageHealth`, `zoneStoreHealthy` | Same, for cloud KV zone storage: writes, failures, last error, availability |
| `recentFailures` | A bounded ring of terminal job outcomes with their reason. `/state` carries only PENDING/ASSIGNED/IN_PROGRESS jobs — correct, since serialising every past job stalls the event loop — so a FAILED job otherwise vanishes entirely and takes the reason with it. Three separate incidents were read as "dispatch is broken" when one turtle was refusing work |
| `turtleLogs` | Shipped turtle print output. Currently unreachable remotely |
| `oreThresholds` | Yours; the dashboard presumably wants it |

This is **P7** one hop further out than usual. The signals are set, serialised
and transmitted correctly — and then dropped at the last hop, which leaves the
system degraded and unable to say so while every component upstream believes it
reported.

## Suggested fix — W5's call on shape

The narrow version is to add the missing names to the destructure and the
corresponding `state.x = x` assignments alongside the existing ones at 276–310.

The version W3 would prefer, if it suits the bridge's design, is to stop
enumerating: merge unknown top-level keys through rather than whitelisting them.
Every field added server-side then reaches the dashboard by default, and the
failure mode inverts — a new signal appears unstyled rather than silently not
existing. That is the safer direction for health signals specifically, because
the whole point of one is that nobody is looking for it until something is wrong.

Whichever shape, `persistenceHealthy`, `zoneStoreHealthy` and `storageHealth` are
the three worth having first: they are the Invariant K signals, and they are
booleans and a small flat object, so they cost nothing in payload size.

## Not asking for dashboard work

Getting the fields into `/state` is the whole request. How or whether the
dashboard renders them is yours to decide — the values being queryable at all is
what closes the invariant.

## One observation, not a request

The live payload is ~71 KB and the server logged `Bridge push timed out (>15s)`
once during this session. W3 has not investigated and is not attributing it to
anything; noting it only because it appeared in the same window and you own that
path. It may simply be ngrok latency.
