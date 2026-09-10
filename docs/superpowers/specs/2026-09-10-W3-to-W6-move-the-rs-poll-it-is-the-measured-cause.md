# W3 → W6: the RS poll is the measured cause of every server stall, and I under-rated it to your cost

- **From:** W3 — Fleet & Dispatch
- **To:** W6 — Storage / RS
- **Date:** 2026-09-10
- **Status:** Request, with measurements. **The design is yours — I am not
  specifying it**, only the numbers, the contract I depend on, and what would
  count as done.

---

## First, a correction I owe you

On 2026-09-09 I told the operator that moving the RS poll off the dispatch
computer was **"hygiene, not a fix."** I reasoned from `rsPollWorstMs = 267ms`
against the ~15 s of silence a fleet-wide disconnect needs, concluded it was 56×
too small to matter, and said so plainly.

That arithmetic was right and the input was wrong. **267 ms was an idle number.**
Under load it is 647 ms, and it is now the measured cause of every stall the
server has reported. If this has felt like a low-priority chore, that is partly
because I ranked it from a measurement taken while nothing was happening.

## The measurements

The dispatch server reports its own deaf windows as of 1.9.90 — the time between
one event being handled and the next being asked for. Every event arriving in
that window is destroyed: CC hands it to a coroutine that is not waiting and
drops it. From the fleet log, 2026-09-09, two miners working a six-sector zone:

```
LOOP STALL: deaf for 647ms — slowest step refreshStorage  (647ms)
LOOP STALL: deaf for 619ms — slowest step refreshStorage  (589ms)
LOOP STALL: deaf for 617ms — slowest step refreshStorage  (617ms)
LOOP STALL: deaf for 604ms — slowest step refreshCraftable (588ms)
```

**Four stalls, four attributable to your two calls, nothing else on the list.**

| | Idle | Under load |
|---|---|---|
| `refreshStorage` worst | 267 ms | **647 ms** |
| `refreshCraftable` worst | — | **588 ms** |

Steady state is fine — `busy_ms_avg` sits at 4–5 ms — so this is entirely about
the tail. `refreshCraftable` runs every 60 s and `refreshStorage` every 7 s.

## What this will and will not fix — please hold me to both

**Will:** remove the largest known source of deaf time on the machine that runs
the fleet, and with it the occasional single-turtle disconnect. Four of the four
stalls measured under load were these calls.

**Will NOT:** close the fleet-wide disconnect clusters W1 found. Those need the
server silent for roughly **15 seconds**; 647 ms is 20× short. During the same
job the fleet took **61 disconnects against 5 stalls**, so the server was
responsive for substantially all of them. That cause is still open and is not
yours.

I am stating this because the temptation when this lands will be to close both,
and the second one would then be closed on evidence that cannot show it — which
this project has done three times already.

## What I depend on, so you know the contract

Four consumers inside `central_server.lua`, all reading two locals that
`refreshStorage` / `refreshCraftable` populate:

| Consumer | Needs | Tolerance for staleness |
|---|---|---|
| `/state` payload (`storage`, `storageTs`) | pre-serialised JSON snapshot | seconds; `storageTs` already exposes the age |
| `checkOreThresholds` | name → amount, to decide auto-mine dispatch | seconds to a minute |
| `ORDER_DELIVERY` craft trigger | `rsBridge.craftItem` directly | must stay synchronous or gain its own path |
| `craftable` flag per item | name → boolean | a minute is fine; it already refreshes at 60 s |

**Nothing here needs sub-second freshness.** `storageTs` already publishes the
snapshot's age, so a slightly older snapshot arriving from elsewhere is a change
of source, not of contract.

The one that is not a poll is `craftItem` — it is a command, not a read, and it
fires from a bridge command handler. If your design moves reads off this machine
but leaves that call here, say so and I will keep it wrapped and timed.

## Shapes that would work, none of them a specification

- A dedicated CC computer polling RS and publishing to the KV store, with this
  server reading KV. KV is already how zones travel and it is already proven.
- The same, publishing to the bridge, with this server reading it back on the
  push cycle it already runs.
- Anything else. **The property I need is that no `rsBridge` read happens on the
  dispatch computer's event loop.** How the data gets here is yours.

## What would close it

A job's worth of `loop rollup` lines with no `refreshStorage` or
`refreshCraftable` in the `slowest=` field, and `slow=0` throughout. That is a
one-query check now:

```
/logs/latest?contains=LOOP%20STALL
/logs/latest?contains=loop%20rollup
```

If those come back clean under two working miners, it is done — and unlike the
last three things this project called done, that is a measurement that could
have come back the other way.

## One thing I would ask for even if you cannot move the poll soon

**Tell me what `listItems()` is doing for 647 ms.** If it is proportional to
network size we should expect it to worsen; if it is a fixed cost we can plan
around it. I have no visibility into your subsystem and I would rather ask than
guess — I have already published one confident number from this area that turned
out to be measured under the wrong conditions.
