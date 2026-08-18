# Ore Coordinate Index — Design

**Date:** 2026-08-18
**Status:** Approved (design); implementation plan not yet written
**Protocol version at time of writing:** 1.9.7

## Problem

The geo scanner returns exact block coordinates, and `scanSector()` in `ore_turtle.lua`
already converts them to absolute world positions:

```lua
{ name = b.name, x = p.x + b.x, y = (p.y - 1) + b.y, z = p.z + b.z }
```

Those coordinates are then collapsed to a name→count table
(`scanFound[o.name] = (scanFound[o.name] or 0) + 1`) and only the counts are
transmitted, because `proto.payloadSectorScan` carries `foundOres` as
`{[name] = count}`. **The coordinates never leave the turtle.**

Consequence: every miner sent to an already-surveyed sector re-runs the full
four-level geo scan on arrival, and re-walks ground a previous miner already
cleared.

## Goal

Two wins, both stated by the user:

1. **Speed** — fly straight to known ore instead of re-scanning on arrival.
2. **No re-scanning** — a second visit to a surveyed sector reuses the previous
   scan rather than repeating it.

Explicitly **not** goals (considered and declined):

- Global "where are the nearest 50 iron" queries across all zones.
- Exact-quantity requests ("mine exactly 50 and stop").

Those would require a queryable in-RAM index; see *Rejected Approaches*.

## What already exists

Sector-granularity targeting is already built and must keep working unchanged:

| Capability | Location |
|---|---|
| Per-sector ore counts, persisted | `central_server.lua:557` — `pz.sectorOreMap[sx..","..sz]` |
| Targeted mine (only sectors holding a requested ore) | `central_server.lua:1064` — `ensureMineZone` |
| Ore demand watchdog (auto-dispatch on low stock) | `central_server.lua:2135` |
| Dashboard-triggered targeted mine | `central_server.lua:2622` |

This design adds block-level precision **underneath** that machinery. It does not
replace it. `sectorOreMap` remains the index used for sector selection.

## Known scale constraint

`central_server.lua:2835` already records a scale failure with name→count data:

> `sectorOreMap` excluded: per-sector maps grow to thousands of entries across
> historical zones and block the event loop when serialised every few seconds.

Coordinates are ~2 orders of magnitude more data than counts. Additionally,
`savePersistentZones()` re-serialises the **entire** zone table on every sector
completion. Therefore: **coordinates must never enter `state.persistentZones`,
never enter the `/state` bridge payload, and never be held in server RAM in
bulk.** This constraint drives the whole design.

## Sizing

A sector spans 33×33 in X/Z (`SCAN_RADIUS = 16`) and Y from −68 to +32
(`SCAN_LEVELS = {16, 0, -32, -52}`, each ±16) — about 109,000 blocks. At
observed densities that is roughly **1,000–3,000 ore blocks per sector**
(one sector reported 261 uranium as a single ore type).

| Encoding | Per sector |
|---|---|
| Naive `{name=…,x=…,y=…,z=…}` via `textutils.serialise` | ~60 B/ore → **60–180 KB** |
| Packed offsets grouped by ore name | ~4 B/ore → **~8–12 KB** |

CC:Tweaked's default `computer_space_limit` is 1 MB. That ceiling is shared with
the server's own programs, `zones.dat` and its backup, so the index budget must
be a configured fraction of it rather than the whole disk — on the order of
**60–80 sectors** at a 512–640 KB budget. The naive form would fit under 10, and
is the reason packing is load-bearing rather than an optimisation.

## Architecture

### New modules

**`oreindex.lua`** — shared, deployed to both the server and miner profiles
(like `protocol.lua`). Owns the packed encoding and nothing else:

- `oreindex.pack(ores, origin) -> string`
- `oreindex.unpack(str, origin) -> ores`
- `oreindex.filter(idx, oreNames) -> idx`

Pure functions. No I/O, no peripherals, no globals — fully testable under the
existing headless harness.

**`oreindex_store.lua`** — server-side only. Per-sector file I/O:

