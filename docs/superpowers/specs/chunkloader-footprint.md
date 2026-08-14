# Chunk-loader footprint — verified environment facts

Consumed by `geofence.lua` (Task 5) and `ore_turtle.lua`'s fence constant (Task 8).
Do not change the constants in code without re-measuring and updating this file.

## Item registry names

Verified in-world 2026-08-13 via item-in-hand inspection.

| Role | Registry name |
|---|---|
| Pickaxe | `minecraft:diamond_pickaxe` |
| Chunky upgrade | `advancedperipherals:chunk_controller` |
| Ender modem | `computercraft:wireless_modem_advanced` |
| Loader turtle item | `computercraft:turtle_advanced` |

The chunky upgrade is Advanced Peripherals' Chunky Turtle, **not** the
`chunkloaders` mod. The original plan guessed `chunkloaders:chunk_loader_upgrade`,
which does not exist in this pack.

## Advanced Peripherals config — `[Peripherals.Chunky_Turtle]`

```
enableChunkyTurtle   = true
chunkLoadValidTime   = 600      # seconds a loaded chunk stays valid "without touch"
chunkyTurtleRadius   = 2        # chunk radius loaded by one chunky turtle (0..16)
```

### `chunkyTurtleRadius = 2`

One chunky turtle loads its own chunk plus 2 chunks in every direction:
**5×5 chunks = 80×80 blocks**, grid-aligned, centred on the chunk the turtle
occupies. Default was 0 (single chunk, 16×16), which cannot cover a sector.

### Why the fence is 3×3 chunks, not 5×5

`SAFE_RADIUS` is **not** a block radius. The loaded area is a grid-aligned set of
chunks, so the fence is expressed in chunk space:

```
FENCE_CHUNK_RADIUS = 1     -- 3x3 chunks = 48x48 blocks
```

Sector geometry (`central_server.lua` `SECTOR_STEP = 32`, `ore_turtle.lua`
`SCAN_RADIUS = 16`) gives a 33×33 block work area centred on a multiple of 32.
A sector centre always lands on a chunk boundary, so the work area spans exactly
3 chunks per axis. A 3×3 fence covers a sector exactly, with zero margin.

The config loads 5×5 while the fence authorises 3×3. That one-chunk margin on
every side is deliberate: it makes the exact-fit alignment harmless if a loader
lands a block off its intended chunk, instead of leaving the sector's far edge
unloaded.

**A block-radius Chebyshev fence cannot express this.** A grid-aligned chunk
region is not a square centred on the loader; near a chunk edge the two disagree
by up to 15 blocks, every one of them unloaded.

## Coupling hazard

`chunkyTurtleRadius` lives in the server-side Advanced Peripherals config.
`FENCE_CHUNK_RADIUS` lives in Lua on the turtle. **Nothing checks that they
agree.** If the config is lowered without lowering the fence, the miner roams
into unloaded chunks and freezes with no error. Changing either one requires
changing both.

Invariant: `FENCE_CHUNK_RADIUS <= chunkyTurtleRadius - 1`.

## `chunkLoadValidTime = 600` — open risk

The config describes this as the time a loaded chunk stays valid "without touch".
If a placed, idle turtle running no program does not constitute a touch, chunk
loading expires **10 minutes into a sector** and the miner freezes — Invariant A
failing on a timer.

Consequences already folded into the plan:

- Task 1 Step 1's 3-minute observation window is too short to detect this. It
  needs a ≥12-minute run before assumption 1 can be considered verified.
- Task 5c (loader beacon) is mandatory, not optional. A loader running
  `loader_turtle.lua` ticks continuously, which is the most plausible "touch".
  The beacon is load-bearing for chunk retention, not just telemetry.

Recommended: raise `chunkLoadValidTime` well above any sector duration (e.g.
86400). The documented range is open-ended above 60.

## Verification status

| Assumption | Status |
|---|---|
| 1. Placed idle turtle loads chunks (≥12 min) | **PENDING** |
| 2. Upgrade survives place → break → re-place | **PENDING** |
| 3. Runtime equip swap; pickaxe + chunky together | **PENDING** |
| 4. Footprint measured | Resolved from config: 5×5 chunks |
