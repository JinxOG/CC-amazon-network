---
to: W1
from: W3
kind: info
subject: initProtectedSlots recorded rock as hardware on all four miners after a mid-job reboot - fixed in your files at the user's direction
date: 2026-10-02
status: open
---

# initProtectedSlots recorded rock as hardware on all four miners after a mid-job reboot - fixed in your files at the user's direction

No decision needed unless you object. It is your open question about
initProtectedSlots, now with the evidence and a fix.

## What happened (2026-10-03)

The user ran a planned whole-server restart at 02:02 UTC with all four
miners mid-dig, to test the outage path. At their 02:10 boot each miner's
initProtectedSlots recorded the contents of its open slots as hardware:

    node_118  slot 2: minecraft:tuff               slot 4: electrodynamics:dustsulfur
    node_119  slot 2: minecraft:lapis_lazuli       slot 4: minecraft:cobbled_deepslate
    node_138  slot 2: mekanism:raw_osmium          slot 4: minecraft:cobbled_deepslate
    node_139  slot 2: minecraft:redstone           slot 4: minecraft:cobbled_deepslate

(loader standing in the world, swap slot open, both filled by digging).
shouldDump then excluded those names for the rest of the job. Packs filled
with deepslate one by one (node_119 03:18, node_118 03:57, node_138 04:37,
node_139 05:02); my new dig-room hook logged "banking left 0 free" and
"Digging with no empty slot" ~250 times between them; RS intake tapered to
zero by 05:21. node_119 dug its loader at 04:36 with 0 free slots:
loader_lost_after_dig (your card - the guard that refuses the dig would
have saved it). The user's screenshot of node_119 showed slots 2 and 4-14
full of cobbled deepslate and lapis. node_139's raw thorium on 10-01 was
the same bug. All four jobs cancelled at 06:44; the user is emptying them
and making new loaders.

## The fix (0b8d3d7, pushed, ships in 1.9.126)

- equipment.isHardwareItem(name): true only for the five equipment.ITEMS
  names, enderstorage:ender_chest, or an entangled chest.
- initProtectedSlots: an item in a hardware slot that is not hardware is
  printed ("not hardware, so it will be banked, not protected") and NOT
  recorded. Everything else unchanged.

3 tests (2 behaviour in test_equipment, 1 source-only on initProtectedSlots),
3 mutants, all killed.

## Still yours

The loader-dig guard (refuse the retrieval dig at 0 free) is now the only
thing between a full pack and a lost loader, and today showed a full pack
can come from a cause the dig-room hook cannot fix.
