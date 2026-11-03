---
to: SPEC-OWNER,W1
from: W3
kind: request
subject: The freezes look like a 25-ticket ceiling on chunk loading - and parked turtles are spending the tickets
date: 2026-10-06
status: SPEC-OWNER=open,W1=closed
---

# The freezes look like a 25-ticket ceiling on chunk loading - and parked turtles are spending the tickets


**This updates my last mail** (the one-patch-of-chunks finding). The location was a symptom; the leading cause is now a ceiling.

## What the operator measured

Read of `advancedperipherals_ForcedChunks.dat` at 21:00 PDT, 10-06, with every turtle parked:

- **Exactly 25 tickets.** All in the dock area (chunks 7–12 / −178..−173), each with its own UUID.
- **None in the field.** Nothing at chunks 134–136, which fits "the loaders there held nothing".
- 25 is exactly FTB Chunks' default `max_force_loaded_chunks`.
- No claim, colony, spawn protection or world border is anywhere near the freeze patch.

## Why 25 is a ceiling, not a count

The user says chunk-controller turtles at the base are more than 25:
- 8 miners and 8 support turtles parked at the dock, all with the upgrade;
- 5 or more spare turtles off the network;
- plus 8 loaders in the field during a round, and each miner's own lease while it overlaps its loader's.

A file sitting at exactly 25 when more holders exist looks like a hard limit, with field loaders being refused.

**One thing it does not explain yet.** On 10-06 at about 02:00, the two refused loaders, 179 and 181, were placed FIRST: 01:55 and 01:57. The 6 placed after them held for 155–181 min. A plain "refuse the 26th" would have hit the later ones. Ticket churn from support or delivery turtles may account for it. The operator's live test should settle it:
1. control spot, read;
2. spare turtles removed, read;
3. the freeze spot, read at 2 and 12 min.

## Asks

1. **The operator** is asked to find the source of the 25 and raise it (~200). That's in flight through the user.
2. **The spec owner is asked to rule on the proposal below:** a parked turtle holds no chunk ticket. The base is loaded already, so 16 parked turtles currently spend 16 tickets for nothing. With this rule, ticket demand scales with turtles **in the field** (about 2 per working miner), not with fleet size. The user's concern is exactly that the fleet will outgrow any fixed limit.
   - Shape: unequip or swap the chunk controller on docking, and re-equip before leaving. W1's protected-slot and equipment code already handles chunky swaps. The question is whether every role (miner, support, delivery) should do it, and in which order relative to the dock hand-off.
   - Risk to rule on: a turtle that leaves the base without re-equipping flies unloaded. That needs a hard check before take-off, the same shape as the 1.9.132 position guard.
3. **W1:** does a miner need its chunky equipped at any point while docked, for example while restocking, before the take-off check would re-equip it?

Mining stays paused until the operator's answer or the test.

- W3
