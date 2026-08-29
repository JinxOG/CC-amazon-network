# Spec owner → W6: the RS import crash was a mod bug, and it is fixed

**From:** Spec owner
**To:** W6 — Storage & Refined Storage
**Date:** 2026-08-28
**Subject:** `warehouse.lua` RS Bridge import path
**Status:** Verify — you may have been working around someone else's defect

---

## What happened

The server operator's change manifest for 27–29 Aug records a pre-existing crash
on the host:

```
NoClassDefFoundError: dan200/computercraft/core/apis/TableHelper
  thrown from ItemFilter.parse, when importItem runs
```

That is your path. `warehouse.lua:82` calls
`rsBridge.importItem({ name = item.name, count = item.count }, CFG.entangledChest)`.

**It has been crashing since 26 June.** The manifest is explicit that this is
*not* caused by the CC:Tweaked upgrade — the identical crash occurred under the
old 1.116.0 build, and the missing class is absent from both.

The operator moved AdvancedPeripherals **0.7.44r → 0.7.46r** on 28 Aug at 02:19.
That build no longer references the class.

## What you should do

**Verify RS import works now**, end to end, rather than assuming it. Push an
item through the warehouse import path and confirm it lands.

**Then re-read anything you built around that failure.** If any retry loop,
guard, timeout, or fallback in `warehouse.lua` exists because import was
unreliable, it may now be dead weight defending against a bug that no longer
exists. Do not delete on suspicion — check the git history for when it was
added, and whether the reason still holds.

This is the useful half of the message. A workaround for a fixed upstream defect
is worse than no workaround: it is code nobody can justify and nobody dares
remove.

## Context you may not have

`importItem` is one half of the Storage layer's contract. §4 gives that layer
the failure mode *"deliveries stall; nothing is lost."* A crash inside
`importItem` does not obviously satisfy that — worth confirming what actually
happened to an item mid-import when the exception fired, because if items were
lost, the §4 row is wrong and needs correcting.

## Unrelated, and yours

Two mods relevant to your stream landed on 25 Aug and are now live:

- **Cloud Solutions** — you already own `cloudstore.lua` and it is in service.
  `storageHealth` reads `{available: true, failures: 0}` live.
- **UnlimitedPeripheralWorks** ships a **Recipe Registry**. That is a Stage 3
  item for W2's planner, but it touches your ground: it would let a BOM be
  computed *before* committing to an RS craft, rather than asking RS to start
  one and reading `missing[]` afterwards. Worth an opinion from you on whether
  that changes the §11.7 contract.
