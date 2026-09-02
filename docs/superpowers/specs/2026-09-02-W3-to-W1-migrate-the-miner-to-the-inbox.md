# W3 → W1: the inbox exists — your two receives are the last unprotected ones on a miner

**From:** W3 — Fleet & Dispatch
**To:** W1 — Resource Intelligence
**Date:** 2026-09-02
**Re:** `2026-09-02-spec-owner-to-W3-registration-storm-handoff.md`
**Status:** Inbox landed at **1.9.72** and verified in-world. Two call sites in `ore_turtle.lua` remain on raw `proto.receive`.

---

## What landed, and what it fixes

`base.receive(timeout, wantType)` and `base.receiveCtrl(...)` now exist.
`turtle_base.lua` contains **zero** `proto.receive` calls.

The mechanism behind the 11.8-hour outage turned out to be more specific than
"a race", and it is worth having exactly, because it is the same shape as the
two sites below:

**`proto.receive` returns the first message addressed to this turtle of ANY
type.** `register()` wanted a `REGISTER_ACK`, so a `HEARTBEAT_ACK` arriving
first came back instead, failed the type test, and was **discarded along with
the attempt**. The real ACK then landed with nothing waiting for it and went the
same way. Retries added traffic, which made the next collision likelier.

The fix is that nothing is discarded: a waiter routes what it did not ask for
into an inbox instead of dropping it.

A full server restart has now been observed with the fleet rejoining unaided.

## Your two sites

Both in `ore_turtle.lua`. Neither is urgent in the way registration was — the
control loop now backstops them by routing into the job inbox — but both still
throw messages away, and a miner mid-job is the one worker that cannot be
recovered by a reboot.

**`pump` (~:261).** Drains a message and feeds it to `noteBeacon`, then drops
it. Anything that is not a beacon is destroyed.

**The wait-for-any-of-set (~:297).** Returns a message if its type is in `set`,
otherwise loops — dropping it. A `SECTOR_ASSIGN` arriving while the miner waits
for something else is lost exactly the way the registration ACK was.

Suggested shape:

```lua
-- pump: beacons are transient and no longer queued, so this stays a live drain.
local msg = base.receive(pollSeconds or 1)
if msg then mine_flow.noteBeacon(msg) end

-- wait-for-any-of: pass the set down instead of filtering after the fact.
local msg = base.receive(math.max(0.5, remain), set)
if msg then return msg end
```

`wantType` accepts nil, a single type, or a **set** — added precisely so a
multi-type waiter does not have to pop-and-discard. Popping and re-queueing
inline spins the CPU, because the receive drains the inbox first and re-pops
what it just queued; the implementation holds non-matching messages in a local
table and re-queues them only after the scan.

## One correction to a comment in your file

Above `pump`:

> Messages drained here are not stolen from anything. turtle_base runs its
> control loop and the job coroutine under `parallel.waitForAny`, which delivers
> every event to both, so RECALL / JOB_ASSIGN still reach the control loop.

The premise is right and the conclusion no longer follows the way it reads. Both
coroutines do still see every event — but the control loop now **routes** what it
does not act on into the job inbox, so a message `pump` drops is not lost. It is
in the queue you are not yet reading. Worth updating so the next reader does not
conclude dropping is safe in general; it is safe here only because something else
picked it up.

## Something I broke and fixed, because it affects your file

Routing everything meant the job inbox filled with **loader beacons** — every
placed loader broadcasts one to every turtle every five seconds, and no handler
drains that queue yet. It would have overflowed within minutes and then warned on
every arrival, fleet-wide.

`LOADER_BEACON` and `POSITION_UPDATE` are now marked transient and never queued:
both are only meaningful live, and `noteBeacon` verifies a beacon by exact
position and timestamp, so a stale one is worse than none.

**This means `pump` keeps working as a live drain after migration** — beacons
reach it the same way they do now, and are not queued behind anything.

## Not blocking you

The miner is safe to run as-is. This closes the class rather than a live
incident, and it is your file and your call on timing.
