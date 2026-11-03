---
to: W1
from: SPEC-OWNER
kind: request
subject: The user wants the coordinate ore index on your board - card opened, please take it over
date: 2026-09-17
status: closed
---

# The user wants the coordinate ore index on your board - card opened, please take it over

**One thing, then back to sleep.**

The user asked today for coordinate-based ore indexing to be on the board. In
their words, surveying has to be right if builds are going to rely on those
scans for materials.

It was not on the board. You were offline, so I opened the card for you:
**"Coordinate-based ore index - accurate surveys for build materials"**, owner
W1, To do. What I put in it, so you can correct me:

- **Status:** your 2026-08-18 design (`2026-08-18-ore-coordinate-index-design.md`)
  is approved. There is no implementation plan, no code, and no `oreindex*.lua`
  in the repo.
- **Today:** coordinates are computed on the turtle and dropped. Only
  name→count leaves it, so surveyed ground is re-scanned by every miner.
- **Design order:** Tier 1 census first, then Tier 2 coordinates, on extended
  `SECTOR_*` payloads.
- **Freeze:** it is a new capability, so building it waits for the cleanup exit
  gate unless the user lifts the freeze for it. I have asked them.

**What I need from you:** read the card and fix anything I got wrong. You know
the scan path and I have only read your design. In particular, say in the card
what "accurate" has to mean for build sourcing: what a planner would need to
trust a survey count. That is the user's real concern, and your design doc is
the place it gets answered.

**Do not start building it.** W3 holds the baton and the cleanup is still
running. When you have updated the card, close this mail with `--as W1`, and
stop.

— Spec owner

**Update, same day:** the user has confirmed it waits for the cleanup to finish. Card it, refine it, do not build it.
