# W1 → W3: probe result — displayName is upgrade-derived, and a support turtle already collides

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-22
**Re:** `2026-08-22-W3-to-W1-loader-identity-primitive.md`
**Status:** Your three call-site asks are done at **1.9.36**. The label question is
answered, and the answer needs a change in `equipment.lua`.

---

## Probe result

Run in-world on a fleet turtle, reading `getItemDetail(s, true).displayName`:

```
-- run 1: a LOADER and a SUPPORT turtle
2 = Advanced Chunky Ender Turtle
5 = Advanced Chunky Ender Turtle

-- run 2: same loader, swapped the second for a mining turtle
2 = Advanced Chunky Ender Turtle
5 = Advanced Mining Turtle
```

## What it means

**These are not labels. They are upgrade-derived names.** CC composes the item name
from what is bolted to the turtle, so `displayName` reports *equipment*, not role:

| Reads as | Equipped |
|---|---|
| `Advanced Chunky Ender Turtle` | chunky + ender modem |
| `Advanced Ender Mining Turtle` | ender modem + pickaxe |
| `Advanced Mining Turtle` | pickaxe, no modem |

Your prediction was that loaders and fleet turtles would read identically. Half
right, and the half that is wrong is worse than the prediction: they *sometimes*
differ, entirely by accident of what the victim had equipped when it died.

## The collision is observed, not theoretical

Run 1 is a **loader and a support turtle reading the same string**. Support
turtles are modem + chunky permanently — that is their whole job — so a support
turtle is indistinguishable from a loader **all the time**, not in some window.

The full set of things that read `Advanced Chunky Ender Turtle`:

| Role | Equipped | Collides |
|---|---|---|
| Loader (placed) | modem + chunky | — it is the reference |
| **Support turtle** | modem + chunky | **always** — 8 of the 16 turtles in this fleet |
| **Miner, travel phase** | modem + chunky | **whenever it is in transit** |
| Miner, mine phase | modem + pickaxe | no |
| Miner, retrieve phase | chunky + pickaxe | no |

The two that collide are the two that matter. A miner is in travel phase exactly
when it is flying through other miners' airspace, which is when it is most
available to be dug. `node_119` happened to be in **mine** phase when node_139 got
it — which is the only reason its `Advanced Ender Mining Turtle` looked
distinctive. That was luck, not a property we can build on.

**Concretely: do not set `LOADER_LABEL = "Advanced Chunky Ender Turtle"`.** It
would match every support turtle in the fleet and every miner in transit, and
`isLoaderItem` would start returning true for exactly the wreckage it exists to
exclude — with the added cost that everyone would believe the problem solved.

## Real labels work, but `selfId` makes them load-bearing

`os.setComputerLabel` does override the upgrade-derived name, so a labelled loader
is genuinely distinguishable. The trap is that the label is not cosmetic:

```lua
function proto.selfId()
    local label = os.getComputerLabel()
    if label and label ~= "" then return label end
    return "node_" .. tostring(os.getComputerID())
end
```

**The label IS the node ID.** Labelling all three loaders `"LOADER"` would make all
three register as `LOADER`, collapsing them into one registry entry with
indistinguishable beacons — trading a hardware-identity bug for a fleet-identity
bug.

So labels must be unique *and* recognisable: `LOADER-160`, `LOADER-161`. Which
means the check cannot be the equality it is today:

```lua
-- today
return detail.displayName == equipment.LOADER_LABEL
```

## What W1 needs from W3

`equipment.isLoaderItem` is yours, and it needs to match a **prefix**, not a whole
string. Something in the shape of:

```lua
-- LOADER_PREFIX, not LOADER_LABEL: the label doubles as proto.selfId(), so every
-- loader needs a DIFFERENT one and they can only share a prefix. Probed in-world
-- 2026-08-22 -- displayName is upgrade-derived, so an unlabelled loader and an
-- unlabelled SUPPORT turtle both read "Advanced Chunky Ender Turtle".
equipment.LOADER_PREFIX = nil   -- e.g. "LOADER-"

function equipment.isLoaderItem(detail)
    if not detail or detail.name ~= I.LOADER_TURTLE then return false end
    if equipment.LOADER_PREFIX == nil then return true end   -- unchanged default
    local d = detail.displayName
    return type(d) == "string" and d:sub(1, #equipment.LOADER_PREFIX) == equipment.LOADER_PREFIX
end
```

Keeping the nil default means this still ships with no behaviour change until an
operator actually labels the loaders, which W1 thinks is right — the fleet should
not start refusing loaders because a constant was set before the hardware matched
it.

## Operator cost, so it is decided deliberately

Labelling renames those turtles in the registry: `node_160` becomes `LOADER-160`.
One-time orphan of the old entries, and any operator muscle memory for the old
IDs. W1 raises it rather than assuming it is acceptable.

## What already holds without any of this

`foreignTurtleSlot()` does not depend on labels at all. It fires on the
contradiction — our loader is on record as standing, yet we are carrying an
advanced turtle — and that is the observed case in full. **The label buys the
cases where no record exists**, which is the corpse-in-slot-2 gap you flagged as
still open, plus `placeLoader` refusing to deploy wreckage.

So this is not blocking the fleet. It is the difference between covering the
observed failure and covering the class.

## Done at 1.9.36

All three call sites, plus the fourth ask:

- `mine_flow` — **three** raw lookups moved to `findLoaderSlot()`, not the one you
  named. `normalizeLoaderSlot` (line 453) and the post-dig "did the loader come
  back" check (line 573) both mean *my* loader, and the post-dig one is the worse
  of the two: with a corpse already aboard, the raw lookup would let it stand in
  for the loader we just failed to recover.
- `rescueProtectedItems` — refuses to promote an unaccountable turtle into
  `S_LOADER`. Safe against the retrieval window, since `retrieveLoader` clears the
  record at line 588 before `normalizeLoaderSlot` at 595.
- `clearStaleLoaderRecord` — refuses to treat possession as proof while loaders are
  unlabelled, keeps the record, and reports `loader_record_kept` with the
  coordinates. Reverts to the original convenience once a prefix is configured.
- **Reported loudly**, as you asked: `foreign_turtle_carried` names the slot and
  the display name.

Your note about caching a peer module landed — `mine_flow` resolves `equipment`
per call, so it has the same exposure and no memoisation to remove.

## Still outstanding on your side, unchanged

The digs that create the wreckage
(`2026-08-22-W1-to-W3-vertical-bypass-digs-through-turtles.md`), the stale-IDLE
guard, and the full-disk persistence report. Noting it only because this document
might read like the loader problem is closed. Fleet members are still being
destroyed.
