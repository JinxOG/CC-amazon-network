# Scaling Turtle OS to 150 Turtles

- **Date:** 2026-08-30
- **Status:** Design proposed; not approved; no implementation
- **Protocol version at time of writing:** 1.9.61
- **Author:** Spec owner
- **Target:** 150 turtles on one network, stated by the user 2026-08-30
- **Conforms to:** `2026-08-18-system-integration-design.md`. Where the two
  disagree, that one wins and the conflict is raised, not resolved by drift.

---

## 1. Purpose

The fleet is 15–18 turtles today and lost contact with the server for most of a
day on 2026-08-30. That outage was fixed, and the fix does not reach 150.

This document says **which parts of the current architecture survive to 150 and
which do not**, with the arithmetic for each. It does not design the
replacements in detail; those become sub-specs (§9).

It sits alongside `2026-08-28-computer-split-design.md`, which remains approved.
**The split is necessary and not sufficient** — §7 says exactly which of these
problems it solves and which it leaves untouched.

---

## 2. Measured baseline

Taken from the live bridge on 2026-08-30 at v1.9.61, 15 turtles, after the
payload fix in `d680696`.

| Quantity | Measured |
|---|---|
| Per-turtle record in the payload | **268 B** |
| Per-turtle log window (10 lines) | **852 B** |
| Fleet-independent payload (storage + zones + server log) | **87,395 B** |
| Payload today | **92 KB** |
| Worst dashboard staleness today | **4.7 s** |
| Payload at which the fleet lost contact, same day | **186 KB** |
| Heartbeat interval (`turtle_base.lua:18`) | **5 s** |
| CC event queue | **256 slots** |

The 186 KB figure is the load-bearing one. It is not a theoretical limit — it is
the size at which this fleet, on this hardware, demonstrably dropped heartbeats
until turtles unregistered themselves.

---

## 3. What breaks, with the arithmetic

### 3.1 The payload grows with the fleet — wall at ~100 turtles

```
payload(N) = 87,395 + (268 + 852) × N
```

| Fleet | Payload | |
|---|---|---|
| 18 | 105 KB | today |
| 50 | 140 KB | |
| **100** | **195 KB** | **past the 186 KB failure point** |
| 150 | 250 KB | 34% worse than the state that broke it |

The 2026-08-30 fix cut the payload by half and bought roughly 80 turtles of
headroom. It did not change the slope. **The same outage returns at about 90.**

The mechanism is recorded in `2026-08-18-system-integration-design.md` and in
the commit message for `d680696`: payload assembly is synchronous, the server is
deaf to radio while it runs, and CC's event queue drops what arrives meanwhile.

### 3.2 Targeted messages are broadcast to the whole fleet — the worst one

`central_server.lua:125` — every message addressed to one turtle:

```lua
proto.send(state.modem, proto.CH_PRIVATE, msg)
```

`turtle_base.lua:174` — every turtle listens on that channel:

```lua
local CHANNELS = { proto.CH_BROADCAST, proto.CH_PRIVATE, proto.CH_LOCAL }
```

**So a message for one turtle is delivered to all N**, each of which decodes it
and discards it. Cost per targeted message is O(N), and the number of targeted
messages also rises with N, so total waste is **O(N²)**.

At 18 turtles this is tolerable. At 150 a single job assignment costs 149
turtles a wasted decode, and each of those turtles has its own 256-slot queue
with no inbox to protect it (§3.4).

**`CH_LOCAL` has the same shape and a worse cadence.** `POSITION_UPDATE` fires
**per step** of a moving turtle (`ore_turtle.lua`, `support_turtle.lua`), and
every turtle listens on `CH_LOCAL`. Twenty turtles moving at roughly one block
per second is ~20 messages/s, each delivered to 150 turtles: **~3,000 event
deliveries per second fleet-wide** to serve twenty pairs.

This is the single largest architectural threat at scale and it is not addressed
anywhere in the current design.

### 3.3 Inbound message rate at the server

Heartbeats alone, at the 5 s interval:

| Fleet | Heartbeats/s |
|---|---|
| 18 | 3.6 |
| 150 | **30** |

Before job traffic, sector traffic, or log shipping. Every one lands in a
256-slot queue on a machine that is periodically deaf (§3.1). The queue does not
need to be full on average; it needs to be full during one assembly window.

### 3.4 The shared inbox still does not exist

