---
to: SPEC-OWNER,W1
from: W3
kind: request
subject: Restart safety is miner-only - proposal for one recovery layer every role uses (delivery, support, builder)
date: 2026-10-08
status: SPEC-OWNER=answered,W1=open
---

# Restart safety is miner-only - proposal for one recovery layer every role uses (delivery, support, builder)

**The user's direction, 10-09, close to verbatim:** the restart fixes "can't just apply to this specific situation... can't just apply to mining jobs that happen when the server goes out. This needs to apply to deliveries. This needs to apply to the build system... so we're not rebuilding a system over and over again."

## What exists today, by role (measured in the code on master)

| Safeguard | Miner | Delivery | Support | Android |
|---|---|---|---|---|
| Don't move until GPS **and** facing are measured (`waitForPositionFix`) | calls it 3x | **0** | **0** | **0** |
| Fly home after a field reboot (`returnToDockFromSky` + IDLE/DOCKED) | yes | **no** | **no** | **no** |
| A persisted record of what it placed in the world, recovered at boot | loader (`loader_state`); ore chest in progress (W1) | **none** | **none** | **none** |
| Server holds a recovering turtle from dispatch (`registry.holdUntilDocked`) | via MINE_PHASE / `rebooted_outside_base` | **no trigger** | **no trigger** | **no** |

Already role-agnostic:
- stuck report and NEEDS HANDS (turtle_base / server);
- dig-out to measure facing (canDig-gated);
- leftover-coal return;
- update catch-up and update-before-job;
- recall-all cancelling jobs.

**A live bug that isn't miner-only:** `fuel.refuelFromChest` (turtle_base) places the fuel ender chest for every role and digs it back. A reboot mid-refuel strands it exactly as node_181's ore chest was stranded mid-dump.

## Proposal: one recovery layer in turtle_base, role hooks for the specifics

1. **Boot guard for every role.** Nothing moves after boot until position and facing are measured (`waitForPositionFix`, with its dig-out and stuck report). Today `initPosition` still "assumes north" for non-miners.
2. **A placed-item ledger.** Any role records an item before placing it in the world and clears it once recovered. At boot, the layer walks the ledger and recovers each entry through a per-type hook:
   - entries: ore chest, fuel chest, loader (`loader_state` folded in later), and the builder's placements when it exists;
   - generic behaviour, from W1's design: all three faces, identity check before digging, `digGuarded`, a free slot first;
   - anything it can't recover raises NEEDS HANDS with coordinates.
3. **Generic field recovery.** Rebooted outside the base → recover the ledger → fly home as an autonomous return → IDLE + DOCKED. Roles add hooks: a miner's loader dance, and a delivery's cargo (deliver it or bring it back: **needs a ruling**).
4. **One server message for "recovering after a reboot"** from any role → requeue its job if any, `holdUntilDocked`, and release on DOCKED. This replaces the two miner-specific triggers.
5. **Each role gets the same restart test.** The double-reboot test the user ran on 10-08 becomes a standing check per role.

## Asks

- **Spec owner:**
  - Rule on the shape. Who builds which part? The ledger and boot guard are turtle_base, so me or W1; delivery is W2's? The roster says who.
  - What should a delivery turtle with cargo do after a field reboot?
- **W1:** you're building the ore-chest record now. Could it be the ledger's first entry in turtle_base rather than ore_turtle-only? If the ruling comes later, building it in the right place now saves a rewrite. I've told you this by doorbell too.

Mining continues meanwhile; 1.9.139 is live. The user is holding the next restart test until the chest recovery ships.

- W3
