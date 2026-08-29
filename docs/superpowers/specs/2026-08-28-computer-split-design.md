# Computer Split Design — dividing `central_server` across machines

- **Date:** 2026-08-28
- **Status:** Design proposed; not approved; no implementation
- **Protocol version at time of writing:** 1.9.58
- **Author:** W6 (Storage) / W5 (Bridge & Dashboard)
- **Conforms to:** `2026-08-18-system-integration-design.md` — this document extends
  its §4 layer model and §11 contracts. Where the two disagree, that one wins and
  the conflict is a thing to raise, not to resolve by drift.

---

## 1. Purpose

`central_server.lua` is 3,938 lines and ~185 KB on a 1 MB disk. This document
decides **which responsibilities move onto their own ComputerCraft computers,
what owns which state, and how those computers talk.**

It deliberately does **not** design any one computer's internals. Those become
sub-specs (§13). This is the shape everyone builds against.

---

## 2. Why — measured, not asserted

Every number here was observed in-world on 2026-08-27/28.

| Observation | Consequence |
|---|---|
| `central_server.lua` = **185 KB**, disk = 1 MB | Updating it needs its own size free *alongside* the existing copy. It hit `Out of space` mid-deploy: 166,813 free, 185,351 needed. |
| The deploy half-applied and **rebooted anyway** | The machine ran an old server while reporting a new `proto.VERSION`. Two rounds of diagnosis went into code that was not running. |
| `/state` payload ≈ **125 KB**, serialised every 3 s | On the dispatcher's event loop. `Bridge push timed out (>15s)` observed repeatedly. |
| Timer events are **demonstrably dropped** | The RS poll died minutes after every boot. It now survives only because a wall-clock fallback carries it; the timer itself appears to still be dropping. |
| CC event queue = 256 slots | Shared by every subsystem on that computer. More work on one machine means more dropped events for all of it. |

One correction, recorded because it shaped earlier thinking and was wrong:
`rsBridge.listItems()` was assumed to be a multi-second blocking call and blamed
for the queue overflow. **Measured: 450 items in 37 ms.** It is not the cause.
Whatever is timing out bridge pushes has not been identified, and this document
does not assume the split fixes it — it makes it observable in isolation.

**What changed to make splitting practical:** `cloudstore` / `kv_storage`. Before
it, dividing responsibilities meant coordinating over the wireless modem — which
the integration spec's own §18 and Invariant G call the weak point. KV gives a
reliable, persistent store shared across every computer the player owns. That
turns "distributed coordination" into "one writer publishes, others read," which
is a far smaller problem.

---

## 3. Rejected: an array of interchangeable servers

Replicating `central_server` across N peers was considered and rejected.

- **The state is densely interconnected.** One `dispatcher.tick()` reads the
  registry, the job queue, sector leases *and* fuel estimates. Sharded, every
  decision becomes several remote reads.
- **There is no consensus primitive.** Two dispatchers can assign one turtle to
  two jobs, or grant one sector twice. Sector leases work today precisely because
  they are in-process.
- **It multiplies known debt.** The dual-state-tracking problem (server mirror vs
  turtle truth) is already unresolved. Peer servers add a third copy to reconcile.

**Specialise by responsibility; do not replicate.** This is what §4's layer model
already describes, and the pattern is proven twice here — `warehouse.lua` runs on
its own computer, and `planner.lua` is designed to.

---

## 4. Principles

Extending the integration spec's P1–P7.

**S1 — One writer per piece of state.** Every key, namespace and table has exactly
one computer that may write it. Everyone else reads. No exceptions, because KV
offers no transactions and no compare-and-swap; two writers to one key is a lost
update with no error.

**S2 — Arbitration is never shared.** Anything that grants exclusive access —
sector leases, dock assignment, job assignment — lives with a single owner and is
never coordinated through KV. KV is for snapshots, not for deciding who gets what.

