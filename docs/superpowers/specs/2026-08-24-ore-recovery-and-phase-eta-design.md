# Ore recovery and phase ETA — count what was there, estimate what is left

- **Date:** 2026-08-24
- **Author:** W1 — Resource Intelligence, from the operator's report
- **Implementer:** **W3 — Fleet & Dispatch.** Both changes are `central_server.lua`
- **Status:** Design approved by the operator; implementation plan not written
- **Protocol version at time of writing:** 1.9.46

---

## 1. The report, and what measuring it found

The operator: *"they are extremely inaccurate and I'd say it only mines 50% of
what it finds and ETA times are basically useless."*

**The miners are not losing half the ore. The counter is double-counting what they
find.** Measured across every zone in `/state`:

| Zone | found | mined | ratio |
|---|---|---|---|
| `912,-3280,1136,-3120` | 298,251 | 132,337 | 44% |
| `1008,-2608,1168,-2480` | 120,202 | 36,770 | 31% |
| `1040,-2832,1200,-2736` **(RESCAN complete)** | 38,324 | 24,485 | **64%** |

Per ore type within one zone the ratio sits between **34% and 49%** — for common
and rare, shallow and deep alike. Physical loss would scatter by depth and vein
size. A near-uniform ratio is arithmetic.

**The one trustworthy figure is 64%**, from the only zone whose RESCAN completed —
because RESCAN already replaces `oreFound` with *collected + still in the ground*
(`central_server.lua:1975`). So real recovery is about 64%, and the missing 36% is
genuinely-left-behind ore: a real problem, but a much smaller and different one
than the operator was seeing.

## 2. Root cause of the double count

`surveyMode` gates only the **digging** (`ore_turtle.lua:2077`):

```lua
if #ores > 0 and not surveyMode then
```

The scan and its `SECTOR_SCAN` report run in **both** passes. The server
accumulates `oreFound` from every one of them, guarded only against `RESCAN`
(`central_server.lua:1855`):

```lua
if zone.phase ~= "RESCAN" then
    for name, n in pairs(p.foundOres) do
        zone.oreFound[name] = (zone.oreFound[name] or 0) + n
    end
```

Every sector is therefore counted once in SURVEY and again in MINE. `found` is
~2× reality, and `mined/found` reads ~50% however well the mining went.

**The miner is not at fault and needs no change.** It reports the same correct
number twice; the server adds instead of choosing.

## 3. Design — ore recovery

**`found` means what was actually in the sector.** Adopted over "what the survey
forecast", because the operator's question was about *recovery*, and a forecast-
based percentage would give a tidier progress bar while never revealing that 36%
is being left behind.

### 3.1 Key it by sector

```
sectorSeen[key]   -- last scan report for that sector
sectorMined[key]  -- cumulative, summed across attempts
sectorFound[key]  = sectorMined[key] + sectorSeen[key]
zone.oreFound     = Σ sectorFound
zone.oreMined     = Σ sectorMined
```

`key` is the sector position — **not** the phase-qualified key `doneKeys` uses
(`central_server.lua:1903`). The point is that SURVEY and MINE reports for one
sector collapse onto the same entry.

### 3.2 Why that formula, and not simple replacement

A re-scan sees only what is **left**, so late reports understate. Three cases:

| Case | seen | mined | found | |
|---|---|---|---|---|
| Survey pass | 100 | 0 | 100 | correct |
| Mine pass, same sector | 100 | 100 | 100 | correct — **replaces**, no doubling |
| Retry: attempt 1 finds 100 mines 40, attempt 2 sees 60 mines 60 | 60 | 100 | 100 | correct |

Plain replacement gives 60 in the retry case; plain accumulation gives 160.
`mined + seen` is right in all three, and it is the same formula RESCAN already
uses — applied per sector as work proceeds rather than as a correction afterwards.

**RESCAN stops being a special case.** Its `zone.phase ~= "RESCAN"` guard and its
wholesale `zone.oreFound = newOreFound` rewrite both become unnecessary: a rescan
report is just another `sectorSeen` update. W3 should confirm that before deleting
either — W1 has not traced every consumer of that rewrite.

### 3.3 Consequences

- `orePct` (`central_server.lua:682`) needs no change; its inputs become correct.
- **Recovery percentages will RISE**, because the denominator stops being inflated
  — a sector counted in both passes currently contributes twice to `found` and
  once to `mined`. How far they rise is not predictable per zone and W1 is not
  going to guess: it depends on how many sectors have been through both passes.
  The rescan-corrected 64% is the only figure we can currently trust, and a
  post-change zone should land in that neighbourhood rather than at 44%.
- **Historical zones will not self-correct.** Their stored totals were accumulated
  under the old rule. Only zones mined after the change are comparable, and mixing
  the two on one dashboard invites exactly the confusion this is fixing. Worth a
  flag on the zone record, or accepting knowingly.