- `store.read(zoneKey, sx, sz) -> str|nil`
- `store.write(zoneKey, sx, sz, str)`
- `store.evict(budgetBytes)`

Kept separate from the codec so the codec stays pure and the storage backend can
change without touching the encoding.

This split is deliberate: `central_server.lua` executes its main loop at load
time and cannot be `require`d under the test harness, so all logic with edge
cases lives in these two modules, leaving only thin wiring untested inside the
server.

### Encoding format

Offsets from the sector origin: `dx` and `dz` each need 6 bits (0–32), `dy`
needs 7 bits (0–100) — **19 bits per ore, written as 4 characters** from a
64-character printable alphabet. Ores are grouped under their block name so the
name is stored once per sector rather than once per ore:

```lua
{
  v   = 1,               -- format version
  ox  = 512, oy = -68, oz = -1024,   -- sector origin (absolute)
  ts  = 1755400000000,   -- epoch ms of the scan
  ore = {
    ["minecraft:deepslate_iron_ore"] = "Bf3aCg7bDh2c…",
  },
}
```

Printable characters rather than raw bytes so `textutils.serialise` stays safe
and files remain debuggable by hand.

### File layout

```
oreidx/<sanitisedZoneKey>/<sx>_<sz>.idx
```

`computeZoneKey` produces `"%d,%d,%d,%d"`; commas are replaced with underscores
for the directory name.

## Data flow

### Survey

1. Miner scans its four levels as today and dedupes by absolute coordinate
   (`seenOres[x..","..y..","..z]` — already implemented).
2. Miner packs the deduped list and sends the string on `SECTOR_SCAN`.
3. Server writes `oreidx/<zoneKey>/<sx>_<sz>.idx`.
4. `sectorOreMap` name→count is written exactly as it is today. Targeted mining
   and the demand watchdog are untouched.

### Mine

1. On `SECTOR_ASSIGN`, the server reads that single sector file, filters it to
   the job's `oreFilter` (if any), and attaches the packed list to the message.
2. Miner unpacks into a `"x,y,z"`-keyed set and **skips the arrival geo scan
   entirely**. (The exit post-scan below still runs — it is what keeps the
   index fresh.)
3. Miner works its existing nearest-first loop (`ore_turtle.lua:741`), which
   already sorts `remaining` by Manhattan distance and pops one at a time.
4. **Every successful dig clears its coordinate from the set**, computed from
   the turtle's own position and dig direction.

### Post-scan (authoritative refresh)

After `DUMPING` and **before** `SWAP_TO_CHUNKY`/`RETRIEVING` — the chunk loader
must still be placed and the chunk still loaded:

1. Move to the sector's scan column.
2. Ascend toward `SURVEY_TRAVEL_Y = 175`, stopping at each of the four scan
   levels in ascending order — Y = −52, −32, 0, 16 — to place the scanner,
   scan, and pick it up.
3. Upload the fresh packed index; the server overwrites the sector file.
4. Retrieve the loader and return home.

The marginal cost is four scans plus one lateral move: the miner must make that
vertical trip anyway, and all four scan levels lie below the travel altitude.

The post-scan is authoritative — it captures incidental ore, third-party changes
by other players or creepers, and anything a bookkeeping bug missed.

## Consumption tracking

Dig-keyed pruning is retained alongside the post-scan, serving two purposes the
post-scan cannot:

1. **Live route pruning** — don't fly to an ore already broken in passing.
2. **Correct mined counts.** Today `byType[ore.name] = … + 1` at
   `ore_turtle.lua:757` fires *only* when a targeted ore is reached, so ore
   broken incidentally en route is collected into the ender chest but never
   counted. `oreMined` therefore under-reports today. Because a dug coordinate
   that is present in the index carries its block name **in the index**, the
   miner can count incidental ore correctly with one table lookup per dig and
   **no `turtle.inspect()` call** — zero extra game ticks. This fixes the
   existing under-count as a side effect.

Diffing the pre-scan against the post-scan yields the same information
independently, and serves as a cross-check.

## Error handling

**Every index failure degrades to "scan on arrival."** Nothing in this feature
may fail a job.

