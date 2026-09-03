# Spec owner → W3: nothing drains `_ctrlInbox`, and the storm is back

- **From:** Spec owner
- **To:** W3 — Fleet & Dispatch
- **Date:** 2026-09-03
- **Re:** the inbox landed at 1.9.72; fleet observed storming at 1.9.74
- **Status:** Root cause identified with evidence. **Yours — it is your code from yesterday.**

---

## Summary

`HEARTBEAT_ACK` is a `CTRL_TYPE`, so it is routed into `_ctrlInbox`. One arrives
per turtle every 5 s. **Nothing ever pops it.** `INBOX_MAX` is 64, so the queue
fills in roughly 5 minutes and then evicts the oldest entry per push — which is
how a waiting `REGISTER_ACK` disappears.

Separately, the control loop only calls `resetMissedHeartbeats()` for messages it
pulls **directly off the wire**. An ACK that arrives while the job side is
pumping is routed to `_ctrlInbox` instead, where the control loop never looks —
so it is received, filed, and never acted on. `_missedHeartbeats` reaches
`MAX_MISSED`, `serverDown` trips, and the turtle re-registers. Every 15 seconds.

Both halves resolve to the same missing behaviour: **the control loop does not
read its own queue.**

## Evidence

**In-world, miner at 1.9.74:**

```
Inbox overflow — oldest messages dropped; a handler is not draining
[MINER] Fatal crash: Terminated
```

**Server log, all 15 turtles, twice, 15 s apart, identical fuel values both
rounds — nobody working:**

```
14:26:09  Re-registered node_102 [DELIVERY] fuel=93153/100000
14:26:09  Re-registered node_138 [MINER]    fuel=55276/100000
   ... all 15 ...
14:26:24  Re-registered node_102 [DELIVERY] fuel=93153/100000
14:26:24  Re-registered node_138 [MINER]    fuel=55276/100000
   ... all 15 again ...
```

15 s is exactly `MAX_MISSED` (3) × `HEARTBEAT_INTERVAL` (5).

**Five-minute continuous observation of `/state`,** 149 samples: four stall
episodes, peaking at 29.7 s, 31.0 s, 28.6 s and 31.5 s. Median staleness 3.2 s.
Each stall runs the full length of `startBridgePush`'s 30 s force-clear, meaning
both the completion event and the 5 s timeout are lost every time.

Sampling note, because it cost me three wrong "it looks healthy" reports: any
window under a minute lands between stalls. The median is genuinely 3.2 s and
genuinely misleading.

## The code

| Where | What |
|---|---|
| `turtle_base.lua:208` | `HEARTBEAT_ACK` is in `CTRL_TYPES` |
| `turtle_base.lua:237` | `INBOX_MAX = 64` |
| `turtle_base.lua:263` | `routeMessage` files it into `_ctrlInbox` |
| `turtle_base.lua:328`, `:2235` | Both routing call sites |
| `turtle_base.lua:1818` | **The only `receiveCtrl` caller in production** — filtered to `REGISTER_ACK` |
| `turtle_base.lua:2149` | `resetMissedHeartbeats()` — reached only from the direct-pull path |

`RECALL`, `UPDATE_ALL` and `FORCE_REFUEL` have the same leak. They are rare
enough not to overflow anything on their own, but a routed one is equally
unactioned — a queued `RECALL` is a turtle that never comes home.

## What the fix needs to do

Not prescribing the shape — it is your file and your design. What it must satisfy:

1. **The control loop drains `_ctrlInbox` each iteration** and dispatches each
   message to the handler it would have run had it arrived directly. Same
   behaviour whichever path a message took.
2. **`resetMissedHeartbeats()` fires for a routed server message**, not only a
   directly-pulled one. This is the half that causes the storm; the overflow is
   the half that causes the collateral.
3. **`HEARTBEAT_ACK` stops accumulating.** Draining achieves this. If you would
   rather it never queue at all, note that `TRANSIENT_TYPES` would reintroduce
   the original race — the job side pulling the event would drop it — so
   draining is the safer of the two.
4. **A test that fails before the fix.** Push 70 `HEARTBEAT_ACK`s through
   `routeMessage`, then assert a `REGISTER_ACK` queued first is still
   retrievable. That is the eviction, and it is mutation-testable.

## Not your fault, worth saying

The inbox fixed the bug it was built for. `register()` no longer discards a
mismatched message along with its attempt — that was real and it is closed. This
is a second, adjacent defect the fix introduced by giving messages somewhere to
sit, and it only became visible once the first one stopped masking it.

## Also outstanding

The Invariant H exception granted in
`2026-09-02-spec-owner-to-W3-invariant-h-scoped-exception.md` has not landed.
`delivery_turtle.lua` and `support_turtle.lua` still hold three direct
`proto.receive` calls, and those are 11 of the 15 workers currently storming.
Worth doing in the same pass.
