# Spec owner → W3: the registration storm, and the inbox that fixes it

- **From:** Spec owner
- **To:** W3 — Fleet & Dispatch
- **Date:** 2026-09-02
- **Subject:** Invariant G, `turtle_base.lua`, an 11.8-hour fleet outage
- **Status:** Root cause identified and evidenced. Mitigation shipped. **The fix is yours.**
- **Versions shipped during diagnosis:** 1.9.61 → 1.9.70

---

## 1. The ask

**Build the shared inbox.** Invariant G mandates `base.receive`; it has never
existed. Every worker runs raw `proto.receive` under `parallel.waitForAny`, and
that race took the fleet down for 11.8 hours on 2026-09-02.

Everything below is evidence, so you do not have to re-derive it, and a list of
six things already measured and cleared, so you do not re-chase them.

---

## 2. What the failure looks like

Captured live with the dashboard frozen 11.8 hours:

```
02:56:26  Re-registered node_119 [MINER] fuel=90852/100000
02:56:26  Re-registered node_102 [DELIVERY] fuel=93165/100000
02:56:26  Re-registered node_143 [SUPPORT] fuel=99972/100000
02:56:29  WARN Bridge push timed out (>5s)
02:56:33  Re-registered node_140 [SUPPORT] fuel=100000/100000
02:56:33  Re-registered node_103 [DELIVERY] fuel=87181/100000
02:56:33  Re-registered node_118 [MINER] fuel=80422/100000
02:56:34  WARN Bridge push timed out (>5s)
```

Three facts to read off it:

1. **The whole fleet re-registers together**, on a cycle. Earlier in the outage
   it was every 32 s; by the end, every 7 s.
2. **The fuel values are identical between rounds.** `node_138` reads 55284 in
   every burst, `node_143` reads 99972 in every burst. Nobody is working.
   Fifteen turtles are doing nothing but re-introducing themselves.
3. **A push failure lands 1–3 seconds after every burst, without exception.**

---

## 3. Root cause

`base.run()` drives `controlLoop` and `jobRunner` under `parallel.waitForAny`.
Both call `proto.receive`. They share one OS event queue, and whichever pulls an
event first consumes it.

`register()` at `turtle_base.lua:1624` waits for its `REGISTER_ACK` with:

```lua
local reply = proto.receive(_self.id, CFG.REGISTER_TIMEOUT)
```

**The server is receiving and answering.** It logs `Re-registered` for every
attempt — that line only exists on the success path. The ACK is sent and then
consumed by the other coroutine, which does not recognise it and discards it.
`register()` sees nothing, times out, and retries.

The same race eats `HEARTBEAT_ACK`, which is why a turtle that *did* register
still trips `serverDown` 15 s later and re-registers again. That is the cycle.

### Why it became a fleet-wide outage

The retry was a flat 5 s. So: retries add traffic → traffic drops more ACKs →
more turtles retry. A runaway. It ended with the CC server unable to complete a
single bridge push, and the dashboard frozen for 11.8 hours, while every health
metric read normal.

### Two things this explains that nothing else did

- **Rebooting one turtle fixes the whole fleet.** Observed three times. On a cold
  boot, `base.init` calls `register()` *before* `base.run()` starts the
  coroutines — nothing is there to steal the ACK, so it lands. The reboot also
  breaks the traffic storm, letting the rest converge.
- **The fleet cannot survive a server restart.** Any restart empties the
  registry and forces all workers through the broken path simultaneously.

---

## 4. Ruled out — do not re-chase these

Each was a live hypothesis, each was measured against the running system, and
each is innocent. Numbers are from `/state`, which now publishes them
continuously.

| Hypothesis | Measured | Verdict |
|---|---|---|
| Payload assembly blocks the loop | `pushBuildMs` **10–21 ms** | Innocent |
| RS storage poll blocks the loop | `rsPollMs` 8–61 ms, `rsPollWorstMs` **159 ms** | Innocent |
| Health pass blocks the loop | `healthMs` **0 ms** | Innocent |
| Server lost its modem | `modemOpen` **true**, no recovery ever triggered | Innocent |
| Terminate signals killing the server | `terminateCount` **0** since 1.9.66 | Innocent — the 12 in `crash.log` were the operator's own deliberate stops |
| Bridge or RCON too slow | Bridge **~1 ms**, RCON **24–27 ms** (operator-measured) | Innocent |