| Failure | Behaviour |
|---|---|
| Missing file | `SECTOR_ASSIGN` carries no ore list; miner scans as today |
| Corrupt / unparseable file | Treated as absent, not an error |
| Unknown `v` version | Treated as absent |
| Origin mismatch vs requested sector | Discarded as absent |
| Post-scan fails (no scanner, `scan()` nil) | Upload the dig-pruned survivor set instead |
| Crash mid-sector | No upload; file stays pre-mine; next visit crosses the miss threshold and re-scans. Self-healing, no bookkeeping required |
| Server disk full | Log, evict, retry once; an absent index is survivable |
| Upload lost to comms failure | Index not updated; self-heals via miss threshold |

**Miss threshold** — re-scan mid-sector when more than ~25% of attempts came up
empty **and** at least 10 attempts have been made, so a sector with three stale
entries does not trigger a full re-scan. Both values configurable.

Misses are detected for free: `turtle.dig()` already returns `false` on air, so
no `inspect()` call is needed to notice a stale entry.

**Geofence filtering happens at route time, not storage time.** The index stores
every ore the scan found, including ore outside the fence — that is true
information about the world. The fence position depends on where the loader was
placed *on that visit* and differs between visits, so a fence-filtered index
would bake one visit's geometry into permanent data.

(Separately and independently of this design: ore outside the fence is currently
counted as FOUND, then fails in `navToOre` and lands in `skipped`, inflating
FOUND totals. Filtering at route time is the correct fix and is in scope here.)

**Eviction** — the store evicts least-recently-used sector files past a
configured byte budget. An evicted sector simply re-scans on next visit.

## Testing

- **Codec:** round-trip identity; boundary values at every corner (`dx` = 0 and
  32, `dy` = −68 and +32); empty and single-ore sectors; out-of-range
  coordinates rejected rather than silently wrapping — a wrapped coordinate
  would send miners to wrong blocks indefinitely.
- **Store:** missing file → nil; corrupt file → nil rather than a raised error;
  version mismatch → nil; eviction removes least-recently-used first.
- **Miner:** index present → no geo scan; index absent → scans exactly as today
  (pins current behaviour); miss threshold triggers mid-sector re-scan; dig
  pruning clears coordinates and counts incidental ore; post-scan failure falls
  back to survivor upload.
- **Mutation testing on every new test.** Seven tests in this codebase have
  already proven unable to fail against the defect they were written for, so
  each new assertion is verified by breaking the code beneath it.
- **Regression pins:** delivery behaviour untouched (standing hard constraint —
  `delivery_turtle.lua` is not modified); survey-only jobs unchanged; all 140
  existing tests green.

## Risks and unknowns

**Unverified: single modem message ceiling.** An unfiltered ~8 KB assign payload
is the largest thing this design puts on the wire. Typical targeted sends are
far smaller (~1 KB for a single ore type). This must be checked in-world before
the large case is relied upon; the implementation plan includes chunked transfer
as the fallback if it fails.

**No Lua runtime for the live fleet on the development machine.** Nothing here
may be claimed as verified without running it under the headless harness or
in-world. This is a standing project constraint.

**`proto.VERSION` must be bumped and pushed** for every change altering server or
protocol behaviour.

## Rejected approaches

**Miner-local cache.** Each miner stores its own scans on its own disk. Simplest,
no upload protocol change — but a *different* miner sent to the same sector
re-scans anyway, and the cache dies with a turtle wipe. Fails the stated
no-re-scan goal for a fleet.

**Full in-RAM server ore index with a query API.** Enables global "nearest 50
iron" queries and dashboard ore heatmaps. Rejected because its serialisation
cost already broke the event loop at ~100× less data
(`central_server.lua:2835`), and it buys global-query power that is explicitly
not a goal. Per-sector files can be indexed into RAM later if that changes, so
this design does not foreclose it.

## Out of scope

Bill-of-materials requests ("build a house, needs 50 iron"), exact-quantity
mining, and the build system itself. Those sit on top of this index and are
separate designs.
