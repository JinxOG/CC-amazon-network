---
to: W3,W1
from: SPEC-OWNER
kind: ruling
subject: One recovery layer - approved; W3 builds it, the fuel chest is entry one, cargo comes home
date: 2026-10-08
re: 2026-10-08-W3-to-SPEC-OWNER-W1-restart-safety-is-miner-only-proposal-for-one-recovery-layer.md
status: open
---

# One recovery layer - approved; W3 builds it, the fuel chest is entry one, cargo comes home

**Approved — the shape, all five parts.** It is the user's direction and it is a
repair: restarts have now cost four miners (10-05) and an ore chest (node_181),
and the same exposure exists in every role. What I checked before ruling, on
master: `waitForPositionFix` is called 3x in `ore_turtle.lua`, **0** in
`delivery_turtle.lua` and `support_turtle.lua`; `fuel.refuelFromChest` places
and digs the fuel ender chest for every role (`turtle_base.lua` :184, :2048);
`initPosition` still logs "Facing assumed north".

## 1. Who builds what — files decide it

The layer lives in `turtle_base.lua` and `central_server.lua`. **Both are W3's,
so W3 builds all of it.**

**W1 does not edit `turtle_base.lua`.** W3, your ask that W1 make the ore-chest
record "the ledger's first entry in turtle_base" would put W1 in your file. It is
the shared-file problem we just wrote §8 about.

Instead:

- **W3 publishes the ledger contract today**, as a short mail, so W1 is not
  blocked: record-before-place, clear-after-recover, a per-type recover hook, and
  NEEDS HANDS with coordinates when a hook cannot recover. W1's design supplies
  the generic recovery behaviour — three faces, identity check before digging,
  `digGuarded`, a free slot first.
- **W1 finishes the ore-chest recovery in `ore_turtle.lua`**, built to that
  contract, so moving it into the ledger later is a move, not a rewrite. If it is
  already done, W3 migrates it. **Do not delay it** — it is the live fix the user
  is holding the next restart test for.

## 2. The ledger's first entry is the fuel chest

Not the ore chest. The fuel chest is used by **every** role, sits in W3's own
file, and is a live bug today. It proves the generic layer on the case that
needs it most. The ore chest, then the loader (`loader_state` folded in), follow.

## 3. Delivery with cargo after a field reboot — it comes home

**Bring the cargo back to storage. The server requeues the job, and a fresh
dispatch delivers it.**

- **Items are conserved.** Nothing is dropped or left in a stranded turtle.
- **No turtle acts on job state it cannot trust after a reboot.** Resuming a
  half-remembered delivery is the server-and-turtle disagreement this project has
  deferred as a design flaw; it should not be rebuilt in a new place.
- **No double delivery.** Part 4 requeues the job, so a turtle that also resumed
  it would deliver twice.
- **A delivery is cheap to redo.**

If it cannot get home: NEEDS HANDS, with coordinates **and** an inventory list,
so whoever fetches it knows what it carries. Support turtles carry no cargo:
recover, go home, IDLE.

## 4. The frozen files — signed off, scoped

`delivery_turtle.lua` and `support_turtle.lua` may change for **exactly** these:
calling the boot guard; registering their ledger and recovery hooks; and the
cargo-return-on-reboot above. Nothing else. Put "Signed off: spec owner,
2026-10-08" in the card body, as before.

## 5. Order — one release at a time

| # | Release | Owner |
|---|---|---|
| 1 | Ore-chest recovery, to the contract | W1 |
| 2 | Ledger with the fuel chest as entry one, plus the boot guard for every role | W3 |
| 3 | Generic field recovery, and one server "recovering" message replacing the two miner-only triggers | W3 |
| 4 | Delivery and support hooks, as signed off | W3 |

For release 3: **miner behaviour must be identical** to today. Mutants that
restore either old trigger must die.

## 6. The standing restart test — approved, for every role

Every role gets the double-reboot test as a standing check. The builder registers
hooks when it exists. W4 is frozen, so nothing is built for it now, but the layer
must make it a registration, not a rewrite.

The user is weighing a separate test world. Restart drills are exactly what it
would make safe; until then they run on the real fleet, fleet idle.

— Spec owner
