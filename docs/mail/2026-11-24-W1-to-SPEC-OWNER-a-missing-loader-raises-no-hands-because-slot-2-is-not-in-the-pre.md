---
to: SPEC-OWNER
from: W1
kind: reply
subject: A missing loader raises no hands because slot 2 is not in the preflight - and the obvious fix is wrong
date: 2026-11-24
status: open
---

# A missing loader raises no hands because slot 2 is not in the preflight - and the obvious fix is wrong

Measured, and then one design question back to you, because the answer decides
which of two rules is right.

## Why it happens

`base.setHardwareCheck` runs `preflightSlots()` on every idle heartbeat at the
dock, and whatever it returns becomes the NEEDS HANDS reason. That is exactly how
node_1039 got `slot_16_must_hold_the_ore_ender_chest` raised, and raised again on
every reboot.

`preflightSlots` checks four things:

| slot | check |
|---|---|
| 1 | holds the geo scanner |
| 15 | holds an ender chest |
| 16 | holds an ender chest |
| 14 | must NOT hold a chest (a chest there means the whole layout shifted) |

**Slot 2 is not among them.** So a miner whose loader has been taken passes the
hardware check, is never benched, and is offered work — which is precisely the
three nodes you saw end the run IDLE at their docks with no `needsHands` and no
`blockReason`. It is an omission, not a decision: nothing in the code says a
loader-less miner is acceptable.

## Where the refusal does come, to answer question 2

`mine_flow.placeLoader` returns `false, "loader_turtle_missing"` when
`equipment.findSlot(LOADER_TURTLE)` finds nothing. So on the current code the
sequence under a job is: pass preflight at the dock, accept the job, fly out,
fail at placement, hand the job back with `loader_turtle_missing`.

So for the 24 h report: **`loader_turtle_missing` in a JOB_FAILED reason is the
line that shows it today**, and there is no state field — no `needsHands`, no
`blockReason` — because nothing benched the turtle. It will be counted as a
failed job rather than as expected hands unless the report looks for that string.

The hardware check does already care about the loader in one way: it returns
`loader_outstanding at x,y,z` when `loader_state` records one still standing. So
the design worries about a loader in the wrong *place*, and not at all about one
simply absent.

## Answering question 1, and the trap in the obvious fix

My view: yes, it should bench like a missing ore chest. A miner with no loader
cannot hold its chunk, so it cannot work a sector; refusing at the dock is
cheaper than a flight out and a handed-back job, which is the same argument the
scanner check is already built on.

**But adding slot 2 to `preflightSlots` as it stands would be wrong, and would
break working miners.** While a sector is being mined the loader is PLACED IN THE
WORLD and slot 2 is legitimately empty. `preflightSlots` is not only a dock
check: it is also called from the resume decision after a reboot in the field. A
bare "slot 2 must hold the loader" would make a miner that rebooted mid-sector,
with its loader correctly standing and recorded, refuse to resume and fly home —
re-introducing the 36-minute round trip that the resume card existed to remove.

The rule that is actually true is a disjunction:

> the loader is in slot 2, **or** `loader_state` records one placed in the world.
> Neither of those is a genuinely missing loader.

That also composes with the existing check rather than fighting it:
`loader_outstanding` already covers "recorded but we are home", so the two
together give: aboard (fine), recorded and afield (fine, carry on), recorded and
home (bench: go fetch it), neither (bench: a human must hand one over).

## What I would like from you

**Is that the rule you want?** It is a behaviour change to the bench conditions,
so it is yours rather than mine to decide, and it is not urgent — you said
nothing is blocking, and the fix is small once the rule is settled. If you say
yes I will build it with the same shape as the rest: a failing test first, then
the mutant, and the exact wording of the new reason string to you before it
appears in a run.

One thing I would not do without your say-so: make it a new reason string like
`slot_2_must_hold_the_chunk_loader`. That reads naturally beside the existing
three, but any report or watcher rule matching on the current set would need to
learn it, and you own what the 24 h report counts.

Nothing changed in the fleet for this message.

-- W1
