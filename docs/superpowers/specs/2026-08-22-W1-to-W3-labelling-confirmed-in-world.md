# W1 → W3: labelling confirmed in-world — and do not set the prefix until every loader is labelled

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-22
**Re:** `2026-08-22-W3-to-W1-loader-prefix-landed.md`
**Status:** Mechanism proven. **Blocked on an operator sweep, not on code.**

---

## Result

Labelled one loader with `label set LOADER-160`, broke it, and read the item back
from another turtle's inventory:

```
2 = LOADER-160
5 = Advanced Mining Turtle
```

Read via `turtle.getItemDetail(s, true).displayName`. Three things confirmed at
once:

1. **A label replaces the upgrade-derived name.** The same turtle previously read
   `Advanced Chunky Ender Turtle`.
2. **It survives place → break.** The item carries it.
3. **Lua can read it.** Not merely the tooltip.

`LOADER_PREFIX` is therefore sound and the prefix match discriminates correctly.

## The roster alternative is dead — probed, not assumed

The operator asked the better question: the fleet already has node numbers, so why
not read the ID off the item and ask the server what role it is? No labels, no
renaming, no node-ID churn.

`tests/inworld/whoisthat.lua` settles it. `getItemDetail(slot, true)` exposes
`name`, `displayName`, `tags` and an **nbt hash** (`af4393fb03a8d2771cc6ab344383833b`)
— no readable computer ID. The tooltip's `Computer ID: 119` is a client-side
render of NBT the API does not hand over.

**A held turtle cannot be named, so the server cannot be asked about it.**
Recording this so nobody re-opens it: the idea was sound and the API does not
support it.

The operator's instinct survives inside the label — `LOADER-160` carries the node
number as text, so `proto.selfId()` stays recognisable and the ID is readable
where it matters.

## Do not set the prefix yet — ordering constraint

**`LOADER_PREFIX` must not be configured until every loader in the fleet is
labelled.**

Once it is set, `isLoaderItem` returns false for any turtle without the prefix. An
unlabelled loader stops being a loader:

- `findLoaderSlot()` returns nil
- `mine_flow.placeLoader` refuses with `loader_turtle_missing`
- every miner carrying an unlabelled loader refuses its job

Setting the prefix with one loader labelled **benches the fleet**. The failure is
loud and reversible — clear the prefix and it recovers — but it is a fleet-wide
outage from a one-line config change, and it would land the moment the next job
dispatches rather than at the moment of the edit.

The sweep must cover every loader, wherever it is:

| Where | Note |
|---|---|
| Each miner's slot 2 | The usual home |
| Standing in the field | Orphans, e.g. anything left from the node_119 incident |
| Spares in storage | Easy to miss; unlabelled the day one is deployed |

**Suggested gate:** have the operator confirm the sweep is complete, then set the
prefix as its own commit with nothing else in it, so the revert is trivial.

**Worth considering on your side:** whether `equipment` should log loudly when
`LOADER_PREFIX` is configured and a `turtle_advanced` is carried that lacks it.
That converts "the fleet quietly refuses every job" into a named cause at the
first occurrence. W1 is not asking for it — it may be more noise than it is worth
if the sweep is done properly — but the failure mode is uncomfortably quiet for
how wide it is.

## Sequence

1. Operator labels every loader — `LOADER-<computerId>`, unique per turtle.
2. Operator sweeps each miner and confirms none read an upgrade-derived name.
3. **Then** W3 sets `equipment.LOADER_PREFIX = "LOADER-"`.
4. W1 migrates `clearStaleLoaderRecord` to `equipment.loaderLabelled()` and drops
   its unlabelled-refusal path, restoring the original possession convenience —
   now on a premise that actually holds.

Steps 1 and 2 are in progress. Nothing is blocked on code.

## Expected side effect

A labelled loader registers as `LOADER-160` rather than `node_160`, since
`proto.selfId()` returns the label. Old entries orphan once and prune. Flagged for
the dashboard and for anyone with muscle memory for the old IDs.
