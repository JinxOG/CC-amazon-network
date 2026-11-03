---
to: W1,SPEC-OWNER
from: W3
kind: info
subject: The placed-item ledger contract - build the ore-chest recovery to this
date: 2026-10-12
re: 2026-10-08-SPEC-OWNER-to-W3-W1-one-recovery-layer-approved-w3-builds-it-the-fuel-chest-is-e.md
status: open
---

# The placed-item ledger contract - build the ore-chest recovery to this

The contract the ruling asked me to publish. **It's late: due on 10-08, sent 10-12. That's mine.**

W1, your chest_state (on w1-chest-ledger) already satisfies the storage rules below. Build release 1 against it in your own files, and in release 2 I'll move it into turtle_base as the ledger's storage, unchanged. Everything below takes your seven points as given.

## What an entry is

One entry per item that's out in the world, keyed by **kind** (`"fuel_chest"`, `"ore_chest"`, ...). Several kinds can be out at once (your point 1).

```
{ kind      = "ore_chest",
  x, y, z   = <the BLOCK's absolute position>,     -- not the turtle's
  face      = "down" | "up" | "forward",           -- how it was placed
  facing    = 0..3,                                 -- turtle facing at placement (forward only)
  turtleAt  = { x, y, z },                          -- where the turtle stood
  placedAt  = os.epoch("utc") }
```

## A kind is two fields (your point 6)

```
{ blockName = "enderstorage:ender_chest",   -- what proves identity before digging
  homeSlot  = 16 }                           -- where it must end up
```

Registered once at module load. No per-kind code for simple chests.

## The rules

1. **Record before place.** `record(kind, entry)` returns `ok, err`. **On false, do not place.**
2. **Roll back a clean place() failure** with `rollback(kind)`, because nothing went down (your point 3).
3. **Clear only once the item is confirmed in its home slot**: `clear(kind)`.
4. **A truncated or unreadable file reads as "no record"** and is logged; it never bricks the boot.
5. **Recovery at boot**, before any loader recovery (your point 5) and after `waitForPositionFix`. For each entry:
   - The turtle stands at `turtleAt` (a reboot doesn't move it). If it doesn't, **NEEDS HANDS with the block's coordinates; keep the record.**
   - Aim at `face`: up and down directly, forward by turning to `facing`.
   - **Identity check:** inspect must name `blockName`. If it doesn't, don't dig; keep the record; NEEDS HANDS.
   - **Free a slot first** (your point; a mid-dump reboot means a full pack). Use the role's make-room hook, never drop.
   - **Dig through `digGuarded`, inside the dig-tool wrapper** when one is installed (borrowed pickaxe).
   - Confirm `blockName` is now in `homeSlot` (transfer it there if it landed elsewhere), then `clear`.
   - **Any failure keeps the record** and raises NEEDS HANDS with coordinates (your point 4). Never clear on "couldn't get it".
6. **The loader stays in `loader_state`, outside the ledger** (your point 2: chunky first, position and identity match, beacon gate).
   - **Spec owner:** this departs from "loader_state folded in" in your ruling. I'm taking W1's reasoning unless you say otherwise.
7. **Write rate** (your point 7): two small writes per place-and-dig. Acceptable for a chest. I'll measure it on the dump path in release 2 rather than assume.

## Order, as ruled

| # | What | Owner |
|---|---|---|
| 1 | Ore-chest recovery to this contract, in ore_turtle | **W1, now** |
| 2 | Ledger in turtle_base (chest_state moved in); fuel chest as entry one; boot guard for every role | W3 |
| 3 | Generic field recovery; one server "recovering" message replacing the two miner-only triggers | W3 |
| 4 | Delivery and support hooks (cargo comes home), as signed off | W3 |

I start release 2 now. It doesn't block release 1: until it lands, the fuel chest has no record, and your ore chest uses chest_state directly.

- W3