**S3 — Every split ships with the old path intact.** A computer that is absent
must degrade to current behaviour, not to a failure. This is "mods add capability,
never replace it" generalised: the dispatcher keeps its fallback until the new
computer has been observed working, and the fallback is removed in a later commit,
never the same one.

**S4 — Radio carries commands; KV carries state.** A message that must reach one
node promptly and change its behaviour goes over the modem with the existing ACK
discipline. Bulk state that many readers want goes in KV. Never the reverse — a
125 KB snapshot does not belong on the radio, and a recall does not belong in a
polled key.

**S5 — Measure before assuming a call is cheap or expensive.** Today's session
produced two wrong assumptions in opposite directions (`listItems` assumed slow,
was 37 ms; a full disk assumed impossible, was the root cause). Every cadence in
this design is provisional until §12's measurements exist.

---

## 5. Target topology

| Computer | Owns | Status |
|---|---|---|
| **dispatch** | Registry, job queue, dispatcher, message handlers, recovery, dock assignment | Exists — shrinks |
| **mine** | Zones, sectors, leases, ore accounting, phase ETA, mine-trip fuel | **New** |
| **gateway** | `/state` assembly, HTTP to the Node bridge, dashboard command intake | **New** |
| **warehouse** | Refined Storage, item movement, stock and craft interface (§11.7) | Exists — W6 |
| **planner** | Projects, BOM, deficits, approval | Planned — W2 |
| **admin** | In-world UI | Exists |

Line counts behind the two new ones, measured from the current file:

| Block | Lines |
|---|---|
| Main loop — payload assembly, bridge commands, RS poll, watchdogs | **1,180** |
| Mining brain — zone store, active zones, ore accounting, ETA, leases, fuel | **1,184** |
| Message handlers | 498 |
| Registry | 295 |
| Dispatcher | 176 |

Extracting both takes `central_server.lua` from 3,938 lines to **1,574** —
comfortably updatable, and small enough that a future split is a choice rather
than a rescue. (The mining figure excludes the job queue and terminal-outcome
blocks that sit between those sections; they stay with dispatch.)

---

## 6. State ownership map (S1)

| State | Writer | Readers | Transport |
|---|---|---|---|
| Worker registry | dispatch | gateway | KV `fl:` |
| Job queue and status | dispatch | gateway, planner | KV `fl:` |
| Dock assignment | dispatch | — | local |
| Mine zones (`z:`) | **mine** | dispatch, gateway | KV `z:` |
| Sector leases | **mine** | — | local — never shared (S2) |
| Ore accounting, phase ETA | mine | gateway | KV `z:` |
| RS stock snapshot | **warehouse** | dispatch, planner, gateway | KV `st:` |
| RS craftability | warehouse | planner | KV `st:` |
| Server log ring | dispatch | gateway | KV `fl:` |
| Storage/persistence health | each writer, for its own | gateway | KV, alongside its data |

Note the change of ownership for zones: `z:` is written by `central_server` today
and moves to **mine**. That is a migration, not a rename — §11.

---

## 7. Transport rules

**KV (`cloudstore`)** — snapshots, one writer, many readers. Persistent across
reboots of either end, which is what makes a gateway restart invisible to the
dashboard.

**Radio** — commands and events addressed to one node. All existing contracts
stay exactly as they are. New ones follow Invariant G: ACK on every
worker↔worker signal.

**HTTP** — only the gateway talks to the Node bridge. The dispatch computer makes
no HTTP calls at all after the split, which removes both the 125 KB serialisation
and the 15-second timeout path from the fleet's event loop.

### 7.1 Snapshot keys are split by section

A single 125 KB blob would work — it is under the 500 KB value limit — but it
forces a full rewrite when one field changes. Sections instead:

| Key | Contents | Approx size |
|---|---|---|
| `fl:turtles` | Registry snapshot | ~15 KB |
| `fl:jobs` | Active jobs | ~5 KB |
| `fl:log` | Last 100 log lines | ~10 KB |
| `fl:health` | Disk, persistence, storage health, version, **running server file size** | <1 KB |
| `st:items` | RS snapshot | ~44 KB |
| `st:craft` | Craftable index | ~5 KB |
| `z:*` | One key per zone | existing |

`fl:health` carries the running server file's byte size deliberately. A partial
update produced a machine advertising a version it was not running; a size that
disagrees with the repo makes that visible in one glance instead of two rounds of
investigation.

### 7.2 KV budget

`cloudstore.BUDGET` gains two namespaces. Both are tiny — these are few keys, not
many — and sit far inside the measured 10,240-key limit.

```lua
[cloudstore.NS.FLEET]   = 50,    -- "fl": fleet/dashboard snapshot sections
[cloudstore.NS.STOCK]   = 50,    -- "st": RS stock and craftability
```

Each namespace also consumes one key for its `__index` entry.

---

## 8. New message contracts

Additive only (P6). Proposed as **§11.8** and **§11.9** of the integration spec;
they belong there once agreed, and `protocol.lua` changes are announced and
version-bumped.

### 8.1 Gateway ↔ Dispatch (§11.8)

The gateway never reads fleet state over the radio — it reads KV. The radio
carries only dashboard commands inward.

| Message | Direction | Payload |
|---|---|---|
| `BRIDGE_CMD` | gateway → dispatch | `{ cmdId, type, params }` |
| `BRIDGE_CMD_ACK` | dispatch → gateway | `{ cmdId, ok, reason }` |

`cmdId` is the existing dedup key (`ts` + type) promoted to a field. The gateway
retries an unacknowledged command; `cmdId` makes that safe.

### 8.2 Dispatch ↔ Mine (§11.9)

| Message | Direction | Payload |
|---|---|---|
| `SECTOR_REQUEST_FWD` | dispatch → mine | `{ minerId, jobId }` |
| `SECTOR_ASSIGN_FWD` | mine → dispatch | `{ minerId, jobId, sector }` |
| `SECTOR_RESULT_FWD` | dispatch → mine | `{ minerId, jobId, sector, kind, ores }` where `kind` is `"scan"` or `"done"` |
| `MINE_JOB_SUBMIT` | dispatch → mine | `{ jobId, bounds, oreFilter, priority }` |
| `MINE_JOB_STATUS` | mine → dispatch | `{ jobId, state, pct, eta }` |

**Miners keep addressing the dispatch computer.** Their sector traffic is
forwarded. This costs a hop, and it is the right first move because it needs **no
change to `ore_turtle.lua`** (W1's file, and the most defect-prone code in the
project). Letting miners address the mine computer directly is a later
optimisation, gated on the forwarding contract being proven and on W1 agreeing —
not a day-one decision.

---

## 9. Failure behaviour (P1)

Each row is a requirement, not a prediction.

| Computer down | Effect | Must NOT happen |
|---|---|---|
| **gateway** | Dashboard goes stale and says so. Fleet entirely unaffected. | Any effect on dispatch or workers |
| **mine** | No new sector assignments. Miners finish the current sector and return. Dispatch still recalls, refuels, and reassigns. | A miner stranded, or a lease leaked |
| **dispatch** | Work pauses. Turtles self-recover and reach dock unaided (Invariant E). | A worker stranded in the field |
| **warehouse** | Deliveries stall; nothing lost | Items lost in the ender chest |
| **KV unavailable** | Every reader keeps its last snapshot and reports it as stale | Any computer failing to boot or crashing |

The KV row is S3 applied: `cloudstore.available()` returning false must be
survivable everywhere, exactly as it already is for zones.

---

## 10. Extraction order

**1 — Gateway.** Smallest, targets a live failure (>15 s push timeouts), needs no
turtle changes, and is fully reversible. It also isolates the timeout: if pushes
still time out from a computer doing nothing else, the cause is the bridge or the
network, not the event loop — which we currently cannot tell apart.