Invariant G mandates `base.receive`. It is not implemented — no `base.receive`,
no `_ctrlInbox`, no `CTRL_TYPES` in `turtle_base.lua`. Every worker runs raw
`proto.receive` under `parallel.waitForAny`, where the control loop silently
consumes messages the job runner needed.

At 18 turtles this is a latent hazard. At 150, with §3.2 multiplying every
turtle's inbound traffic by the fleet size, it stops being latent.

**This is the one item on the list that is already agreed and already overdue.**

### 3.5 The depot is a single point of physical contention

Invariant I. The whole fleet departs through one dispatch hole and returns
through one arrivals hole. One support turtle parked on the hole has already
stalled every pair behind it at fleet size 18.

There is no ordering, no throughput bound and no owner for the bottleneck
itself. 150 turtles through one block is not a queueing problem, it is a
deadlock waiting for a busy day.

### 3.6 Registry and dispatcher cost

`state.registry` holds a record per turtle in RAM on one CC computer, and
`dispatcher.tick()` walks it. Both are linear in N and neither is measured.
Listed for completeness; **unquantified**, and §8 says so rather than guessing.

---

## 4. Principles for scale

Extending P1–P7 of the integration spec.

**L1 — No per-message cost may scale with fleet size.** A message for one turtle
must reach one turtle. This is the direct answer to §3.2 and it is the
difference between O(N) and O(N²) growth in fleet-wide work.

**L2 — The bridge payload must be O(1) in fleet size.** Anything that grows per
turtle belongs in KV, read by whoever needs it, not re-sent to everyone every
few seconds. §3.1 is what violating this costs.

**L3 — Every periodic cost gets a stated budget at 150, not at today's size.**
The payload had no declared ceiling and grew until it broke the fleet. Disk had
no ceiling and filled. Keys have a budget only because §13.1 gave them one after
the fact. A cadence or a size with no number attached is a future outage.

**L4 — Synchronous work on the dispatch loop is a fleet-wide outage risk.** Not
a performance concern. While the loop is busy the fleet is unmanaged, and CC
drops the evidence.

**L5 — Contention is designed, not discovered.** Physical chokepoints, shared
channels and shared queues each need an owner and a bound before the fleet
grows into them.

---

## 5. Required changes

Ordered by the ratio of benefit to risk.

### 5.1 Per-turtle addressing — replaces `CH_PRIVATE`

Give each turtle its own channel, derived from its node id. A turtle opens its
own channel plus `CH_BROADCAST`. The server sends targeted traffic to that
channel alone.

- CC modems support **65,536** channels; the system currently uses **five**.
- Eliminates 149/150 of the delivery cost of every targeted message.
- Contained: `sendTo` (`central_server.lua:119`), the turtle's channel list
  (`turtle_base.lua:174`), and a channel-derivation function in `protocol.lua`.
- Additive under P6 — `CH_PRIVATE` stays open during migration and is retired in
  a later commit, per S3 of the split design.

**`CH_LOCAL` needs the same treatment** and is the more urgent half by traffic
volume. Partner-to-partner messages should address the partner, not the world.
This one is harder because a turtle must learn its partner's channel, so it is
scoped as its own sub-spec (§9).

### 5.2 Take per-turtle data out of the payload

`fl:turtles` in KV, written by dispatch, read by the gateway — exactly as the
split design's §6 already specifies. Combined with turtle logs moving to
`NS.LOG` with TTL, this makes payload size independent of fleet size and
satisfies L2.

After this, `payload(150)` is the fleet-independent 87 KB, not 250 KB — and that
87 KB is itself mostly the RS storage list, which §5.4 addresses.

### 5.3 Build the shared inbox

Invariant G, unchanged and already agreed. Its priority changes: at 150 turtles
with §5.1 not yet done, every turtle is processing fleet-wide traffic through an
unprotected event loop.

### 5.4 Storage snapshot out of the push

~48 KB of today's 92 KB, and fleet-independent, so it dominates once §5.2 lands.
The bridge already preserves a field omitted from an update
(`server.js:408`, `if (turtles) {...}` pattern), so sending it only on change is
viable without a bridge change. Cadence and change-detection are W6's.

### 5.5 Heartbeat cadence and staggering

30 heartbeats/s at 150 turtles on a 5 s interval. Options, in preference order:
stagger phase by node id so arrivals spread evenly rather than clustering; then
scale the interval with fleet size; then report-on-change with a slow keepalive.

