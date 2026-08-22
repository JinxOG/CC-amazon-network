# Exclusive sector leases — one miner, one volume, enforced

- **Date:** 2026-08-22
- **Author:** W1 — Resource Intelligence, from the operator's proposal
- **Primary implementer:** **W3 — Fleet & Dispatch.** Most of this lands in W3's files
- **Status:** Design approved by the operator; implementation plan not yet written
- **Protocol version at time of writing:** 1.9.37

---

## 1. Why

On 2026-08-22 `node_139` returned to its dock carrying `node_119` — a miner — as
an item. One turtle mined another. The evidence (fuel burn ~18k against a
completed job's 38k, and a loader never retrieved) puts it **in the mining zone**,
not at the depot.

The operator's diagnosis: *multiple turtles doing multiple jobs intersecting with
each other*. This design is that proposal.

Two defences are needed and neither replaces the other:

| | Purpose |
|---|---|
| **Dig guard** (`turtle_base`, W3, outstanding) | Makes a collision **non-fatal**. The floor. |
| **Sector leases** (this document) | Makes a collision **structurally impossible** in the working volume. |

A guard alone means turtles keep meeting and keep relying on a check to not kill
each other. A lease alone means one missed case is still fatal. Ship both.

## 2. What already works

**Assignment is already exclusive.** `nextSector` pops from `zone.pending`
(`central_server.lua:1363`), so two miners never hold the same sector. Nothing in
this design changes how sectors are chosen.

**What is missing is enforcement.** The geofence is chunk-based at radius 1 —
**48 blocks** — while `SECTOR_STEP` is **32**. Adjacent leaseholders' fences
overlap by 16 blocks on every shared edge. The lease is real; the wall is the
wrong size and in the wrong units.

## 3. The lease

A sector assignment becomes a **lease**: a rectangle one miner is confined to and
no other worker may enter.

### 3.1 Footprint — half-open, and why

**32 × 32 blocks, `[sx−16, sx+15]`.**

`SECTOR_STEP` is 32 but the geo scanner reads radius 16, which is **33 blocks
wide**. Sector 1120 covers x 1104–1136; sector 1152 covers x 1136–1168. They
share the column at **x = 1136**. The comment at `central_server.lua:1093` states
adjacent sectors do not overlap; it is off by one block on every shared edge.

Harmless while fences are 48 wide and overlap anyway. Not harmless when
exclusivity is the point — two leaseholders could both legitimately stand on that
column.

> **Scans may overlap. Leases must tile.** The scan still reads 33 wide; the lease
> is the half-open 32. These are different things and only one of them is a
> promise.

### 3.2 Volume — exclusive below, shared above

Bedrock up to a **ceiling**, exclusive. Above the ceiling is shared transit.

Rejected: **the full column, bedrock to sky.** A zone is 15 sectors and the sky
lane from the depot crosses other sectors. With the fence enforced at the movement
primitive (Invariant C) a miner would physically refuse to overfly a neighbour,
and four miners on a 15-sector zone would deadlock on the way home.

The ceiling sits above the survey travel altitude and below the sky lane. It must
be derived from the same constants as `SURVEY_TRAVEL_Y` and `SKY_Y` rather than
hard-coded, because both already shift per miner by `travelYOffset`.

**Known gap, accepted:** a miner ascending or descending inside its own column is
in shared airspace above the ceiling. The dig guard is the backstop there.

### 3.3 Chunk-loading safety — this is a pure narrowing

Sectors sit on multiples of 32, so `sx/16` is even and a lease spans exactly
**two chunks per axis**, both within ±1 chunk of the sector's centre chunk. That
is strictly inside the loader's 3×3 footprint.

**The tighter fence is never outside loaded chunks.** No trade against Invariant A;
the lease is a subset of what the loader already holds. `placeLoader` already
refuses a loader that cannot cover its sector (`loader_target_wrong_chunk`), so
the covering relationship is enforced before the lease is armed.

## 4. Mechanism

1. **`SECTOR_ASSIGN` carries the lease** — `x1, z1, x2, z2, ceilingY` alongside
   the existing `sectorX/sectorZ`. Shared protocol change, version bump.
2. **The miner fences to the lease**, not to its loader's chunk. This replaces the
   `setAnchorBlock(tx, tz, chunkRadius)` call in `placeLoader`.
3. **The server holds the lease** for as long as the assignment stands, and
   returns it to `zone.pending` when released.

### 4.1 Release

| Trigger | Action |
|---|---|
| Sector completed (`SECTOR_DONE`) | Release, assign next |
| Job failed / recalled | Release |
| **Holder dies or goes absent** | **Release back to the pool** |

The absent case already exists: `checkStuckJobs` Case 3 re-queues a job whose
turtle has been offline past the grace window. It is currently starved by the
stale-IDLE guard (`2026-08-22-W1-to-W3-idle-heartbeat-guard-starves-job-recovery.md`)
— **that fix is a prerequisite for this one**, or leases from dead miners are
never reclaimed.

### 4.2 Orphan loaders in a reclaimed sector

A dead miner's loader is still standing in the sector the pool just handed to
someone else. `node_160` is exactly this.

**The new holder works around it and reports it. It never retrieves it.**

- Treated as a **no-dig obstacle** for the duration of the lease.
- Reported once as `orphan_loader at x,y,z`.
- Collected by an operator or a future dedicated recovery job — not by a miner
  mid-sector.

Rejected: **the new holder retrieves it.** It is inside their exclusive fence and
nobody else can, which is a real argument. But a miner already carries its own
loader, and while `equipment.LOADER_PREFIX` is unconfigured it **cannot tell the
two apart** — `loader_state` would track one turtle while the inventory held two
identical items. That is the defect of
`2026-08-22-W1-to-W3-a-dug-up-miner-is-indistinguishable-from-a-loader.md`, walked
into deliberately. Revisit once loaders are labelled.

**Cost, accepted:** orphaned loaders accumulate until something collects them.
They are at least visible and inside a leased sector, which is better than today,
where nothing knows they exist.

## 5. What must change, and who owns it

| Change | File | Owner |
|---|---|---|
| Block-rectangle fence mode; **Y ceiling** | `geofence.lua` | **W3** |
| Fence vertical moves — currently only forward/back are fenced | `turtle_base.lua` | **W3** |
| Lease bounds on `SECTOR_ASSIGN` | `protocol.lua` | shared |
| Issue, hold, release, reclaim leases | `central_server.lua` | **W3** |
| Arm the fence from the lease; orphan-loader handling | `ore_turtle.lua`, `mine_flow.lua` | **W1** |

**The majority is W3's.** W1 cannot enforce the lease in its own files without
violating Invariant C, which puts fence enforcement at the movement primitive.
W1's slice is inert until the primitives exist.

### 5.1 The two primitives that do not exist yet

**`geofence.contains(x, z)` has no Y.** The fence is a chunk-space Chebyshev test
and nothing more. A ceiling is a new concept in that module.

**Vertical movement is not fenced at all.** `tryMove` only consults
`fenceBlocksStep` for `forward`/`back` (`turtle_base.lua:600`). `move.up` and
`move.down` are unfenced today, so a ceiling would have no effect until they are.

Both are W3 decisions about their own module's shape, and W1 has deliberately not
specified an API for them.

## 6. What this does and does not fix

**Does:** two miners can never occupy the same working volume. The in-field
collision that destroyed `node_119` becomes structurally impossible rather than
improbable.

**Does not:**

- **Transit.** Miners still share the sky lane between depot and zone.
- **The depot.** They still queue in the single-block arrivals hole (Invariant I).
- **Support and delivery turtles.** Leases are miner-only. Delivery is frozen
  under Invariant H and is not in scope.

The dig guard covers what leases do not. Neither is sufficient alone.

## 7. Accepted costs

- **Veins crossing a lease boundary are cut.** A 32-block fence cuts more of them
  than a 48-block one. The ore is not lost — it is recovered when the neighbouring
  sector is leased. Deliberate: a clean boundary is worth more than a whole vein.
- **Orphan loaders accumulate** until collected (§4.2).
- **Ascent/descent above the ceiling is unprotected** (§3.2).

## 8. Prerequisites

1. **The stale-IDLE guard fix.** Without it a dead miner's lease is never
   reclaimed, and §4.1's core promise does not hold.
2. **The dig guard.** Not strictly required, but shipping leases first would
   invite the belief that the collision problem is solved.

## 9. Open questions

- **What exactly is the ceiling?** It must derive from `SURVEY_TRAVEL_Y` and
  `SKY_Y`, both of which shift by `travelYOffset` per miner. If two miners'
  offsets put one's ceiling inside another's working volume, the guarantee breaks.
  W1 believes this is the same latent altitude-slot collision already noted
  against `travelYOffset` and should be resolved with it, not separately.
- **Does the server need to verify a lease, or is the turtle-side fence enough?**
  The fence is fail-closed and armed from a server-issued value, so W1's view is
  that it is enough. Raised so it is decided rather than assumed.
- **Do leases need to survive a server restart?** They are derived from
  `zone.pending`, which is persisted — but persistence is currently failing on a
  full disk (`2026-08-22-W1-to-W3-savejobs-destroys-its-own-backup-on-a-full-disk.md`).
