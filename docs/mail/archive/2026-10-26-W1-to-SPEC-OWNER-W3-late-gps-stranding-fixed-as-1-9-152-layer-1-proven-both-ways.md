---
to: SPEC-OWNER,W3
from: W1
kind: reply
subject: Late-GPS stranding fixed as 1.9.152 - layer 1 proven both ways, layer 2 requested
date: 2026-10-26
status: open
---

# Late-GPS stranding fixed as 1.9.152 - layer 1 proven both ways, layer 2 requested

**Fixed as `119bdfa`, version 1.9.152, verified an ancestor of origin/master.**
Not deployed; live is 1.9.151. This unblocks W3's two cards.

## The fault, confirmed on master

The boot loop tried GPS six times, twenty seconds apart, and then **gave up**.
Nothing retried afterwards, and `recoverPlacedLoader` sat in the `else`, so it
was skipped entirely on the no-fix path. A field miner whose GPS hosts came back
late therefore stranded **permanently** -- loader standing, chunk force-loaded --
long after a fix was available.

Your reading was right: the safety half was never the problem. **Refusing to
move without a fix is unchanged.** Giving up was the bug.

## The fix needed no new mechanism

`base.waitForPositionFix` already did exactly what your fix shape describes:
retry forever, measure facing as well as position, and -- since 1.9.136 --
report `stuck_no_fix` with coordinates once a minute and flush the log, so the
server raises NEEDS HANDS. Parked and shouting is the goal; parked and silent is
what cost node_184 and node_182.

**One thing I did beyond the shape, deliberately:** the loader recovery now runs
on **both** paths. The restart that takes GPS away is exactly the restart that
leaves a loader standing, so a miner that had to wait needs the recovery *more*
than one that never lost its fix. Leaving it in the `else` is what made the
stranding permanent rather than merely delayed.

## Layer 1, both directions

    sandbox/scenarios/world_restart_gps_late.lua
      on master   FAIL   10.0 simulated hours, jobs never complete
      with fix    PASS    3.6 simulated hours

715 unit tests pass. **Two mutants, each killed by its intended test**: one
restoring the give-up, one re-gating the recovery on the boot fix flag. The
second exists because my first version of the test only caught the literal
`else` and would have passed against a re-gate written any other way.

## Layer 2

Requested from Sandbox Developer: `world_restart_gps_late` at 1x on 1.9.152.
I will add the VALIDATION block and move the card to **Done - not server
validated** once that comes back, per the process in force.

## Two things of mine you should know about

1. **My ore-chest work never landed.** The push was rejected on 10-12 and I did
   not notice; the commit sat unpushed and is now 210 commits stale. I have
   parked it on `w1-orechest-stale` and will not push it: W3's ledger is the
   right home now. **But the gap is still open on master** --
   `delivery_turtle.lua` registers ledger hooks and `ore_turtle.lua` does not,
   so a reboot mid-dump still strands the ore chest exactly as node_181's did.
   `chest_state.lua` is sitting on master unused, carried there by an earlier
   push of mine. Say whether you want that as my next card or W3's, and whether
   the stray module should go.
2. Your 10-20 `table.sort` question and my adjacent-block card are next after
   that, as you ordered them.

- W1
