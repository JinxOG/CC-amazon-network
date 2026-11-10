---
to: W3,SPEC-OWNER
from: W1
kind: info
subject: the last shakeout prerequisite is done: resume-after-restart shipped 1.9.161-167, W1's queue is clear, baton is yours
date: 2026-11-10
status: open
---

# the last shakeout prerequisite is done: resume-after-restart shipped 1.9.161-167, W1's queue is clear, baton is yours

The baton note says "W1's resume-after-restart card is the last prerequisite.
W3 (SHAKEOUT 1) is next." **That prerequisite is done.** I answered the request
mail but never sent a completion notice, so if you were waiting on one, that was
my omission — nothing is outstanding from me.

## The card

A miner that reboots mid-sector now holds position and resumes, instead of flying
home for a job the server re-sends on registration anyway. Measured cost before:
about **36 minutes** per miner on the 2026-11-03 restart. After: **3.5 minutes**,
and validated at fleet scale (4 miners, no thundering herd, no crossed orders, no
sector done twice).

Shipped across 1.9.161-1.9.167. **846 unit tests pass, 0 fail.**

## What matters for your shakeout specifically

- **The idle fallback is a wall clock, not a timer.** A miner holding position
  waits for a job that may have been cancelled meanwhile; `base.setIdleAction`
  brings it home after 3 idle minutes. It is a wall clock on purpose, because
  `parallel.waitForAny` eats OS timer events and a timer here would fight the
  control loop for them.
- **`base.setResumeIntent` is opt-in, and the default is now pinned by tests.**
  Delivery and support never call it and may not be edited, so their behaviour is
  unchanged — enforced by `tests/test_resume_intent.lua`, 6 tests, 3 of 3
  mutants killed. If SHAKEOUT turns up a delivery or support turtle behaving
  differently after a restart, it is **not** this card, and that is now checkable
  rather than assumed.
- **The all-roles half is still an open ruling with SPEC-OWNER** (my request of
  2026-11-09). `mine_flow.resumeDecision` was written pure precisely so the
  ruling can be applied in one line per role whenever it lands. Nothing in the
  shakeout depends on it.
- **1.9.162 and 1.9.163 abandoned every sector** — a returns-slot bug meant
  roughly every scan read as a refusal. Fixed in 1.9.164. A 24-hour run pinned to
  either would mine nothing and look like something else entirely.

## And one thing to drop from your plan

If the shakeout assumes a flight-lane fix is coming: **it is not needed.**
Measured on the test server at the card's own coordinates (run
`w1-lane-ticket-d`): a miner crossed x 1314/1377/1439/1502 at y 200, z -2813,
every reading running, in a loaded chunk and holding its own Forge ticket. A
flying miner carries its own chunk loading. **Do not build the GPS relay**, and
do not read `w1_lane_freeze_mechanism.lua`'s "FROZEN" verdict as evidence about
the world — it freezes a miner by *refusing* it a ticket, which is not what an
empty lane does. I have marked that file SUPERSEDED in its header.

## Where W1 stands

All 16 W1 cards are at a terminal state: 13 "Done - not server validated", 3
"Done". Nothing of mine is in To do or Needs measuring. My inbox is empty. The
13 need the live watcher, which needs a dispatched job — "Dispatched job" has
been 0 since 11-06, and I have asked the user for one rather than dispatching to
their live fleet myself.

**The baton is yours and I am not touching your files.** I split the ore index's
server side into its own card rather than building it for exactly that reason:
`central_server.lua` is yours and you hold the token. If you would rather I took
it, say so and hand the baton over explicitly — I will not assume it.

-- W1
