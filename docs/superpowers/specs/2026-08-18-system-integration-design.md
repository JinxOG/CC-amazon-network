# System Integration Spec — the shared vision

**Date:** 2026-08-18
**Status:** Design approved; implementation plans not yet written
**Protocol version at time of writing:** 1.9.13

---

## 1. Purpose and how to use this document

This is the **north star**. It exists so that several engineers working in
parallel on different subsystems build pieces that fit together on first
contact.

It is deliberately *not* a detailed design of any one subsystem. Each subsystem
gets its own spec — see [Related documents](#19-related-documents) — and this
document tells those specs what they must conform to.

**Read this before writing any subsystem spec or implementation plan.** If your
design contradicts something here, that is a signal to raise the conflict, not
to quietly diverge. This document changes by discussion, not by drift.

Three things it settles:

1. **What we are building toward**, so no one optimises a subsystem in a
   direction the system doesn't want to go.
2. **The contracts between subsystems**, so two engineers can build against each
   other before either side exists.
3. **Who owns what**, so parallel work does not collide in the same file.

---

## 2. North star

A player submits a high-level request — *"build a warehouse here"*, *"run a road
from A to B"*, *"keep 2,000 iron ingots in stock"* — and the system carries it
out with no further intervention.

Concretely, the system must:

- work out everything the request needs, down to raw materials;
- know what it already has in Refined Storage;
- know **what the fleet is capable of obtaining**, and say so up front when it
  is not capable;
- acquire the deficit — mining ore, harvesting surface resources, or asking RS
  to craft it;
- deliver materials where they are needed;
- build the structure;
- and report progress the whole way.

The one intentional exception to full autonomy is a **single approval gate**
after planning (§10). Everything before it is automatic; everything after it
runs to completion untouched.

---

## 3. Design principles

These are the tie-breakers. When a design decision is genuinely balanced, these
decide it.

**P1 — Every layer must fail without stranding the layer below it.**
The bridge going down must not affect a turtle in the field. The planner going
down must not stop in-flight jobs. The server going down must not strand a
turtle away from base. This generalises Invariant E from the solo-miner plan to
the whole system.

**P2 — No turtle is idle because of what it is.**
Any design that leaves one class of turtle saturated while another sits docked
is wrong. Roles are **capabilities a turtle acquires by swapping equipment**,
not identities it is born with. Fleet mobility is a first-class goal, not an
optimisation.

**P3 — Infeasibility is discovered at plan time, never at build time.**
The worst failure mode in the system is a half-built structure and a stalled
fleet because nobody can obtain an item. Every material must resolve to an
acquisition method before the approval gate.

**P4 — Indexed world data is a hint, never truth.**
Players, mobs, and world changes invalidate anything we recorded. Every consumer
of indexed data must tolerate the block being gone, and must be able to refresh
what it finds stale.

**P5 — State that matters lives server-side, not on the worker.**
Workers die, get killed, unload with their chunk, and reboot. Any protocol that
assumes a worker survives its task is defective. Work is reassignable by
default.

**P6 — Additive protocol change only.**
New message types may be added. Existing ones are never repurposed or silently
reshaped.

---

## 4. Layer model

Five layers. Each is owned by different code, and P1 governs their failure
relationships.

| Layer | Runs on | Owns | If it fails |
|---|---|---|---|
| **Intent** | Node bridge + web dashboard | Auth, project submission, Dynmap drawing, blueprint conversion, monitoring | No new submissions. Fleet unaffected. Fails closed. |
| **Planning** | `planner` CC computer *(new)* | BOM, stock check, deficit → jobs, project lifecycle | No new projects planned. In-flight jobs still execute. |
| **Dispatch** | `central_server.lua` | Registry, job queue, assignment, zones, recovery | Work pauses. Turtles still self-recover and return home. |
| **Execution** | Turtles and Androids | Doing the work | That worker's task is reassigned. |
| **Storage** | `warehouse.lua` + Refined Storage | Item in/out, autocrafting, stock levels | Deliveries stall; nothing is lost. |

### 4.1 Why the planner is an in-world computer

The planner runs on its own ComputerCraft computer, following the proven
`warehouse.lua` pattern: a separate computer that does not reboot with the
Minecraft server and needs no process on anyone's PC.

Rejected: **putting project planning on the Node bridge.** It would have given
us npm libraries and real disk, but it makes a PC-side process load-bearing for
autonomy, which is both operationally fragile and hard to re-set-up later.

Rejected: **putting project planning inside `central_server.lua`.** That file is
already ~153 KB with documented event-loop stalls from serialising zone data. It
does not get more responsibilities.

Two facts make the in-world planner practical:

- **Refined Storage already does recipe-tree expansion.** `rsBridge.craftItem()`
  resolves the whole tree itself and reports what is missing. We never need a
  recipe database or npm.
- **Blueprint parsing is the only genuinely hard-in-Lua part** (`.litematic` is
  gzipped NBT), and it is a **one-time offline conversion** on the bridge, not a
  runtime dependency.

### 4.2 The bridge is never load-bearing

The Node bridge owns the web UI, hosting Lua files for `install`, the Dynmap
proxy, monitoring, one-time blueprint conversion, and — later — authentication
and quotas. It is the gateway for **submission**, never for **execution**.

**Operational requirement:** the bridge must start automatically with its host
machine, via a Windows service (NSSM) or Task Scheduler "at startup". Manual
restart after a host reboot is a defect, not a workflow.

---

## 5. Vocabulary

Fixed terms. Use these exactly; do not introduce synonyms.

| Term | Meaning |
|---|---|
| **Project** | A user request with a lifecycle (§9). "Build a warehouse." |
| **Job** | A primitive the dispatcher assigns to one worker. `MINE`, `DELIVER`, `SURVEY`, `HARVEST`, `BUILD`. |
| **Zone / Sector** | Existing mining geography. A zone is a mining region; a sector is a scan/work unit within it. |
| **Site** | A surveyed region in the World Resource Index. |
| **Placement Set** | A list of blocks at absolute world coordinates. **The universal build input.** |
| **BOM** | Bill of materials — aggregated item counts a project needs. |
| **Capability** | Something a worker can do right now, given its equipment and cargo. |
| **Acquisition Method** | How a material is obtained (§8). |
| **Census** | Per-sector name→count of every block type. Tier 1 of the index. |
| **Coordinate Index** | Packed exact coordinates for watchlisted materials. Tier 2. |

---

## 6. Fleet catalog

### 6.1 Universal conventions

Binding across every turtle type.

| Slot | Contents |
|---|---|
| **15** | Fuel ender chest — always, every turtle |
| **16** | Payload ender chest — ore chest on a miner, delivery chest on a delivery turtle. Only ever the payload chest. |

- Item registry names are pinned in `equipment.ITEMS` and are **never hardcoded
  elsewhere**. Verified in-world 2026-08-13.
- **Two upgrade slots, three or more needs.** No turtle holds modem + chunky +
  pickaxe simultaneously. Capability is therefore *phase-dependent*, and
  `equipment.lua` owns every transition. This is the most misunderstood
  constraint in the codebase.

The miner's three phases, from `equipment.lua`:

| Phase | Equipped | Sacrificed |
|---|---|---|
| travel | modem + chunky | pickaxe — self-loading, cannot dig |
| mine | modem + pickaxe | chunky — placed loader holds the chunk |
| retrieve | chunky + pickaxe | modem — comms down, can dig and stay loaded |

Losing comms is self-correcting; losing chunk loading outside the base-loaded
area is an unrecoverable freeze. **Retrieval always sacrifices the modem.**

### 6.2 Fleet today

| Type | Equipment | Slots | Status |
|---|---|---|---|
| **Miner** | modem/chunky/pickaxe cycling | 1 scanner, 2 carried loader, 3 stowed tool, 4 modem (retrieval only), 14 coal, 15 fuel EC, 16 ore EC | Current. Solo — no partner. |
| **Delivery** | modem + pickaxe | 15 fuel EC, 16 delivery EC | Current. Still paired with support. |
| **Support** | modem + chunky | — | **Deprecated.** Mining no longer uses it; delivery still does. |
| **Loader** | chunky | — | Placed, idle, runs no program. Holds 5×5 chunks = 80×80 blocks. |
| **Android** | 9 hotbar slots, redstone fuel | — | `moveTo` / `useBlock` / `breakBlock` / `grabItemFromContainer`. **Cannot self-chunk-load. Is an entity — can be killed.** |

### 6.3 Fleet target

Three classes:

- **`WORKER`** — general purpose. Self chunk-loads, swaps its own equipment, and
  takes any job it is equipped for: mine, deliver, survey, harvest, excavate.
- **`ANDROID`** — humanoid placement tasks only, stationed inside a pre-loaded
  volume.
- **`LOADER`** — placed idle chunky turtle. Never dispatched, never runs a
  program.

### 6.4 Capability → equipment

The dispatcher uses this to decide whether a given worker can take a given job.

| Capability | Requires |
|---|---|
| `COMMS` | ender modem equipped |
| `MINE` | pickaxe equipped + chunk coverage (own chunky or placed loader) |
| `SCAN` | geo scanner in inventory (placed and picked up per scan) |
| `DELIVER` | payload ender chest in slot 16 |
| `HARVEST` | pickaxe + sapling stock for replanting (§6.6) — plus possibly axe/shovel, **pending V4** |
| `BUILD` | builder class TBD — **pending Probe C** |

### 6.5 Generalised tool carry

The miner's current swap logic is hardcoded to three items. The target model
carries **N tools** as configuration, so adding an axe or shovel is a config
entry rather than a rewrite of the swap dance.

**This model is specified now; the extra tools are not committed until V4
resolves.** A diamond pickaxe in CC:Tweaked already breaks logs, dirt, sand, and
gravel with correct drops, so for vanilla materials extra tools may buy nothing.

**Speed is not a factor and must not be used as an argument for extra tools.**
`turtle.dig()` breaks a block in a single action and then waits out a fixed
action cooldown; neither block hardness nor tool type scales it — a turtle digs
obsidian as fast as dirt. Turtle tools also take no durability damage. A pickaxe
and an axe dig a log at identical speed.

The tool decides only two things: **whether the block breaks at all** (harvest
level / tool-type check) and **what it drops**. So extra tools are justified only
by drop correctness — modded blocks that gate drops behind a tool type. Each
additional tool costs an inventory slot and another state in the most
defect-prone code in the project, so the cost is only paid once the benefit is
measured.

**Shears are not required for sustainable forestry, and would work against it.**
Leaves drop saplings (chance-based) when broken by *anything except* shears or
Silk Touch; with shears the leaf **block** drops instead and no sapling. The
worker therefore breaks leaves with the pickaxe it already carries. Shears are
justified only if leaf blocks are separately wanted as a building material — it
is either/or per leaf block, never both — and are gated on **V7**.

### 6.6 Sustainable forestry

Harvest sites **regrow**. A `HARVEST` job targeting trees carries a **replant
obligation**: collect saplings from broken leaves and replant before leaving.

Two consequences that reach beyond the harvest job itself:

- **The worker must carry sapling stock** (one inventory slot per species in
  play), seeded from RS if the site's own drops are insufficient.
- **A forestry site is a renewable stock, not a finite one** (§7.3). Its census
  recovers over time, so it must not be treated as depleted after harvest the way
  a mined-out ore sector is.

---

## 7. World Resource Index

One store, one code path, several resource classes. **Ore is simply the first
class in it** — the ore coordinate index design is the implementation of this
pattern, not a separate system.

### 7.1 Two tiers

**Tier 1 — Census.** Name→count for every block type in each sector. Cheap
(~50 entries per sector), always stored. This is the searchable *"where in the
world is spruce"* layer and the answer to *"how much is actually there."*

**Tier 2 — Coordinate Index.** Packed 4-byte offsets, **watchlisted materials
only**, stored as per-sector files under an LRU byte budget.

Rejected: **coordinates for every block type.** A sector scan covers ~109,000
blocks; this is roughly 100× over the CC disk budget.

### 7.2 The scanner already sees everything

`ore_turtle.lua:717` calls `sc.scan(SCAN_RADIUS)`, which returns every block in
range with name and tags. `isOre()` at line 730 then discards everything that is
not ore. **Full-census survey is not a new sensor capability — it is removing a
filter and deciding what to keep.**

### 7.3 Staleness (P4)

- Entries are hints, never truth.
- `turtle.dig()` returning `false` detects a miss **for free** — no `inspect()`
  call needed.
- Past a configurable miss rate, the worker re-surveys in place.
- Every visit uploads a fresh authoritative scan.
- Every site carries a survey timestamp.

This policy is already designed for ore and generalises to logs and dirt
unchanged.

**Renewable resources regrow.** Ore is finite: a mined-out sector stays
mined-out. A replanted forestry site (§6.6) recovers, so its census must age
*upward*, not merely decay in confidence. A site must never be marked permanently
depleted on the strength of one post-harvest scan.

### 7.4 Storage constraint

Coordinates **never** enter `state.persistentZones`, **never** enter the `/state`
bridge payload, and are **never** held in server RAM in bulk.
`central_server.lua:2835` already records a scale failure with name→count data
alone; coordinates are two orders of magnitude larger.

---

## 8. Acquisition capability matrix (P3)

Every material resolves to exactly one method. The planner checks this **before**
the approval gate.

| Method | Source | Status |
|---|---|---|
| `RS_CRAFT` | Refined Storage resolves it, including machine chains | **Auto-detected live** via `listCraftableItems()` |
| `GEO_MINE` | Ore, coordinate-indexed | Built |
| `HARVEST` | Surface resources at indexed coordinates — logs, specific dirt. **Tree harvests carry a replant obligation** (§6.6) | Not built |
| `EXCAVATE` | Bulk region dig | Not built, optional |
| `HUMAN_SUPPLY` | The player | Flagged at plan time |

**The matrix largely maintains itself.** Because `RS_CRAFT` is detected from RS's
live craftable list, adding a machine chain in-world (cobblestone generator →
pulveriser → gravel → sand) makes those materials available with **no code
change**.

**Availability is a live fleet query, not a static table.** "Can we obtain this?"
resolves against currently registered worker capabilities (§6.4). If every
scanner-equipped worker is dead, surveying is unavailable and the approval
screen says so.

---

## 9. Project lifecycle

```
DRAFT → PLANNING → AWAITING_APPROVAL → GATHERING → STAGING → BUILDING → COMPLETE
                          ↓                 ↓
                      BLOCKED            FAILED
```

| State | What happens |
|---|---|
| `DRAFT` | Submitted, not yet planned |
| `PLANNING` | Resolve placement set → BOM → stock check → deficits → acquisition methods → feasibility → estimate |
| `AWAITING_APPROVAL` | Present the plan; wait. Skipped if the project's auto-approve flag is set |
| `GATHERING` | Emit `MINE`/`HARVEST` jobs and `RS_CRAFT` requests until stock satisfies the BOM |
| `STAGING` | `DELIVER` jobs move materials to a staging chest at the site |
| `BUILDING` | Builders consume the placement set by column |
| `BLOCKED` | Needs human-supplied material or an unavailable capability |
| `COMPLETE` / `FAILED` | Terminal |

### 9.1 Planning does all the work up front

This is what makes the approval gate meaningful. `PLANNING` resolves:

1. **Placement set** — from a blueprint *or* a generator. Same output either way.
2. **BOM** — aggregated counts, plus a configurable buffer for world drift and
   losses.
3. **RS stock** — what we already have.
4. **Deficit** — BOM minus stock.
5. **Acquisition method per deficit item** (§8).
6. **Feasibility** — anything `HUMAN_SUPPLY`, or any method with no capable
   worker alive.
7. **Estimate** — job count and rough duration.

### 9.2 The approval screen

Shows: total materials; what RS already holds; what will be mined and roughly
how many runs; what RS will craft; and — most importantly — **anything the fleet
cannot obtain.**

Rejected: **fully autonomous with no gate.** A bad plan running unsupervised
burns hours of fleet time and places thousands of wrong blocks; the gate costs
one click. The gate also maps cleanly onto future subaccounts — other players'
projects require approval, the owner's auto-approve.

Rejected: **a gate at every phase.** Once the plan is approved there is nothing
new to decide, and per-phase gates make overnight builds impossible.

---

## 10. Scheduling and arbitration

**One project at a time, FIFO.** A project runs to completion before the next
starts.

**But the fleet still runs fully parallel.** The planner emits job primitives
that the existing dispatcher spreads across every available worker — the whole
fleet pulls toward one goal rather than several.

**Stock-keeping thresholds fill idle capacity** in the background rather than
waiting for a completely empty queue. The existing ore demand watchdog
(`central_server.lua:2135`) is the ancestor of this and is **outdated** — it must
be brought under this model rather than left as a parallel mechanism.

Rejected: **fleet partitioning / static reservations.** A project's fleet needs
change by phase — during mining the delivery turtles idle, during staging the
miners do. Static reservation guarantees idle workers in every phase, directly
violating P2.

Rejected: **priority preemption.** Pausing a build cleanly is hard and risks
several half-built structures. A `priority` field ships now (§15) so this can be
added later without migration.

---

## 11. Message contracts

These are the integration points. **They are specified here so two workstreams
can build against each other before either exists.** Shapes may be refined by
agreement; they may not be diverged from silently (P6).

### 11.1 Intent ↔ Planning

| Message | Direction | Payload |
|---|---|---|
| `PROJECT_SUBMIT` | bridge → planner | `{ projectId, kind, owner, priority, placementSetRef | goalSpec, autoApprove }` |
| `PROJECT_PLAN` | planner → bridge | `{ projectId, bom, stock, deficits[], methods{}, blockers[], estimate }` |
| `PROJECT_APPROVE` | bridge → planner | `{ projectId, owner }` |
| `PROJECT_CANCEL` | bridge → planner | `{ projectId, owner, reason }` |
| `PROJECT_STATUS` | planner → bridge | `{ projectId, state, progress, currentPhase }` |

### 11.2 Planning ↔ Dispatch

The planner **requests** jobs; the server owns assignment. The planner never
talks to a worker directly.

| Message | Direction | Payload |
|---|---|---|
| `JOB_SUBMIT` | planner → server | `{ jobId, projectId, kind, params, owner, priority }` |
| `JOB_RESULT` | server → planner | `{ jobId, projectId, ok, yield{}, reason }` |
| `RESOURCE_QUERY` | planner → server | `{ material, quantity }` |
| `RESOURCE_RESULT` | server → planner | `{ material, sites[], totalKnown, staleness }` |
| `CAPABILITY_QUERY` | planner → server | `{ methods[] }` |
| `CAPABILITY_RESULT` | server → planner | `{ method → availableWorkerCount }` |

### 11.3 Survey and index

Extends the existing `SECTOR_*` family rather than replacing it.

| Message | Direction | Payload |
|---|---|---|
| `SURVEY_ASSIGN` | server → worker | `{ jobId, site, sector, watchlist[] }` |
| `SURVEY_DONE` | worker → server | `{ jobId, sector, census{}, packedIndex, ts }` |

### 11.4 Build

**Builder-class-agnostic.** This contract holds whether the builder is an
Android or a turtle (Probe C), and it assumes builders die (P5).

| Message | Direction | Payload |
|---|---|---|
| `COLUMN_REQUEST` | builder → server | `{ jobId, projectId }` |
| `COLUMN_ASSIGN` | server → builder | `{ jobId, columnId, blocks[] }` |
| `COLUMN_DONE` | builder → server | `{ jobId, columnId, placed, failed[] }` |

**Columns are reassignable.** Progress is recorded server-side; no state lives
only on the builder. A builder that dies, unloads with its chunk, or reboots
mid-column has that column reassigned — exactly as the mining sector handshake
handles a dead miner.

### 11.5 Registration

`REGISTER` gains a `capabilities` array (§15). The server matches jobs to
capabilities, not to role names.

### 11.6 Placement set format

The universal build input. Produced by blueprint conversion *or* by a generator;
consumed by the build pipeline, which never knows which.

```lua
{
  v         = 1,
  projectId = "...",
  origin    = { x, y, z },     -- absolute world anchor
  bbox      = { min = {x,y,z}, max = {x,y,z} },
  blocks    = {                 -- offsets from origin
    { dx, dy, dz, id, state },  -- state = facing/half/etc., may be nil
  },
}
```

The **bounding box is computed at parse time** — the parser walks every block
anyway — and drives the static loader blanket (§12.4).

---

## 12. Standing invariants

Lifted from the solo-miner plan and the Android feasibility study, promoted to
system-wide rules because they apply to every field worker.

**A — Chunk safety.** A worker must never be outside the base-loaded area with
neither its own chunky equipped nor a placed loader within footprint. Any code
path that could violate this is a defect regardless of how unlikely.

**B — Modem recoverability.** A worker must be able to recover a missing modem on
boot from its own inventory. A reboot inside the swap window must not brick it.

**C — Geofence.** While the pickaxe is equipped, the worker must not move outside
the guaranteed-loaded footprint. **Enforced at the movement primitive, not at
call sites.**

**D — No abandoned loaders.** A placed loader must always be recoverable.
Placement is persisted to disk before placing and cleared only after confirmed
retrieval, so a crash at any instant errs toward "we may have one out there."
An abandoned loader is a lost worker plus a permanently force-loaded chunk.

**E — Server independence.** A worker must be able to retrieve its loader and
reach its dock with **no server contact at all**. A server outage may pause work;
it must never strand a worker in the field.

**F — Reassignable work (P5).** No task may depend on the worker surviving it.

**G — ACK on every worker↔worker signal.** Any new worker-to-worker message ships
with an ACK loop. `parallel.waitForAny` shares one OS event queue between
coroutines; direct `proto.receive` calls in a multi-loop program silently steal
events. Use `base.receive` (the shared inbox), never `proto.receive`.

**H — `delivery_turtle.lua` is frozen.** Standing constraint. Delivery behaviour
does not change as a side effect of other work.

### 12.1 Build sites use a static loader blanket

A build site does not move, and its footprint is known before the first block is
placed. So builders work inside a **pre-placed static loader volume** — one
loader covers 80×80 blocks, so most builds need exactly one. Loaders go down at
build start and come up at build end.

This is **less** infrastructure than mining, not more: none of `equipment.lua`'s
swap choreography is needed, and the geofence becomes a static bounding-box check
instead of a moving fence. It is also **role-agnostic** — a builder turtle far
from base has the same problem — so it is not a cost attributable to the Android
decision.

---

## 13. File ownership

One engineer per file. Coordinate before crossing a boundary.

| Area | Files | Note |
|---|---|---|
| Shared protocol | `protocol.lua` | Coordinate before editing; version bump required |
| Dispatch | `central_server.lua` | At scale limits — new logic goes elsewhere by default |
| Planning | `planner.lua` | New |
| Storage | `warehouse.lua` | |
| Worker runtime | `turtle_base.lua`, `equipment.lua`, `geofence.lua`, `loader_state.lua` | |
| Mining execution | `ore_turtle.lua`, `mine_flow.lua` | |
| Delivery | `delivery_turtle.lua`, `support_turtle.lua` | **Frozen** (Invariant H) |
| Resource index | `oreindex.lua`, `oreindex_store.lua` | New. Pure functions, fully testable |
| Android runtime | `android_base.lua` | |
| Bridge & dashboard | `server.js`, `public/` | Never load-bearing |

### 13.1 Push protocol

1. Make code changes.
2. Bump `proto.VERSION` in `protocol.lua`.
3. Commit both together and push.
4. State exactly which computers/turtles need `install <role>` + reboot.

**Never trigger `/self-update` or `UPDATE_ALL` without asking first** — it
restarts all turtles and interrupts active miners.

### 13.2 Verification discipline

There is **no Lua runtime for the live fleet on the development machine.**
Nothing may be claimed verified without the headless harness or an in-world test.

New tests are **mutation-tested** — break the code beneath the assertion and
confirm the test fails. Seven existing tests have already proven unable to fail
against the defect they were written for.

---

## 14. Engineer workstreams

Five streams. Each depends on **contracts in §11**, not on another stream's code
— that is what makes real parallelism possible.

### W1 — Resource Intelligence

**Mission:** Know what the world has and where.
**Owns:** `oreindex.lua`, `oreindex_store.lua`, scan paths in `ore_turtle.lua`
and `mine_flow.lua`.
**Depends on:** nothing.
**Must not touch:** `central_server.lua` beyond thin wiring; `delivery_turtle.lua`.
**First deliverable:** ore coordinate index (already specced), then the census
tier and `SURVEY_ASSIGN`/`SURVEY_DONE`.

### W2 — Planner

**Mission:** Turn a request into a plan and then into jobs.
**Owns:** `planner.lua`.
**Depends on:** §11.1, §11.2 contracts. W1's census by contract only.
**Must not touch:** `central_server.lua`; anything worker-side.
**First deliverable:** planner computer with BOM, RS stock check, deficit
calculation, and the approval screen.

### W3 — Fleet & Dispatch

**Mission:** Capability-based dispatch and worker consolidation.
**Owns:** `central_server.lua`, `turtle_base.lua`, `equipment.lua`.
**Depends on:** nothing.
**Must not touch:** `delivery_turtle.lua` (Invariant H).
**First deliverable:** `capabilities` on `REGISTER`; `owner` and `priority`
fields; capability-matched assignment.

### W4 — Construction

**Mission:** Turn a placement set into a built structure.
**Owns:** `android_base.lua`, new builder module.
**Depends on:** §11.4 and §11.6 contracts; W3 capabilities.
**Blocked on:** **Probe C** — do not write the BUILDER role until the builder
class is decided.
**First deliverable:** run Probe C, since it gates everything else in this
stream. The column protocol (§11.4) is builder-agnostic, so it can be specified
in parallel while the probe is outstanding — but not implemented against a
specific builder class until the probe resolves.
**Also owns two known defects** in `android_base.lua`: the refuel mechanism
(`android_base.lua:63` uses `swapHands` instead of `equipSlot`/`storeItem`), and
the latent parallel-inbox bug — the Android needs the `base.receive` inbox split
**before** any builder role lands, not after.

### W5 — Bridge, Dashboard & Generators

**Mission:** How humans talk to the system.
**Owns:** `server.js`, `public/`.
**Depends on:** §11.1 contract.
**Blocked on:** **Probe C** for the `.litematic` parser — its output is shaped by
which block states the chosen builder can reach.
**First deliverable:** bridge auto-start as a service; the placement-set format
(§11.6); dashboard project submission and approval UI. Then the road generator,
then the parser once Probe C resolves.

### 14.1 Coordination rules

- One engineer per file.
- `protocol.lua` changes are **announced** and version-bumped.
- Every cross-stream integration point is defined as a message contract in §11
  **first**.
- If your design contradicts this document, raise it. Do not diverge silently.

---

## 15. Required-now hooks

Four things that cost nothing today and are painful retrofits later.

| Hook | Why now |
|---|---|
| **`owner` on every job and project** | Currently **nonexistent** anywhere in `central_server.lua` or `protocol.lua`. Adding it after permissions, quotas, and audit history exist means touching every job path at once. |
| **`priority` on projects** | Lets preemption or partitioning be added later with no migration. |
| **`capabilities[]` on registration** | The foundation of P2 and of the §8 availability query. |
| **Placement set as the sole build input** | Stops blueprints and generators forking the build pipeline into two code paths. |

---

## 16. Roadmap

Each phase unblocks the next. Nothing is parallel-blocked on a phase above it
once §11 contracts are fixed.

| Phase | Work | Unblocks |
|---|---|---|
| **0 — now** | Finish mining consolidation; ore coordinate index | The index pattern everything copies |
| **1** | Resource index generalisation: census tier, survey job, non-ore classes | Knowing what the world has |
| **2** | `planner` computer: project lifecycle, BOM, stock check, approval | The whole autonomous loop |
| **3** | Build execution: placement sets, column protocol, staging | Actually building things |
| **4** | Worker consolidation; harvest workers | One worker type (P2) |
| **5** | Road generator + Dynmap drawing | Parametric builds |
| **6** | Auth, subaccounts, quotas, permissions | Other people |

---

## 17. Open verification items

Unresolved questions that shape design. **Nothing that depends on these may be
built on an assumption about their answer.**

| # | Question | Blocks |
|---|---|---|
| **V1 / Probe C** | What block states can a *turtle* actually place, versus an Android's `useBlock`? | The builder class. Highest decision weight of any open item. **Run first.** |
| **V2 / Probe A** | Can an Android hold and place a loader turtle? Does `chunk_controller` fit a pocket slot? | Whether builds need a turtle bootstrap step |
| **V3 / Probe B** | Does a static loader blanket keep an Android ticking across distance? | §12.4 |
| **V4** | Does this modpack require an axe/shovel for the **drops** we want, or does a diamond pickaxe suffice? Speed is settled and is not part of this question (§6.5). Test: dig a modded log with a pickaxe turtle, check the inventory. | Whether extra tool slots are worth their cost (§6.5) |
| **V5 / Probe D** | Android failure modes: chunk unload, death, inventory, clean reboot and re-register | Whether unattended overnight builds are realistic |
| **V6** | Single modem message ceiling — an unfiltered ~8 KB assign payload is the largest thing on the wire | Whether chunked transfer is needed |
| **V7** | Can a turtle equip **shears** as an upgrade in this pack? CC:Tweaked ships upgrades for the diamond tools; shears may need a datapack. | Only whether leaf **blocks** are obtainable as a material. Sustainable forestry does **not** depend on this (§6.5) |

---

## 18. Deferred decisions

Recorded with their trigger conditions so they are re-opened deliberately, not
rediscovered.

**Delivery pairing.** Delivery keeps the support pair for now. **Pairing is a
consequence of underground transit, not of delivery** — a digging turtle cannot
hold its own chunk loader. The real question is therefore *"should delivery
fly?"* If delivery moves to air transit, that reason evaporates and delivery
becomes structurally identical to mining: self-loading transit, no partner.
**Trigger:** any serious proposal to move delivery to air.

**Dual state tracking.** The server mirrors every worker's runtime state, and the
two diverge after a crash; ~250 lines exist to re-sync the mirror. **Fix path:**
workers become authoritative state reporters, sending a full snapshot on
re-registration. **Deferred** because it is effectively a server rewrite.
**Trigger:** the next time a crash-recovery bug is traced to mirror divergence.

**Two-state-machine coordination.** The message-loss half is fixed (shared
inbox + `sendReliable`). The remaining half — miner and support running
independent state machines with four separate return paths — is open.
**Deferred** pending observation of real recalls. **Trigger:** delivery
consolidation, which removes the last pair, may retire this entirely.

**Fleet partitioning and priority preemption.** See §10. **Trigger:** sustained
contention where FIFO demonstrably wastes fleet time.

---

## 19. Related documents

| Document | Relationship |
|---|---|
| `2026-08-18-ore-coordinate-index-design.md` | Implementation of §7, Tier 2 |
| `2026-08-18-android-chunkloading-feasibility.md` | Source of §12.4, §14 W4, and V1–V3, V5 |
| `chunkloader-footprint.md` | Verified chunk-loading measurements behind §6.2 |
| `2026-08-13-solo-miner-carried-chunkloader.md` | Source of §12 invariants A–E |
| `2026-06-11-mining-robustness-design.md` | Prior mining hardening |
| `2026-06-04-codebase-audit-report.md` | Known defects and debt |

---

## 20. Out of scope

This document does **not** design: the internals of any single subsystem; the
`.litematic` parser; the road generator's geometry; the authentication scheme;
or the excavation job type. Each gets its own spec, conforming to the contracts
here.