Two further notes for the record. Payload size was my own leading theory for
three days and it was wrong; it is worth reducing on its own merits but it did
not cause this. And every fix that appeared to help shipped with a server
restart — **the restart was doing the work**, which is how the real fault stayed
hidden.

---

## 5. What shipped during diagnosis

All are independently justified and none should be reverted, but understand that
**only 1.9.70 addresses the actual fault, and only partially.**

| Version | Change | Why it stands |
|---|---|---|
| 1.9.61 | Ship 10 log lines per node instead of 60 | Payload 190 KB → 92 KB. Worth keeping; not the cause. |
| 1.9.62 | Bridge push timeout 15 s → 5 s | The timeout equalled the fleet's patience (`MAX_MISSED` 3 × `HEARTBEAT_INTERVAL` 5 s), so recovery could never win the race. Real bug, real fix. |
| 1.9.63 | Publish `pushBuildMs` | Killed the payload theory in one reading. |
| 1.9.64 | Publish `rsPollMs` / `rsPollWorstMs` | Killed the RS theory. |
| 1.9.65 | `ensureModemLive` + `modemOpen` | Invariant B applied to the server, which never had it. Keep regardless. |
| 1.9.66 | Ignore terminate | **Superseded by 1.9.69.** Shipped on a wrong theory. |
| 1.9.67 | Log storage only on change | **The change that cracked this.** Log history went 2.2 min → 84 min, which is what made a 32-second cycle visible at all. |
| 1.9.68 | Publish `healthMs` / `healthWorstMs` | Killed the health-pass theory. |
| 1.9.69 | Ctrl+T as a double-press | Restores the operator's deploy workflow. |
| **1.9.70** | **Registration retry backoff 5/10/20/40/60 s** | **Mitigation only.** Stops the race feeding itself; does not fix it. |

---

## 6. The fix — yours

Build the inbox Invariant G already requires. The design existed once (v1.8.1),
was rolled back, and no part of it survives: no `base.receive`, no
`_ctrlInbox`, no `_jobInbox`, no `CTRL_TYPES`.

**Shape:**

- **Exactly one place pulls events.** Everything else reads from an inbox. This
  is the whole point; two `proto.receive` callers is the bug.
- **Two queues.** Control messages (`HEARTBEAT_ACK`, `RECALL`, `UPDATE_ALL`,
  `FORCE_REFUEL`, `REGISTER_ACK`) to `_ctrlInbox`; job and coordination messages
  to `_jobInbox`.
- **`base.receive(timeout)`** pops the job inbox. `register()` at
  `turtle_base.lua:1624` and both `proto.receive` calls in `ore_turtle.lua`
  (`:223`, `:259`) migrate to it.

**Two invariants from the original design, preserved here because they were
learned the hard way:**

1. **Hold, never push back inline.** Inside a receive loop, collect non-matching
   messages in a local `held` table and re-queue them *after* the loop. Pushing
   back inline spins the CPU — the receive drains the inbox first, so it re-pops
   what it just queued and never blocks.
2. **`HEARTBEAT_ACK` stays a control type.** It is the only proof the server is
   alive. If the job runner absorbs it, `_missedHeartbeats` reaches `MAX_MISSED`,
   `serverDown` trips, and `tryMove()` freezes all movement — which is a
   fleet-wide freeze, not a messaging bug, and looks nothing like one.

**Sequencing:** land the inbox, observe a full server restart in-world with the
fleet rejoining unaided, *then* consider relaxing 1.9.70's backoff. The backoff
is cheap insurance and should outlive the fix.

---

## 7. Instrumentation you now have

`/state` publishes, continuously: `pushBuildMs`, `rsPollMs`, `rsPollWorstMs`,
`healthMs`, `healthWorstMs`, `modemOpen`, `terminateCount`, `lastTerminateMs`,
`diskFree`, `storageHealth`, `zoneStoreHealthy`, `persistenceHealthy`.

The server log now holds **hours** rather than 2.2 minutes. Do not undo 1.9.67 —
every attempt to diagnose this before it landed was reading a two-minute window
into a fault that builds over days, and six wrong theories came out of that.

---

## 8. Related, and worth reading before you start

- `2026-08-30-scaling-to-150-turtles.md` §3.4 — this race gets structurally worse
  at 150 turtles, and §3.2's broadcast addressing multiplies every turtle's
  inbound traffic by fleet size. The inbox is a prerequisite for that work, not
  a parallel track.
- `2026-08-18-system-integration-design.md` Invariant G — the requirement, and
  the note that ACK loops make loss *visible*, not *absent*, because the hazard
  is receiver-side.
