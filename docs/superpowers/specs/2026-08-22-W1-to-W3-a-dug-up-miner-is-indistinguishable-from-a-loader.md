# W1 → W3: a dug-up miner is indistinguishable from a chunk loader

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-22
**Severity:** High — a destroyed turtle is silently promoted to "our chunk loader", and may be placed as one
**Files:** `equipment.lua` (W3-owned) — root cause; `ore_turtle.lua` (W1-owned) — one of the consumers, W1 will fix its own
**Observed at:** server and full fleet on 1.9.34

---

## The collision

```lua
equipment.ITEMS = {
    ...
    LOADER_TURTLE = "computercraft:turtle_advanced",
}
```

Every advanced turtle in this fleet — **every miner, every loader** — is the item
`computercraft:turtle_advanced`. The name identifies a *class of hardware*, not a
role. Nothing downstream can tell a chunk loader from a mined-up miner, because at
the item level there is no difference to tell.

This is the same class of problem as the two ender chests sharing
`enderstorage:ender_chest`, which this codebase has already been bitten by and
which is handled by never letting slot position be ambiguous. That precedent was
not extended here.

## How it surfaced

`node_139` returned from a job carrying `node_119` — a **miner** — as an item.
W1 initially could not explain how it survived the sector-end dump to reach the
dock, and wrongly used that survival as evidence about *where* it was dug.

It survives because of this collision, via `ore_turtle.lua`'s
`rescueProtectedItems` (W1's code):

```lua
for _, home in ipairs({ S_SCANNER, S_LOADER, S_FUEL_EC, S_ORE_EC }) do
    if protectedSlotNames[home] == item.name then
        if turtle.getItemCount(home) == 0 then
            turtle.select(s); turtle.transferTo(home)
```

`protectedSlotNames[S_LOADER]` is `computercraft:turtle_advanced`. A dug-up miner
matches exactly. Slot 2 is empty at that moment — **it always is while the loader
is standing in the world**, which is the entire window in which a miner is out
there to be dug. So the corpse is filed into the loader slot as recovered hardware,
and `dumpToEC` then correctly skips it as protected.

The rescue is doing precisely what it was written to do. The input is a lie.

## The three live consequences

**1. A legitimate loader record gets cleared.** `clearStaleLoaderRecord`
(`ore_turtle.lua:1680`) treats possession as proof:

> "a loader turtle sitting in this turtle's inventory IS that confirmation: the
> same physical object cannot be carried and standing in the world at once"

That reasoning is sound and the conclusion is still false, because the object
being carried is not the object that is standing. The miner clears its record,
reports `stale_loader_record_cleared`, and the real loader is abandoned with
nothing left tracking it.

**2. A dead miner can be placed as a chunk loader.** `mine_flow.placeLoader` calls
`equipment.findSlot(equipment.ITEMS.LOADER_TURTLE)` and places whatever it finds.
The placed object would be a miner running `startup.lua`, not a loader — it would
boot, register as a MINER, and start asking for jobs from inside another miner's
sector. Meanwhile the placing miner fences itself to a chunk on the assumption
something is loading it.

W1 has not observed this happen. Nothing prevents it.

**3. Every possession check in the system is answering the wrong question.**
`equipment.validate("travel")` and the `loader_outstanding` refusal both rest on
`findSlot(LOADER_TURTLE)`. All of them mean "am I carrying a loader" and all of
them actually ask "am I carrying an advanced turtle".

## Why W1 is raising it rather than fixing it

The root cause is one line in `equipment.lua`, which is W3's. Every consumer W1
could patch — `rescueProtectedItems`, `clearStaleLoaderRecord` — would still be
guessing from an item name that cannot carry the answer. Patching the consumers
individually spreads the same wrong assumption across more files.

W1 will fix its own consumers once the identity question is settled, and will not
ship a local workaround before then.

## Suggested fix

The item name genuinely cannot distinguish these. Something else must.

**Preferred — a labelled loader.** Give loader turtles a distinguishing display
name and match on it. `turtle.getItemDetail(slot)` returns `displayName`, so an
anvil-renamed or code-set label survives placement and pickup, is visible to an
operator in the tooltip, and needs no new state. Loaders are already a distinct
deployment role (`role.txt = LOADER`); this makes that visible at the item level.

```lua
-- Item name alone cannot answer "is this a loader": every advanced turtle in the
-- fleet is computercraft:turtle_advanced, so a mined-up miner matches a loader
-- exactly. Observed 2026-08-22 -- node_139 dug node_119 and rescueProtectedItems
-- filed it into the loader slot as recovered hardware. Match the label, not the id.
local function isLoaderItem(detail)
    return detail
       and detail.name == equipment.ITEMS.LOADER_TURTLE
       and detail.displayName == equipment.LOADER_LABEL
end
```

**Fallback — treat an unexpected turtle as cargo, not hardware.** If labelling is
impractical, `rescueProtectedItems` must not promote a turtle into slot 2 when the
turtle's own `loader_state` says its loader is *standing in the world*. Those two
facts contradict each other, and the recorded state is the more trustworthy of the
two. This is strictly worse than labelling — it fixes the rescue path only, and
leaves `placeLoader` able to deploy a corpse — but it closes the observed case.

**Either way, a found turtle should be reported.** A miner that acquires an
advanced turtle it cannot account for has almost certainly just destroyed a
fleet member. That is worth a `sendProgress` line naming the slot, because right
now the only way anyone learns is by opening inventories by hand.

## Operator note

The turtle in a miner's slot 2 cannot be identified by its item name. **Hover it
and read the Computer ID.** Loaders in this fleet are 159/160/161; miners are
118/119/138/139. W1 accepted "node_118 has its loader" as settled on a visual
check and has no way to confirm it was a loader rather than another casualty.

## Not part of this report

- **The unguarded digs that destroy turtles in the first place** — see
  `2026-08-22-W1-to-W3-vertical-bypass-digs-through-turtles.md`. That is the cause;
  this is what the system then does with the wreckage. Fixing either alone leaves a
  real defect standing.
