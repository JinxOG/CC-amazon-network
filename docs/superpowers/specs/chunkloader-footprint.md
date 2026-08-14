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

## `chunkLoadValidTime = 600` — measured, not a decay timer for idle loaders

The config describes this as the time a loaded chunk stays valid "without touch",
which raised the worry that an idle placed loader would stop holding its chunk
ten minutes into a sector. **Measured: it does not.**

Test C ran a witness turtle 5 blocks from an idle, program-less chunky turtle
with the player 300+ blocks away:

```
[REPORT] 248 ticks over 20.8 min of wall clock
[REPORT] expected ~250 ticks if never stalled
[REPORT] largest gap: 7.0 s
[REPORT] no stall detected — loading held.
```

20.8 minutes is comfortably past the 600 s threshold, and the largest gap (7.0 s
against a 5 s interval) is ordinary tick jitter, not a stall. Whatever "touch"
means here, an idle placed chunky turtle satisfies it.

Consequence: the loader beacon (Task 5c) is **not** load-bearing for chunk
retention. It remains worth building for verification and orphan self-reporting,
which is what it was originally for.

Residual: no control run was recorded. A control — break the loader, wipe
`tick.log`, rerun for 5 minutes, confirm it stalls almost immediately — would
rule out the area having been held loaded by something else. Cheap, and worth
doing before rollout.

## Verification status

All three assumptions verified in-world 2026-08-13 using `tests/inworld/`.

| Assumption | Status |
|---|---|
| 1. Placed idle turtle loads chunks | **PASS** — 20.8 min, no stall (control run outstanding) |
| 2. Upgrade survives place → break → re-place | **PASS** — returns as `Advanced Chunky Turtle` |
| 3. Runtime equip swap; pickaxe + chunky together | **PASS** — `equip` true in both directions, loadout restored |
| 4. Footprint | Resolved from config: 5×5 chunks |

## Equipment detection — use `turtle.getEquippedLeft/Right`

The Step 4b probe settled how `equipment.lua` should identify upgrades:

```
restored:  L=modem  R=nil
   getEquipped L: computercraft:wireless_modem_advanced
                R: minecraft:diamond_pickaxe
```

Two facts:

1. **`turtle.getEquippedLeft()` / `getEquippedRight()` exist** on this version and
   return the equipped item's detail, including its registry `name`.
2. **`peripheral.getType()` returns `nil` for the pickaxe side**, so it cannot
   distinguish a tool from an empty side.

So upgrades are identified by registry name directly. The original plan's scheme —
map peripheral types to upgrade kinds, then infer the pickaxe by elimination
because it is the only non-peripheral upgrade — is unnecessary and is deleted.
That inference would also have been fragile: it assumed exactly one equipped
upgrade reports `nil`, which stops being true the moment two tools are held.
