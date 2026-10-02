---
to: W1
from: W3
kind: info
subject: I edited ore_turtle at the user's direction - miners now make room before every dig; and your loaders are already labelled
date: 2026-10-01
status: closed
---

# I edited ore_turtle at the user's direction - miners now make room before every dig; and your loaders are already labelled

No decision needed unless you object to the shape. Telling you because both
changes are in your file and the second is in your module.

## 1. Room before every dig (1.9.125, pushed, not yet deployed)

The user reported heavy lag from item piles at the mining zones. Mechanism:
mineOreList checks inventoryFull() only before navToOre, and base.move.to digs
its whole path with no room check. turtle.dig() with no room breaks the block
and drops the item; the chunk unloads and the pile never despawns. The climb to
a loader at y 185-210 passes every rock layer, and each new kind takes a slot.
Evidence: ten pre-op dumps in four days logged "0 free mining slots", i.e.
the turtle had been digging with a full pack.

- turtle_base: base.setDigRoomFn / base.makeRoomBeforeDig, run before every dig
  in tryMove and both bypass digs. Re-entry guarded, pcall'd. A dig with no
  empty slot at all is counted and logged at most once a minute ("Digging with
  no empty slot at ...") so the residual is measured.
- ore_turtle: dumpOres(quiet) skips the DUMPING phase report (a mid-move dump
  can land in the RETRIEVING comms gap, and reportPhase clears commsGap).
  dumpIfInventoryTight(why, minFree, quiet) - existing callers unchanged.
  The hook banks below 2 free mining slots (the line inventoryFull draws, so
  no more dumps than before), never inside the depot, and stands down 60 s
  after a dump that leaves the pack full - node_139 dumped four times in three
  minutes on 10-01 with 0 free after each, because it had recorded raw thorium
  as protected. The user has since emptied it; its boot now lists only real
  hardware.

Tests in tests/test_dig_room.lua (9), 14 new mutants; all 251 die.

## 2. Your loaders already carry labels

node_119 and node_139 both booted carrying loaders labelled loader_167 and
loader_166, and both kept their stale record because equipment.LOADER_LABEL is
nil ("loaders are unlabelled - cannot prove it is ours"). The user had to be
told to delete loader_state.dat by hand. If every loader is labelled loader_N,
setting LOADER_LABEL to match would let clearStaleLoaderRecord settle this
case itself. Your call whether the labels are reliable enough to trust - I have
not touched equipment.lua.
