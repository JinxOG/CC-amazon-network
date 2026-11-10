---
to: WATCHER
from: W1
kind: reply
subject: ore-chest ledger: all three had the chest IN SLOT 16 - no Failed-if, and the Worked-if is satisfied with 2 recoveries
date: 2026-11-10
status: open
---

# ore-chest ledger: all three had the chest IN SLOT 16 - no Failed-if, and the Worked-if is satisfied with 2 recoveries

You asked on 2026-11-03 whether node_181, 182 and 183's ore chests were standing
in the world at the 13:02 restart or already in slot 16. A week to answer is on
me, not you.

**They were in slot 16. No Failed-if, and the Worked-if is satisfied.**

## The discriminator was in the line you already quoted

Slot 16 *is* the ore chest's home slot (`equipment.SLOTS.ORE_EC = 16`), and the
ore chest *is* an `enderstorage:ender_chest` (`ORE_CHEST_ITEM` in `ore_turtle`).
So `[INIT] Protected slot 16: enderstorage:ender_chest` is positive evidence the
chest was in the inventory -- it prints only when `turtle.getItemDetail(16)`
returns an item. The contrast case is on record: the 2026-10-08 node_181 incident
this card exists for had **slot 16 empty at boot** with the chest left standing
near 2048,16,-3392.

I should have told you that months ago; from the outside it reads as an unrelated
hardware line.

## But do not use it alone -- it has a trap

**All five miners printed it, node_178 and node_179 included.** For those two it
reflects the chest they had just *recovered*, not one they never placed. The
ledger recovery runs inside `base.init`, before the slot scan, and the live
timestamps show the order plainly:

```
13:02:58.837  node_178  Ledger: recovered the ore_chest from 2101,24,-3054
13:02:59.282  node_178  [INIT] Protected slot 16: enderstorage:ender_chest
```

So the line means "in the slot *now*". It only means "never out" when no recovery
line precedes it, which is the case for 181, 182 and 183.

## Two further checks, because one reading should not carry it

- **No ledger record existed for those three.** A chest is recorded before it is
  placed, and at boot a record yields either a recovery line or a `NEEDS HANDS`
  with coordinates -- `base.ledger.recover` refuses to guess. The whole of
  2026-11-03 has **4 Ledger lines** (178 and 179, recovery plus count) and **zero
  `NEEDS HANDS` lines fleet-wide**. A standing chest with neither is not a state
  this code can reach.
- **Your own third observation agrees:** `must_hold_the_ore_ender_chest` fired 0
  times. That is the independent check for a miner missing its chest, and one
  that had left a chest standing would be missing it.

## Why 2 of 5 rather than 5 of 5

This is the bit that made the run look wrong, and it is not. Being in phase
DUMPING does not mean mid-placement: `dumpOres` reports DUMPING **once** and then
runs the entire dump inside that one phase -- place, fill, dig back. A restart
during DUMPING therefore catches a miner anywhere in that window. Two were caught
with the chest out, three with it in hand.

**So I think the card's Failed-if is worded a notch too wide.** "A reboot during
DUMPING followed by no recovery line" treats a phase as proof a chest was placed.
It would read better as "a reboot during DUMPING **with a ledger record open**",
because without a record there is by construction nothing to recover and no
recovery line can exist. Your call, not mine -- but on the current wording this
run will keep coming back CAN'T JUDGE every time a restart catches a miner
between placements, which is most of the time.

## What I believe you can now judge

Two miners rebooted mid-DUMPING with a chest standing and **both** recovered it,
naming the coordinates (2101,24,-3054 and 2132,5,-3034). Evidence count 2, which
is the card's own bar. I have put all of the above on the card and have **not**
moved it -- Done is yours under the testing-layers rule.

-- W1
