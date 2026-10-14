---
to: W1,SPEC-OWNER
from: W3
kind: info
subject: Recovery layer release 2 is live as 1.9.141 - one line for W1, and what the standing restart test now covers
date: 2026-10-14
status: open
---

# Recovery layer release 2 is live as 1.9.141 - one line for W1, and what the standing restart test now covers

**Live:** 1.9.141, deployed 10-14 09:29 UTC, pinned to 7ced7cd. All 19 turtles were on it within 81 s. Every role's boot was clean:
- 19/19 measured position and facing and reported Ready;
- zero waits, zero stuck reports, zero ledger records outstanding.

Built to the ruling and contract. Plan: docs/superpowers/plans/2026-10-12-recovery-layer-release-2.md.

## What's in it

- **`base.ledger`**: one record per kind (`ledger_<kind>.dat`).
  - Record before place. Roll back a clean place failure. Clear only once the item is home.
  - An unwritable or throwing disk is reported, never assumed. A truncated file reads as no record.
- **Generic recovery**, in the contract's order:
  - position measured, plus facing only for forward items;
  - standing where it was placed;
  - the block IS the item;
  - room made without dropping;
  - `digGuarded` inside the dig-tool wrapper when one is installed;
  - then `bringHome`.
  - Every failure keeps the record and sends `needs_hands: <kind> at x,y,z -- <reason>`.
  - **Stale records clear themselves** (already home, or dug but not yet moved home), so nobody is sent to an empty block.
- **The fuel chest is entry one**, recorded in `refuelFromChest`, for every role.
- **`base.recoverLedger()`** runs at the top of `base.run` for every role.
- **No turtle moves after boot until position and facing are measured.** This is a guard in `tryMove`, armed by `base.init`. The boot route home is chosen from a measured position (`base.homeAfterBoot`): a single failed `gpsSync` used to send a docked delivery turtle down through its station chest. Miners keep `gpsSync` there.
- **Server:** `registry.flagNeedsHands` writes its **own field** (`ledgerNeedsHands`), shown on the dashboard, cleared by the turtle's `ledger_ok`. Not a dispatch bench.

## Verification

- 639 tests, 378 mutants killed.
- A fresh whole-branch review (opus) found 1 Critical and 4 Important issues. All were fixed test-first, plus #9 re-graded to Important (a throwing write killed `base.run`, a crash loop).
- One mutant is omitted on purpose: "boot guard armed before boot" hangs the suite, because the harness has no per-mutant timeout.

## W1: one line, yours

Please call **`base.recoverLedger()`** in ore_turtle **before `recoverPlacedLoader`**. It's idempotent and a no-op when empty. Today a miner reaches it only at `base.run`, after the loader recovery has flown away. Your ore chest becomes a ledger kind with:

```lua
base.ledger.registerKind("ore_chest", { blockName = "enderstorage:ender_chest", homeSlot = 16 })
```

record and clear in `bankPayload`, plus that call. Nothing else is needed from the layer.

## Deferred minors (not in this release)

- `digOutForFacing` could dig a forward-placed recorded chest in a dead end. It self-heals: the dug chest is found aboard next boot.
- Record facing and position only when measured.
- Re-check the block after `makeRoomBeforeDig`.
- A field reboot mid-refuel away from the dock gets NEEDS HANDS, not recovery, until release 3.

## Spec owner

**Release 3 is next:** generic field recovery, and one server "recovering" message replacing the two miner-only triggers. As you ruled, miner behaviour stays identical, and mutants that restore either old trigger must die.

The standing double-reboot test now applies to every role; the user will run it with the operator.

- W3
