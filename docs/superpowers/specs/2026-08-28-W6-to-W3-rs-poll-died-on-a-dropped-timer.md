# W6 → W3: RS storage sync died on a dropped timer; wall-clock fallback added to your file

**From:** W6 — Storage & Refined Storage (also W5)
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-28
**Severity:** High — RS storage sync stopped minutes after every server start and stayed dead until reboot
**File:** `central_server.lua` (yours; edited with the spec owner's explicit authorisation)
**Observed at:** server 1.9.55, live

---

## What was happening

The dashboard's RS storage snapshot froze minutes after each server start and
never recovered. Measured live: `updatedAt` 3 seconds old — server pushing
normally — while `storageTs` was **13,787 seconds (3.8 h) stale**, and **zero**
RS-related lines appeared in a 928-second log window where ~31 refreshes were
due. `refreshStorage` was neither succeeding nor failing; it was not being
called at all.

`storageTimer` re-arms **only inside its own handler**. CC drops events once the
256-slot queue overflows, so one lost timer event ends that task permanently.
The user's own observation rules out the alternative explanation: a detached RS
Bridge would not come back on restart, and restarting fixed it every time.

`craftableTimer`, `staleTimer` and `oreWatchdogTimer` have the identical shape.
They were simply less visible when they died.

## The part that makes it self-inflicted

The existing fallback block's comment says events get dropped *"e.g. during
refreshStorage"* — and then gives `refreshStorage` no fallback.

`listItems()` over 450 items is a multi-second blocking call that yields, and
the traffic arriving during that yield is what overflows the queue. **RS polling
is generating the overflow that kills its own timer** — and plausibly costing
dispatch and health ticks too, since they share the queue. Worth considering
next time a dispatch tick looks like it went missing.

## What I changed in your file

Additive only; no existing behaviour altered.

1. `isDue(now, lastRun, intervalSec)` at file scope, above `server.run`. Named
   rather than inline because there are now seven of these and the seconds vs
   milliseconds boundary is the live bug risk — a missing `*1000` turns a
   30-second poll into a 30-millisecond one and still looks like working code.
2. Four wall-clock fallbacks in the existing fallback block, for storage (30s),
   craftable (60s), stale supports (30s) and the ore watchdog (60s), each
   mirroring the three you already had.
3. `isDue` exported through the `__CC_SERVER_TEST` seam.
4. Two tests in `tests/test_server_zones.lua`, both mutation-tested: dropping
   the `*1000`, flipping `>=` to `>`, and requiring a prior run all get caught.

**I did not touch your three existing fallback blocks.** Folding them onto
`isDue` would be tidier and is provably equivalent, but the bridge-push one
carries load-bearing "call unconditionally" semantics and I would rather you
made that call in your own file.

Suite: **265 → 267 passed, 0 failed.**

## What this does and does not fix

It makes the poll unkillable: the fallback block runs after *every* event, and
events are never scarce on that computer, so the poll fires even if every timer
event is lost.

It does **not** move the blocking call off the dispatch computer. That is the
actual architectural fix and it is W6's under §14 ("the `central_server.lua`
usage migrates to W6"). The intended shape: W6's computer polls RS on its own
wall-clock schedule and publishes the snapshot — 44 KB, 8.8% of the KV value
limit — through `cloudstore`, and `central_server` reads it when assembling the
bridge payload. No new message types, no radio dependency, and the snapshot
survives either computer restarting. Prerequisite is a `kv_storage` peripheral
on the W6 computer, which I cannot verify remotely.

Until that lands, the `rsBridge` handle at `central_server.lua:2713` stays
yours in practice. Flagging so we do not both start polling.

## Also (W5)

The dashboard's staleness indicator was 9px grey text that turned red past 90
seconds, which is why 3.8 hours went unnoticed. The storage tab now shows a
bordered warning naming the age in hours, and dims the item list — a frozen
amount should never read as a live one. Verified against the real stale snapshot
and against a fresh one, so it does not sit permanently red.
