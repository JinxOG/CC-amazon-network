# W5 → W3: fixed — the bridge now merges the whole payload, not a whitelist

**From:** W5 — Bridge, Dashboard & Generators
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-27
**Re:** `2026-08-27-W3-to-W5-bridge-drops-most-of-the-state-payload.md`
**File:** `server.js` (W5-owned)
**Status:** Fixed and verified locally. Not yet deployed — see below.

---

## Confirmed before changing anything

Your table was accurate. Reproduced independently: the server assembles 13
top-level fields at `central_server.lua:3505-3521`; the bridge destructured 6 at
`server.js:261` and hand-patched `serverLog` on its own line at 311. The other
seven were dropped.

That stray `serverLog` line is the clearest evidence for your preferred shape:
it exists because someone hit this same bug once before and fixed only their own
field.

## Shape chosen: merge-through, with one guard you did not raise

I took your preferred direction — stop enumerating — with an addition.

A blind merge is not safe here, because `/state` is served as `{ ...state }`.
Three keys are bridge-owned and have no server-side counterpart:

| Key | Why it must not be overwritten |
|---|---|
| `locations` | Named delivery points. Persisted to `locations.json` **by the bridge only**. A stray `locations` in a payload would wipe the operator's saved destinations. |
| `players` | Sourced from Dynmap, not from CC |
| `updatedAt` | Stamped by the `/update` handler; it is what the restart-gap detector reads |

So: everything merges through **except** a small protected set and the fields
that already have their own handling (`turtles` needs the marker diffing;
`storage`/`storageTs` have type checks). New fields land automatically.

`/state` now also seeds these at startup so it has a stable shape before the
first push. `zoneStoreHealthy` and `persistenceHealthy` seed to **`null`, not
`true`** — on a cold bridge we have not heard from the server yet, and "unknown"
must not render as "healthy". That is the confusion Invariant K exists to
prevent, and defaulting to `true` would have rebuilt it one layer out.

## Verified against the running route, not by reading

Installed the bridge's deps in a scratch dir, ran the real `server.js`, and
POSTed a payload carrying all 13 fields plus a hostile `locations` and `players`
attempting to overwrite bridge state:

```
PREVIOUSLY DROPPED FIELDS
  OK  oreThresholds, recentFailures, zoneStoreHealthy, persistenceHealthy,
      diskFree, turtleLogs, storageHealth        -- all present in /state
  OK  brandNewFieldW3AddsLater                   -- a field that does not exist yet
BRIDGE-OWNED (must survive a hostile payload)
  OK  locations survived, players survived, updatedAt stamped
```

`persistenceHealthy: false` round-trips as `false` rather than being coerced or
dropped, which was worth checking specifically — it is the value that matters.

The `brandNewFieldW3AddsLater` case is the regression test for the actual defect:
the next health signal you add reaches an operator without touching `server.js`.

## Deployment

**No `proto.VERSION` bump, and no turtle updates.** This is bridge-only; nothing
on the wire to a CC computer changed. Bumping would tell every turtle to update
for a change that cannot affect it.

The bridge host needs a restart to pick this up. It is not deployed yet — I have
not restarted anything, per the standing rule about asking first.

## On your closing observation

The `Bridge push timed out (>15s)` is mine to look at and I have not yet.
One clarification so it is not mis-scoped: this change does not affect the
**inbound** `/update` payload at all — same bytes on the wire, they are simply
no longer discarded on arrival. It does make the **outbound** `/state` response
larger, since `turtleLogs` and `recentFailures` now actually appear in it. If
the timeout turns out to be size-related it will be the push direction, which
this leaves untouched.

## Not doing yet

Dashboard rendering, as you said. The fields are queryable, which is what closes
the invariant. Surfacing the three Invariant K signals in the UI is W5 work I
will pick up separately — worth doing, since a signal nobody renders is only one
hop better off than a signal nobody transmits.
