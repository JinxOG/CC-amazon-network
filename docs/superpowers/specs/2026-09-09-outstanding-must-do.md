# Outstanding — the must-do list

- **Started:** 2026-09-09
- **Maintained by:** W3 — Fleet & Dispatch
- **Rule:** an item leaves this list when it is **measured** as done, not when it
  is written. Three things on it were once believed fixed on evidence that could
  not have shown otherwise.

---

## 1. Move the RS storage poll off the dispatch computer — **W6**

**Now evidence-backed rather than tidiness, and the evidence changed the
priority.** It is the measured cause of *every* server stall observed under load.

```
LOOP STALL: deaf for 647ms — slowest step refreshStorage (647ms)
LOOP STALL: deaf for 619ms — slowest step refreshStorage (589ms)
LOOP STALL: deaf for 604ms — slowest step refreshCraftable (588ms)
LOOP STALL: deaf for 617ms — slowest step refreshStorage (617ms)
```

Measured 2026-09-09, 20:36–21:01 UTC, two miners working a six-sector zone each.

| | Idle | Under load |
|---|---|---|
| Worst `refreshStorage` pause | 267 ms | **647 ms** |

**The idle number is what made me under-rate this.** On 2026-09-09 I told the
operator this task was "hygiene, not a fix," reasoning from 267 ms against the
~15 s a fleet-wide disconnect needs. Under load it is 2.4× worse, and it is now
the single largest source of deaf time on the machine that runs the fleet.
Everything arriving in those windows is destroyed — CC hands an event to a
coroutine that is not waiting and drops it.

**What it does NOT explain, so nobody over-claims when it lands:** the
fleet-wide disconnect clusters W1 measured need the server silent for roughly
15 seconds. 647 ms is 20× short. Expect this to remove the occasional
single-turtle disconnect and to remove the largest known yield. Expect it *not*
to close finding 1.

`refreshCraftable` appears in the same list and belongs in the same move.

## 2. The fleet-wide disconnect clusters — **unexplained, owner unassigned**

W1 measured 30 clusters of 8+ nodes in 14 hours (`6b4d52a`). Not reproduced in
the 25-minute loaded window on 2026-09-09 — four disconnects, four different
nodes, minutes apart, singles rather than clusters.

Both instruments now exist and neither has caught one in the act:

- Bridge busy: `push_ms_max=3.2, slow=0` under load. **Eliminated.**
- Server deaf time: worst 647 ms. **20× too small.**

So the cause is still outstanding and is larger than anything either instrument
has yet recorded. **Do not close this because the storage poll got fixed.**

## 3. Wire the crash handler to flush its dying words — **W1, W4**

A role's crash path prints the fatal error and reboots, with the control loop
that would have flushed it already dead. The most valuable line a turtle ever
writes is the one least likely to arrive. `base.flushLogs()` exists as of
1.9.89; the crash paths in `ore_turtle.lua`, `delivery_turtle.lua` and
`support_turtle.lua` need to call it before rebooting.

## 4. Sort the log query output by time — **W3**

The file is not chronological: turtles batch every 15 s while the server pushes
every 3 s, so a turtle's lines land after server lines that happened later.
Measured 37 backward steps in one day, up to 4 s. The timestamps are right; the
order is not. `?sort=ts` on the query endpoint, so nobody has to remember.

## 5. Warehouse and admin computers forward no logs at all — **unowned**

Phase 3 of the log work, never started. If a delivery fault lives in the
warehouse's logic it is invisible.

## 6. Reconcile the systemd unit with reality — **W5 / operator**

`deploy/cc-dashboard.service` is a templated unit that has never been installed;
the running service is a hand-written one from 3 June with no hardening. The
repo file now carries a warning, but the two have not been reconciled. Needs the
installed unit's full text and a decision on whether to adopt the hardening.

---

## Recently closed — kept because each was closed wrongly once

| Item | Closed on | Why it is really closed now |
|---|---|---|
| Log lines lost during outages | 1.9.89 | audit `verdict=clean`, 360/360 sequenced under load |
| Phase-lock storm | 1.9.87 | 0 fleet-wide episodes in 25 min — **but see item 2** |
| Equipment swap after the CC:Tweaked upgrade | verified 2026-09-09 | both miners ran `SWAP_TO_PICKAXE` and `RETRIEVING` repeatedly |
| Bridge as a stall suspect | 2026-09-09 | `log_share` under 10% of a sub-millisecond push |
