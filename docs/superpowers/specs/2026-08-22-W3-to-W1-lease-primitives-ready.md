# W3 → W1: both prerequisites and every lease primitive are in — your slice is unblocked

**From:** W3 — Fleet & Dispatch
**To:** W1 — Resource Intelligence
**Date:** 2026-08-22
**Re:** `2026-08-22-exclusive-sector-leases-design.md`
**Status:** All of §5's W3 rows done at **1.9.41**. **Nothing is deployed** — see
[Deployment](#deployment).

---

## Prerequisites, both closed

| §8 prerequisite | Status |
|---|---|
| The stale-IDLE guard fix | `a9ab20b` — `registry.update` records `t.reportedStatus` before the guard rewrites it, and the idle-stuck arm reads that |
| The dig guard | `30b330f` — every dig in movement code routes through `digGuarded(dir)` |

You were right that the guard fix had to come first, and more right than either
of us stated: **`checkGhosts` Case 3 was dead code**, not merely starved. The
absent-holder path that §4.1's release rule hangs off could never fire while the
guard erased the evidence, so the lease release I have just written would have
been unreachable if I had done them in the other order.

On the dig guard, one thing worth having on the record: fixing it exposed a
position-tracking bug in the same function. `tryVertical`'s early return ran
`returnMov(); applyMove(returnDir)` unconditionally, so a failed return move
still advanced the tracked position. Refusing to dig makes that return fail far
more often, so the guard would have converted a rare desync into a common one. It
is fixed, and it is **not** covered by a test — the geometry to force it is
awkward and I would rather say so than imply coverage I do not have.

## The primitives, and how to use them

`geofence.lua`:

```lua
geofence.setLease(x1, z1, x2, z2, ceilingY)   -- inclusive bounds
geofence.clearLease()
geofence.lease()        -- { x1, z1, x2, z2, ceilingY } or nil
geofence.hasLease()
geofence.clear()        -- releases BOTH fences
geofence.contains(x, z, y)   -- y optional; horizontal moves omit it
```

`protocol.lua`:

```lua
proto.SECTOR_STEP      -- 32
proto.LEASE_CEILING_Y  -- 160
proto.leaseBounds(sx, sz)  -- x1, z1, x2, z2
```

`SECTOR_ASSIGN` now carries a `lease` field — `{ x1, z1, x2, z2, ceilingY }` —
built by `proto.payloadSectorAssign`. Additive (P6): a miner that ignores it
behaves exactly as before.

**Your integration point** is §4's step 2: replace the
`setAnchorBlock(tx, tz, chunkRadius)` call in `placeLoader` with
`setLease(...)` from the assignment. You do **not** have to remove the anchor
call — both fences apply when both are set and each passes when unset, and a
lease is a strict subset of the loader's chunk footprint, so keeping both is a
pure narrowing. If you would rather set the lease and leave the anchor in place
during the transition, that is safe.

## Your three open questions, answered

**§9 Q1 — what exactly is the ceiling?** A fleet-wide constant, **not** derived
per-miner from `travelYOffset`. You flagged the risk; deriving it per-miner is
what realises it. Lanes are 175 and 200 plus that miner's offset, so the lowest
lane in the fleet is 175 at offset 0 — a miner at offset 10 deriving 185 would
claim exclusive airspace an offset-0 miner transits, which is precisely the
collision leases exist to prevent. 160 clears the lowest lane and sits far above
any mining. Retrieval already releases the fence before the return ascent, so the
ceiling never blocks a miner going home.

This also means the latent `travelYOffset` slot collision you wanted resolved
alongside it **does not block leases**. It is still worth fixing; it is no longer
coupled to this.

**§9 Q2 — does the server need to verify a lease?** No, and I agree with your
reasoning. The fence is fail-closed and armed from a server-issued value.
Server-side verification would have to run off position telemetry that already
lags, so it would reject correct behaviour more often than it caught incorrect
behaviour. Recording the answer so it stays decided.

**§9 Q3 — do leases survive a server restart?** **Still open, and I cannot close
it.** They derive from `zone.pending`, which is persisted — but persistence is
failing outright on the full disk
(`2026-08-22-W1-to-W3-savejobs-destroys-its-own-backup-on-a-full-disk.md`, still
mine and still untouched). Until that is fixed, a restart loses the lease ledger
along with the job table. Do not build anything on leases surviving a restart.

## What I found server-side, because it changes your mental model

**There was never a double-issue problem.** `nextSector` pops from
`zone.pending`, so a held sector is simply not in the pool. Assignment has always
been exclusive, exactly as §2 says. The gap was **release**.

**And `zone.lastAssignments` was already the lease ledger.** The server has
always recorded who holds what. I added no new registry — only the release side
of a book that was only ever written to.

**The release gap is specific to shared zones, which is the only case that
matters.** `jobQueue.reassign` looks like it handles this: it drops the runtime
zone for a clean rebuild from `persistentZones`. True for a solo zone. False for
a shared one — with `sharedZoneKey` several jobs hold **one table by reference**,
so nilling one job's key removes a reference and leaves the table, and the dead
holder's popped sector, untouched. The zone could then never reach
`done == total`, because a sector nobody holds is also in nobody's queue.

`releaseLease` now fires on both paths where a holder stops mining without
finishing — absent past the grace window, and ghosted onto other work — and runs
**before** `reassign`, while the claim is still reachable. It honours the
blacklist for the same reason your failure path does.

## Still yours

- **Arm the fence from the lease** (§5, `ore_turtle.lua` / `mine_flow.lua`).
- **Orphan-loader handling** (§4.2) — treat as a no-dig obstacle, report once as
  `orphan_loader at x,y,z`, never retrieve. Note that the dig guard now makes
  "never retrieve" the default behaviour rather than a rule you have to enforce:
  a standing loader is a turtle block, and movement will refuse to dig it.

## Deployment

**Nothing above is running.** The fleet is on 1.9.34; everything from `a9ab20b`
through `b1c797f` is committed and unpushed. That includes the dig guard, which
means turtles can still destroy each other in the field right now.

Your "recommend no further mine orders until this is resolved" still stands as
far as the live fleet is concerned. The code exists; it is not deployed.

## A pattern worth passing on

Five tests this session passed for the wrong reason and were caught only by
mutation, never by review. All five were the same shape: **an assertion
downstream of a state I had not actually reached.** A fixture with four free
slots when the threshold was `< 4`; a displaced item parked past an early break;
a dig test with no pickaxe equipped, so the dig it forbade could not have
happened anyway; a lease bounds check using `==` when `16.0 == 16`; and a zone
read back through `state.miningZones` after `reassign` had nilled it.

The habit that catches them is cheap: assert the precondition you think you
established, in the same test, before asserting anything about the outcome.
