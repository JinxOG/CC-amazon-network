---
to: W1
from: SPEC-OWNER
kind: request
subject: You hold the baton: resume the job after a restart instead of flying home (a shakeout prerequisite)
date: 2026-11-09
status: answered
---

# You hold the baton: resume the job after a restart instead of flying home (a shakeout prerequisite)

The user handed you the baton on 2026-11-09. W5 finished the bridge slow-push card (eee8bc1: the 143 s
pushes were the host starving the bridge process, not the bridge; the bridge now reports its own timer lag).

## Your card

**"After a restart, turtles resume the job where they stand instead of flying home (36 min lost per miner
today)"** on the board, owner W1. The card body holds the measurement, the six build points, and the
WORKED IF / FAILED IF tests. Read it first; this mail only adds context.

## Why it matters now

It is a prerequisite for the shakeout stress test (spec `docs/superpowers/specs/2026-11-09-shakeout-stress-test-design.md`,
approved by the user 2026-11-09; plan `docs/superpowers/plans/2026-11-09-shakeout-stress-test.md`, Part 0).
That run injects world restarts and server crashes into 128 working miners for 24 hours. Every miner that
flies home after each one floods the base and the ATC, and eats the run's working time.

## Things already settled

- **Never act on a journaled facing.** Measure first. See W3's fix 1bd4ee3 (the boot check compares the
  journal with the facing the turtle booted with); build on that check, do not write a second one.
- **All roles.** Safeguards are built once for every role (the user's standing rule). delivery_turtle.lua and
  support_turtle.lua are frozen, so the shared logic goes in turtle_base.lua. If you find a frozen-file edit is
  truly needed, ask me for a ruling before making it.
- **File ownership (my ruling).** turtle_base.lua and ore_turtle.lua's boot recovery belong to W3's stream.
  W3 is asleep and only the baton holder works, so you may edit them for this card. Say which functions
  you changed in your done mail so W3 can read them before SHAKEOUT 1.
- **Live tests are miners only** (the user, 2026-10-16). Delivery and support are proven by sim + T2 alone.
- **No live deploys** (the user, since 2026-10-28). Your cards finish at "Done - not server validated"; the
  watcher validates later.
- **The ATC computer exists now** (atc.lua). A miner that resumes in the field never touches the base, so it
  should not need a grant; one that must go home asks for one as usual.
- The streamlined cycle in BATON.md applies: you write and run both layers yourself, no relaying.

## When you are done

Move the card, then one mail to SPEC-OWNER with the result and anything you could not finish. Then stop;
the baton goes to W3 next (SHAKEOUT 1, per-bay turtle types) on the user's say-so.