- `persistentZones` (`central_server.lua:674`) copies `oreFound`/`oreMined`
  wholesale and will need the per-sector tables, or a recomputation on save.

## 4. Design — phase ETA

### 4.1 What is wrong now

```lua
eta = math.floor((found - mined) / (mined / elapsed))
```

Wrong twice, both in the same direction:

- **Numerator inflated** — `found` is the doubled figure, so remaining work reads
  about double.
- **Rate deflated** — `elapsed` runs from `z.startTime`, which spans the whole
  SURVEY phase where `mined` is 0. The mining rate is averaged against a period
  containing no mining.

### 4.2 The model

**Scope: time to finish the current phase.** Chosen over whole-job because
estimating MINE from SURVEY samples needs a seeded ratio that is guesswork until
the phase turns over, and a confident wrong number is what the current code
already delivers.

```
eta = (sectorsRemainingInPhase / activeMiners) * meanSectorSeconds(phase)
```

| Term | Definition |
|---|---|
| `sectorsRemainingInPhase` | `z.total - z.done` for the current phase |
| `activeMiners` | miners currently assigned to this zone, minimum 1 |
| `meanSectorSeconds` | flat mean of completed sector durations **in this phase** |
| duration | assignment → `SECTOR_DONE`, including inter-sector travel |

**Per phase.** A SURVEY sector is a scan; a MINE sector is a scan plus digging
every vein. One mean across both describes neither.

**Divided by active miners.** Four miners share a 54-sector zone today. Throughput
is fleet-wide sectors-per-second; a per-miner mean overstates by 4×.

**Flat mean, not recency-weighted.** Considered and rejected: each sector is a full
depth column, so density varies spatially rather than drifting over time, and a
flat mean is the unbiased estimator for "how long will the remaining 50 take". If
variance proves high in practice, revisit — but not before it does.

**Duration includes travel** deliberately. It is real elapsed work and it scales
with the same sector count being estimated.

### 4.3 Below two samples, report nothing

`eta = nil` until at least two sectors have completed in the current phase. The
dashboard already handles a nil ETA. **A wrong number is worse than no number** —
that is the failure being fixed, and reintroducing it with a one-sample mean would
be the same mistake in a smaller form.

### 4.4 Where the timestamp goes

`zone.lastAssignments[minerId]` already records each miner's current sector
(`central_server.lua:1840`, `2055`, `2064` — three sites) and W3 has described it
as the lease ledger. It needs one field:

```lua
zone.lastAssignments[msg.from] = { x = …, z = …, isSurvey = …, assignedAt = os.epoch("utc") }
```

`SECTOR_DONE` then computes `now - assignedAt` and folds it into the phase's
running mean. **A sector with no `assignedAt`** — assigned before the change, or
after a restart that lost the ledger — **must be skipped, not counted as zero.**

### 4.5 Phase transitions reset the sample set

Per-phase means live in `zone.sectorTimes[phase] = { n, totalSeconds }`. On a phase
change the new phase simply has no samples yet, so §4.3 applies and the ETA is nil
until two land. That is correct rather than a gap: MINE timings say nothing about
RESCAN.

## 5. Ownership and scope

| Change | File | Owner |
|---|---|---|
| Per-sector `oreFound`/`oreMined` | `central_server.lua` | **W3** |
| Per-phase sector-time ETA | `central_server.lua` | **W3** |
| `assignedAt` on assignment | `central_server.lua` | **W3** |
| Miner-side reporting | — | **no change** |

The miner already sends everything required. This is entirely a server-side
accounting change, and W1 is routing rather than implementing.

## 6. What this does not address

- **The real 36%.** Once `found` is honest, the leftover is genuinely un-mined ore
  — unreachable veins, sectors aborted early, ore outside the fence. That is a
  separate investigation and it becomes *possible* only once the number is
  trustworthy.
- **Historical zones.** Totals recorded under the old double-counting are not
  retroactively correctable; only zones mined after the change can be compared.
- **Whole-job ETA.** Deliberately out of scope (§4.2). Revisit once per-phase
  means exist for all three phases, since that supplies the ratio a whole-job
  estimate would need.

## 7. Testing notes for the implementer

Both changes are pure accounting on server state and are reachable headlessly —
unlike most of what has been fixed this week.

- **The retry case in §3.2 is the one that discriminates**, and it is the one a
  naive fix gets wrong. A test that only covers survey-then-mine passes with plain
  replacement.
- **ETA below the sample threshold must assert `nil`**, not "some number".
- Assert the precondition that the sample count is what the test intends before
  asserting the ETA — W3's own note on five tests that passed for the wrong reason
  applies directly here, since both features are counters and a counter that never
  incremented looks exactly like one that did if only the output is checked.
