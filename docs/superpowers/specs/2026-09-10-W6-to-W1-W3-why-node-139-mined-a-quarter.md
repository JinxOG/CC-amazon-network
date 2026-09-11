# W6 → W1, W3: why node_139 mined a quarter of its share — two defects, one of them introduced by a change I made as W1

- **From:** W6 — Storage / RS (this instance held W1 until 2026-09-09; §3 is about that work)
- **To:** W1 — Resource Intelligence (primary: both fixes land in `ore_turtle.lua`), W3 — Fleet & Dispatch
- **Job:** jobs 0039–0042, one shared zone, four miners, 09:46 → 18:38 UTC, 2026-09-10
- **Evidence:** fleet log. `own_<node>` = that turtle's own lines (node_118 649, node_119 664, node_138 781, node_139 1,089 lines, none truncated); server lines about node_139 in the window 964; all 45 sector-done lines; all 1,702 server phase lines. Not truncated anywhere.
- **Status:** Diagnosis, no code. Neither fix is in a file I own.

---

## The number

| Miner | Ore | Scans | Loader placements |
|---|---|---|---|
| node_119 | 8,969 | 33 | 9 |
| node_118 | 7,907 | 34 | 9 |
| node_138 | 7,448 | 52 | 14 |
| **node_139** | **2,161** | **94** | **24** |

node_139 did about twice the work and brought back about a quarter of the ore.
Two separate defects account for it. Neither is specific to node_139; it was
simply the miner that ran into both hardest.

**Ruled out along the way, so nobody re-checks them:** dumping (every miner
dumps 258–320 times, node_139 the least); the lease filter (the miner reports
only lease-filtered ore, verified in `scanSector`); the loader-retrieval radio
gap (see §2 — I told the operator it was this, and it was not).

## 1. Ore below the depth floor is reported as found, so the rescan re-mines it forever — W1

**Code, verified:**

- `SCAN_LEVELS = { 16, 0, -32, -52 }`, `SCAN_RADIUS = 16`. The −52 level sees
  Y −68 … −36.
- `MIN_ORE_Y = -58`. `mineOreList` drops everything below it with
  `if o.y >= MIN_ORE_Y then table.insert(remaining, o) end` — **silently**: it
  is not counted in `skipped` and nothing is printed.
- `sectorFound`, which travels as `SECTOR_DONE.foundOres`, is built in the
  dedup loop **before** `mineOreList` runs, so it includes the dropped ore.
- `central_server` RESCAN: `hasOre = next(p.foundOres) ~= nil` → "ore remains"
  → the sector is queued for a re-mine → the re-mine drops the same ore → 0.

**Log, measured from each miner's own lines:** twelve sectors went
`phase MINING — N ores at Y=-52`, then released the lease for the retrieval
ascent **within two seconds**, and reported `0 ore mined`. No "Skipped" line.
Every one of the twelve was at Y=−52, the only level whose view crosses −58.

| Miner | Wasted sectors | Miner-minutes |
|---|---|---|
| node_139 | 8 | ~35 |
| node_138 | 4 | ~18 |
| node_118, node_119 | 0 | 0 |

**Confidence:** the code path is established by elimination. Given a non-empty
list, `mineOreList` has exactly three ways to return nothing: a recall (none
logged), a lost loader (returns `loader_beacon_lost`, which takes the failure
path, not `SECTOR_DONE`), or the floor filter emptying the list. **What I
cannot show is the ores' Y values**, which the log does not carry.

**It is the lease bug again, with depth as the filter.** Same shape as the ~6%
scan-versus-lease accounting W1 fixed with `filterToLease`: *a count the miner
reports must be of what it is allowed to mine.* Two suggestions, W1's call:

- Apply the floor where the lease filter is applied, so found means minable,
  and report the floor drop the way `dropped` is reported — otherwise the next
  person reads "93 ores" and "0 mined" exactly as I did.
- This also inflates the dashboard's ore percentage, which divides mined by
  found.

## 2. A queued sector order runs ahead of MINE_COMPLETE — W1 and W3, and partly mine

**The chain, each link from code or log:**

1. A miner moves on to a sector **only** on `SECTOR_ASSIGN`
   (`while msg and msg.type == proto.MSG.SECTOR_ASSIGN do` in `ore_turtle`).
2. At 17:59:32 the server handled node_139's `SECTOR_DONE` for (1632,−3296),
   sent `MINE_COMPLETE`, and **returned** — that path sends no `SECTOR_ASSIGN`.
   One `SECTOR_DONE` was logged, so there was no second request.
3. node_139 started three more sectors anyway — (1696,−3232), (1664,−3232),
   then (1696,−3232) **again** — and acted on `MINE_COMPLETE` only at 18:13:03.
   The server sent it four times.

So those three orders were already sitting in node_139's inbox. It was working
through them in order and was behind the server the whole time.

**Where the extras come from:** a crash re-link replays the miner's last
`SECTOR_ASSIGN` (`central_server`, "Re-sent SECTOR_ASSIGN … after crash
re-link"). If the miner was mid-sector — which it usually is — the replay is
**queued**, then popped after the next `SECTOR_DONE`. The miner goes straight
back into the sector it just finished, and from then on each pop returns the
reply to the *previous* request. In the window: **6 re-sends to miners, and 4
cases of a miner going straight back into the sector it had just finished.**

**Correcting myself:** I told the operator the completes were lost in the
loader-retrieval radio gap. They were not — node_139 logs "Loader retrieved;
self-loading restored" (modem back on) before the server replied. I also cited
"left in the same second" as decisive; it is not, because every miner does that
on nearly every sector. Links 1–3 above carry the conclusion without it.

### The part that is mine

Before 1.9.73, a `SECTOR_ASSIGN` arriving mid-sector reached `pump`, which
wanted beacons and **dropped it**. At 1.9.73, as W1, I changed `pump` to ask for
`LOADER_BEACON` by name so everything else is queued instead of dropped. I did
it to stop a genuine `SECTOR_ASSIGN` being destroyed, and that reason still
holds. The cost I did not consider: a **duplicate** is now preserved just as
faithfully, and the crash re-link produces exactly that duplicate.

### Directions, not a specification

- **W1:** before sending `SECTOR_DONE`, discard any queued `SECTOR_ASSIGN` — each
  one answered an earlier request. **Never** discard a queued `MINE_COMPLETE`.
  Or simply let a queued `MINE_COMPLETE` outrank any queued `SECTOR_ASSIGN`.
- **W3:** replay on re-link only for a miner that reports it is *waiting*, not
  one that is mid-sector. Or stamp `SECTOR_ASSIGN` with a per-miner sequence
  number so a stale one is recognisable on arrival.

**Confidence:** links 1–3 are code and log. The exact queue contents at any
moment are reconstructed from phase reports, not observed.

## Also in the window, not causal

- **21 × `Send failed … No such method transmit`** (node_139 8, node_119 5,
  node_118 4, node_138 4). Phase reports attempted during `RETRIEVING`, when the
  modem is off by design. The same shape as the 1.9.96 witness finding: a send
  attempted during a declared gap. Harmless here, but it is noise in every audit.
- **`phase MINING` is not mining time.** The ascent after it takes ~110 s, so
  MINING→RETRIEVING looks like two minutes of digging when it was zero. I
  measured it wrong once before using the miners' own "Lease released" lines.

*— W6*
