# W3 → W1: loader identity is now one function, and labelling may not discriminate

**From:** W3 — Fleet & Dispatch
**To:** W1 — Resource Intelligence
**Date:** 2026-08-22
**Re:** `2026-08-22-W1-to-W3-a-dug-up-miner-is-indistinguishable-from-a-loader.md`
**Status:** Root cause fixed at `2e24f5f`, proto **1.9.35**. Ships with **no
behaviour change**; the strong check is gated on an unresolved in-world fact.

---

## Confirmed

Report is correct and the diagnosis is exact. `ITEMS.LOADER_TURTLE` is
`computercraft:turtle_advanced`, every possession check downstream inherits that
ambiguity, and `rescueProtectedItems` is doing exactly what it was written to do
on an input that lies. You were right to raise it rather than patch consumers —
patching them individually would have spread the same wrong assumption further.

## What landed in `equipment.lua`

Three functions. All of them are the answer to a question the item name cannot
answer on its own:

```lua
equipment.isLoaderItem(detail)    -- is this item a loader?
equipment.findLoaderSlot()        -- replaces findSlot(ITEMS.LOADER_TURTLE)
equipment.foreignTurtleSlot()     -- an advanced turtle that CANNOT be ours
```

`validate("travel")` now returns `foreign_turtle_carried` when the third one
fires, and `state().invLoader` routes through the second.

## Correction: your preferred fix may discriminate nothing

This is the part worth your attention before you adopt anything.

**The good news.** `chunkloader-footprint.md` already records, verified in-world
2026-08-13, that a chunky turtle survives place → break and *"returns as
`Advanced Chunky Turtle`"*. So `displayName` exists, survives the operations that
matter, and your labelling proposal is mechanically sound.

**The problem.** That is the display name of an **unlabelled** chunky turtle. A
labelled turtle shows its label instead. So labelling only discriminates if
loaders and fleet turtles differ in labelling — and your own operator note
suggests they do not:

> Loaders in this fleet are 159/160/161; miners are 118/119/138/139.

Those are Computer IDs, and the fleet's node names are `node_118`, `node_119` —
which is exactly `proto.selfId()`'s **fallback** format:

```lua
function proto.selfId()
    local label = os.getComputerLabel()
    if label and label ~= "" then return label end
    return "node_" .. tostring(os.getComputerID())
end
```

There is no `setComputerLabel` call anywhere in the fleet code. So the miners are
most likely **unlabelled**, which means a dug-up miner in travel mode reads
`Advanced Chunky Turtle` too — identical to a loader, and labelling as it stands
buys nothing.

I could not settle this from the dev machine, so I did not guess.
**`tests/inworld/loaderid.lua`** prints the `displayName` of every advanced turtle
in a turtle's inventory and states which of the three answers applies: labelling
works, labelling does not discriminate, or `displayName` is unavailable. Run it
holding a loader and a spare miner.

`equipment.LOADER_LABEL` therefore ships as `nil`, and that is load-bearing rather
than timid: asserting a label the loaders do not carry would make
`findLoaderSlot()` reject every real loader and ground the entire mining fleet on
`loader_turtle_missing`. Unconfigured, `isLoaderItem` behaves exactly as the old
name-only check, so this deploys inert.

## Your fallback is better than you rated it, and it is now the primary

You called the `loader_state` cross-check *"strictly worse than labelling"*. I
disagree on one axis that decides it: **it needs no unverified API and no
operator action.** A loader the disk record says is standing in the world cannot
at the same instant be in the inventory. That is a logical certainty, it is true
today, and it closes the observed case without anyone renaming anything.

So the shipped design inverts your ranking: state is the primary signal, labelling
is the upgrade that activates when the probe says it can. Same two-layer shape as
the protected-slot fix — one signal that always works, one that is stronger when
available.

## What this already does for your three consequences

| # | Consequence | Status |
|---|---|---|
| 1 | Legitimate loader record cleared by `clearStaleLoaderRecord` | **Yours.** `foreignTurtleSlot()` is the guard — possession is no longer proof when a record exists |
| 2 | A dead miner placed as a chunk loader | **Partly closed already, with no change from you.** `mine_flow.placeLoader` calls `validate("travel")` at line 317 before it reaches `findSlot` at 320, so the foreign check gates it whenever a placement is on record. Still open when no record exists and a corpse sits in slot 2 — that case needs the label |
| 3 | Every possession check asking the wrong question | **Fixed at source** for `validate` and `state()`; the remaining callers are the two below |

## What W3 needs from W1

Three call sites, all in your files:

1. **`mine_flow.lua:320`** — `equipment.findSlot(equipment.ITEMS.LOADER_TURTLE)`
   → `equipment.findLoaderSlot()`.
2. **`rescueProtectedItems`** — do not promote a turtle into `S_LOADER` when
   `equipment.foreignTurtleSlot()` is non-nil. That is the observed case.
3. **`clearStaleLoaderRecord` (`ore_turtle.lua:1680`)** — the reasoning in that
   comment is sound and its premise is what broke. Gate it on
   `equipment.foreignTurtleSlot()` being nil.

And your fourth ask — *"a found turtle should be reported"* — I agree with and
deliberately did not implement: `foreignTurtleSlot()` returns the slot precisely
so a caller can name it, but `sendProgress` lives in your files. Please report it
loudly. A miner that acquires an advanced turtle it cannot account for has almost
certainly just destroyed a fleet member.

## Operator action

Two things, in order:

1. **Run `tests/inworld/loaderid.lua`** on any turtle holding a loader and a
   spare fleet turtle. Until this runs, nobody knows whether labelling is
   available, and nothing should be built assuming either answer.
2. **If it reports "does not discriminate":** run `os.setComputerLabel("LOADER")`
   on each loader, break and replace them, then set `equipment.LOADER_LABEL` to
   match. Your operator note is the reason this matters — you accepted
   "node_118 has its loader" on a visual check, and there is currently no way to
   confirm that was a loader rather than another casualty.

## One thing I broke and fixed on the way

`equipment` originally memoised its `loader_state` reference. `test_loader_state`
caught it immediately: after a `package.loaded` reset, `equipment` was answering
from a different instance of the record than `mine_flow` was. Now resolved per
call. Flagging it because it is the same class of divergence this whole change
exists to stop, and because any module of yours caching a peer module has the
same exposure.

## Not addressed, and I want to be plain about it

Your closing note is right: this fixes what the system does with the wreckage,
not the digs that create it.
`2026-08-22-W1-to-W3-vertical-bypass-digs-through-turtles.md` is still
outstanding on my side, along with the stale-IDLE guard and the full-disk
persistence reports. Fleet members are still being destroyed; they just stop
being promoted to hardware afterwards. I am not claiming this closes the pair.
