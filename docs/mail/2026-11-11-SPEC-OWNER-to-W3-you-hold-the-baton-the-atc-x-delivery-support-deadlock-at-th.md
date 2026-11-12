---
to: W3
from: SPEC-OWNER
kind: request
subject: You hold the baton: the ATC x delivery/support deadlock at the dispatch hole (shakeout blocker), then the NEEDS HANDS 'facing unknown' card
date: 2026-11-11
status: open
---

# You hold the baton: the ATC x delivery/support deadlock at the dispatch hole (shakeout blocker), then the NEEDS HANDS 'facing unknown' card

The user handed you the baton on 2026-11-11.

## Card 1 (TOP PRIORITY, shakeout blocker)

The board card **"TOP PRIORITY (shakeout blocker) - ATC x delivery/support deadlock at the dispatch hole"** holds the measurements, the run folders, and its WORKED IF / FAILED IF tests. Read it first.

In short: the ATC's fairness rule keeps a support out behind an older waiting delivery. Its own delivery then gives up and leaves. The support goes down the dispatch hole anyway, ends at "Delivery ascending - holding position", and holds DH for the rest of the run. Waits reached 19,353 s.

It is on master's code too. Base d4b2ae8 hits it, and none of atc.lua, support_turtle.lua, delivery_turtle.lua, turtle_base.lua or protocol.lua changed in the shakeout build.

**Reproduce:** `sandbox/scenarios/w3_bay_types150.lua` (SANDBOX_NO_TRACE=1). It now has a "no wait to be let in over 900 s" check. The same 6 turtles stick on every run.

**Fix shape is yours to choose.** The sim implementer suggested two options, for you to judge, not as a ruling:
- skip the fairness check when the turtle's partner is already let in;
- end the support's follow when its delivery has already left the hole.

**Frozen files:** delivery_turtle.lua and support_turtle.lua are frozen. If the fix truly needs one of them, mail me the exact change and why before editing. Prefer atc.lua or turtle_base.lua if either can carry it. Whatever you build must work for every role (the user's standing rule).

## Card 2, if time allows

**"Healthy docked turtles end with NEEDS HANDS 'facing unknown' set (146 of 150 in passing ATC sims)".** It is also on the board with measurements. It may be a fleet bug or a simulator artefact; tell me which, with evidence.

## What changed on master while you were asleep (the shakeout build, b8d5ed0)

These changes are in files you own, so read them before you start:

- **waypoints.lua**
  - `CFG.BAY_TYPES`: worker bay 1 DELIVERY, support bay 1 SUPPORT, the other 8 bays MINER.
  - `W.docks.MINER` and `W.dockTypeFor(role)`.
  - dock_assignments.dat is now keyed by position (`byPos`). The legacy DELIVERY and SUPPORT lists are still written in their old side-index meaning, so a rollback keeps every turtle on its dock.
- **central_server.lua** (registry.register and heartbeats)
  - Docks are now picked by type.
  - A misplaced turtle is moved once ("Dock moved: ..."). Its old cell stays reserved until it is seen off it.
  - An idle moved turtle gets a REBOOT, re-sent on heartbeat every 60 s, up to 5 times, then released with a WARN.
  - releaseLostTurtle, REMOVE and assignDockAt now cover every dock pool.
  - Locals in server.run: 195 of 200.
- **sandbox/world/synth.lua** knows MINER docks. The four old 150-turtle scenarios now use 16 delivery, 16 support and 118 miners.

Tests are in tests/test_bay_types.lua and tests/test_bay_types_server.lua. The ledger with every ruling is in the head-engineer worktree, git-ignored: .superpowers/sdd/2026-11-09-shakeout-stress-test/progress.md.

## Rules for this baton (unchanged)

- You write and run both layers yourself: the simulator, then T2 with sandbox/t2/scenario.py. No relaying.
- No live deploys. Cards finish at "Done - not server validated".
- Never pattern-kill processes. Every T2 bridge is `node server.js`, so kill by verified PID only.
- Close any T2 server, bridge or sim you start when you finish. The user asked that nothing be left running.

## When you are done

Move the cards and send one mail to SPEC-OWNER with the results. Then stop. The baton comes back to me for the shakeout's T2 proofs.
