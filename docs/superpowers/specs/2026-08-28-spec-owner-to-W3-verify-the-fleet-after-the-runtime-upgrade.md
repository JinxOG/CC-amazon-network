# Spec owner → W3: the fleet is running on a runtime nobody has verified

**From:** Spec owner
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-28
**Subject:** CC:Tweaked 1.116.0 → 1.120.2, unverified against live code
**Status:** Verify — highest unexamined risk on the server

---

## What changed under you

The server operator replaced **CC:Tweaked 1.116.0 with 1.120.2** on the host
during 27–29 Aug, alongside removing CC Androids and adding Turtlematic,
UnlimitedPeripheralWorks and Cloud Solutions.

Their manifest reasons that **no `.lua` files were modified, so no client
reflash was needed.** That is true for *deployment* and says nothing about
*behaviour*. The same Turtle OS code is now executing on a runtime four minor
versions newer, and nobody has looked at whether it still behaves the same.

I checked the official incompatibilities page at
`tweaked.cc/reference/breaking_changes.html`. It documents **nothing** between
1.116 and 1.120 — but it only covers up to **1.109.3**, so that is missing
documentation, not a clean bill of health. Treat it as unknown.

## Why this lands on you

You own `turtle_base.lua`, `equipment.lua`, `geofence.lua` and
`central_server.lua` — every file that touches the CC APIs most likely to shift
between versions: `os.pullEvent`, `parallel`, `turtle.*`, `peripheral.*`, `fs`,
and modem transmit/receive.

Two of those are load-bearing in ways a subtle change would break quietly:

- **`parallel.waitForAny` event handling.** Invariant G exists because the
  control loop and job runner share one event queue. The shared inbox that was
  meant to fix this **still does not exist** — no `base.receive`, no
  `_ctrlInbox`, no `CTRL_TYPES`. Every worker is on raw `proto.receive` today.
  A change in event delivery order or timing would surface as intermittent lost
  signals, which is exactly the failure this codebase is worst at diagnosing.
- **`equipment.lua`'s swap dance.** `equipLeft`/`equipRight` behaviour during
  the modem-down retrieval window. Invariants A, B and C all depend on it.

## What to check

Not a code review — a behavioural sweep against the live fleet:

1. **Miners complete a full sector cycle** — travel, place loader, swap to
   pickaxe, mine, swap to chunky, retrieve loader, return, dock.
2. **Delivery still works.** `delivery_turtle.lua` is frozen (Invariant H), so
   any change here is the runtime, not the code.
3. **No new WARN or ERROR classes** in `serverLog` that were not there at 1.9.55.
4. **`fs` behaviour around the persistence paths** — the disk crisis is fixed but
   the write patterns are unchanged.
5. **Modem range and delivery.** Any silent change here reads as "turtles
   ignoring orders."

## Also yours, and still open

**`saveActiveZones` at `central_server.lua:754` still uses `fs.copy`.** The
same defect was fixed in `saveJobs` (`:490`) and `savePersistentZones` (`:629`),
both now `fs.move`. `active_zones.dat` was one of the two files truncated to
near-zero in the original disk incident, so the exact mechanism that
manufactured that failure is still live in the third function. W1 found the
class; this is the remaining instance.

**The server has crashed five times.** `crash.log` records five, the most recent
`server.run crashed: Terminated`. `24ccdbe` made crashes attributable — use it.
This sits at the top of Stage 0 in the recentred roadmap (§16), above everything
else you have queued.

## One thing that got easier

Androids are gone from the modpack. The `ANDROID` class is retired, `W4`'s
builder will be a turtle, and the fleet target simplifies to `WORKER` and
`LOADER`. Nothing in your files depends on Androids, but the capability matrix
in §6.4 no longer needs to carry them.

## Note on access

External `/state` now requires credentials — the dashboard has a Basic Auth gate
in front of all routes except `/ping`. In-game computers are unaffected
(loopback stays open), but anyone verifying from outside the LAN needs the
credentials from `~/cc-dashboard/.env`.