**2 — Storage snapshot publisher (W6).** Warehouse already holds an `rsBridge` and
already polls. Publishing `st:items` removes 44 KB from the dispatch payload and
the RS poll from the dispatch loop. Small, and W6 owns both ends.

**3 — Mine brain.** The largest single win on file size, and the highest coupling.
Third because the two above make it safer and because it needs the forwarding
contract in §8.2 settled first.

**4 — Planner.** Already specced, already assigned to W2, gated on §11.7.

---

## 11. Migration and rollout

Every extraction follows the same shape, which is the one the zone migration
already proved:

1. **Read before write.** The new consumer reads from the new location, falling
   back to the old, before anything writes there.
2. **Write to both.** The new owner writes the new location while the old path
   still functions.
3. **Observe in-world** across a restart of each side.
4. **Remove the fallback** in a separate, later commit.

Zone ownership moving from dispatch to mine is the one true migration: `z:` keys
keep their format and their namespace, and only the writer changes. Step 2 is
therefore "both computers can write `z:`", which **violates S1 temporarily**. That
window must be short, must be stated in the commit, and the mine computer is the
writer the moment step 3 passes.

---

## 12. Prerequisite measurements

Per S5, these are unknown and every cadence above is provisional until they exist.
Each is a small in-world probe, not a build.

| # | Question | Blocks |
|---|---|---|
| **M1** | How long does `cloudstore.put` take for a 44 KB value? For 125 KB? | Whether snapshot cadence can match the current 3 s push |
| **M2** | How long does `cloudstore.get` take at those sizes? | Whether the gateway can poll KV at 3 s |
| **M3** | Does a second computer's KV access contend with the first? | Whether readers and the writer can run at the same cadence |
| **M4** | Does the >15 s bridge push timeout persist on a computer doing nothing else? | Whether the timeout is event-loop pressure or the bridge itself |
| **M5** | Is a `kv_storage` peripheral available for each new computer in-world? | Everything — confirmed available in principle, not yet placed |

M1–M3 decide whether KV is fast enough to be the transport at all. If it is not,
the fallback is the gateway pulling state over the radio in sections, which is
worse but workable — and better to discover with a probe than in a rewrite.

---

## 13. Sub-specs this defers

This document is deliberately topology-only. Each computer's internals get their
own spec, conforming to the contracts here.

| Sub-spec | Owner | Covers |
|---|---|---|
| **Gateway** | W5 | Snapshot assembly from `fl:`/`st:`/`z:`, `/state` shape compatibility, command intake and retry, staleness reporting, bridge auto-start |
| **Storage publisher** | W6 | RS poll cadence, `st:` key format, §11.7 stock-and-craft interface, craft tracking and `missing[]` |
| **Mine brain** | W1 + W3 | Zone/sector/lease internals, the forwarding contract, ore accounting and ETA |
| **Dispatch after the split** | W3 | What remains, and what the fallbacks look like once removed |

---

## 14. Verification

Per §13.2: nothing is claimed verified without the headless harness or an in-world
test, and new tests are mutation-tested (§13.3).

- Snapshot assembly and staleness logic are **pure functions** and belong in
  `tests/`. This is the main reason to extract them: they are currently
  unreachable inside `server.run`'s closure.
- The `__CC_SERVER_TEST` seam pattern extends to each new computer. Any new server
  program exposes its internals the same way, from the start rather than
  retrofitted.
- Each extraction's rollout step 3 is an explicit in-world observation with a
  named thing to look for, not "it seems fine."

---

## 15. Out of scope

Not designed here: splitting `central_server.lua` into multiple *files* on one
computer (worth doing, orthogonal, and cheaper); the Node bridge's internals;
authentication; log aggregation via `NS.LOG`; and moving `jobs.dat` or
`crash.log` into KV. The last two are the obvious next disk-pressure work and
should get their own plan once the gateway lands.