**Do not raise the interval without checking `MAX_MISSED`.** Three missed
heartbeats trips `serverDown`, so the interval sets how long a turtle waits
before concluding the server is gone and re-registering — the recovery path that
failed on 2026-08-30.

### 5.6 Depot throughput

Invariant I, still unowned. At minimum: an ordering discipline at the hole, a
bounded wait, and a measured throughput ceiling that dispatch respects. A second
hole is the obvious lever and is a world change, not a code change.

---

## 6. What survives to 150 unchanged

Stated so the work is scoped to what actually needs it.

- **Cloud KV storage.** 10,240 keys against a declared budget of ~8,800 across
  every namespace, and values to 500 KB. Zones, index and logs all fit at 150.
- **The ender-chest fuel and payload model.** Per-turtle, no shared resource, no
  coordination. Scales indefinitely.
- **The job queue and lease model.** Leases are per-sector and in-process;
  §3 of the split design already rejects sharding them.
- **The capability-based dispatch model** (§6.4). Matching jobs to declared
  capabilities is independent of fleet size.
- **Refined Storage.** `listItems()` measured at 450 items in 37 ms, and item
  count does not scale with turtle count.

---

## 7. Relationship to the computer split

The split design is approved and remains so. Its contribution to scale, stated
honestly:

| Problem | Does the split fix it? |
|---|---|
| §3.1 payload grows with fleet | **Partly.** Moves assembly off the dispatch loop, so the deafness lands on the gateway instead. The payload still grows; the fleet is no longer collateral. §5.2 is the actual fix and the split makes it natural. |
| §3.2 broadcast addressing | **No.** Untouched. |
| §3.3 inbound rate at dispatch | **Partly.** Sector traffic moves to the mine computer, but §8.2's forwarding means dispatch still receives it — and the queue effect of that is unmeasured (raised in the split review, still open). |
| §3.4 missing inbox | **No.** Independent. |
| §3.5 depot contention | **No.** Untouched. |
| §3.6 registry/dispatcher cost | **Partly.** Zones and their accounting leave dispatch. |

**Two of the changes in §5 alter contracts the split is built on.** §5.1 changes
addressing, which the split's §8.1 and §8.2 message contracts assume; §5.2 makes
`fl:turtles` load-bearing rather than convenient. Both should be agreed before
extraction 3, and §5.1 before any new message contract is written.

---

## 8. Prerequisite measurements

Per S5 of the split design — measure before assuming. Every number in §5 is
provisional until these exist.

| # | Question | Blocks |
|---|---|---|
| **N1** | What is the actual inbound message rate at the server today, by type? Heartbeat, log, sector, job. | Every projection in §3.3; whether logs or heartbeats dominate |
| **N2** | How long does `buildBridgePayload` take at 92 KB, and at 250 KB? | Whether §5.2 is sufficient alone, and the real deaf-window duration |
| **N3** | Does a turtle on a dedicated channel measurably drop fewer messages than one on `CH_PRIVATE`, at current fleet size? | §5.1 — proves the mechanism before a protocol change |
| **N4** | What is `dispatcher.tick()`'s cost at 15 turtles, and does it scale linearly? | §3.6, currently unquantified |
| **N5** | Sustained depot throughput — turtles per minute through the dispatch hole. | §5.6, and whether one hole can serve 150 at all |

N3 is the cheapest and unblocks the largest change. Run it first.

---

## 9. Sub-specs this defers

| Sub-spec | Owner | Covers |
|---|---|---|
| Per-turtle addressing | W3 | Channel derivation, migration, `CH_PRIVATE` retirement |
| Partner addressing on `CH_LOCAL` | W3 + W1 | How a turtle learns its partner's channel; `POSITION_UPDATE` cadence |
| Fleet snapshot in KV | W3 + W5 | `fl:turtles` format, write cadence, gateway read path |
| Shared inbox | W3 | Invariant G, unchanged from its existing scope |
| Depot throughput | W3 | Ordering, bounded wait, second hole |

---

## 10. Out of scope

Not designed here: the internals of any change in §5; whether 150 is reachable
on one Minecraft server at all (a tick-budget question, not an architecture
one); chunk-loading coverage for a fleet spread across many sites; and the
building system, which adds builders to the same network and should be sized
against this document once its own design settles.
