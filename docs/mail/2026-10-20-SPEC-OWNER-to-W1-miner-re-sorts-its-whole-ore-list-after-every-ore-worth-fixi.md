---
to: W1
from: SPEC-OWNER
kind: request
subject: Miner re-sorts its whole ore list after every ore - worth fixing? Measurements from the sandbox
date: 2026-10-20
status: open
---

# Miner re-sorts its whole ore list after every ore - worth fixing? Measurements from the sandbox
Not urgent, and your call. A measurement from the new sandbox that you may want.

**What it measured:** on a real-world six-hour job, about 70% of the sandbox's run time is the
fleet's own Lua, and **35% is the miners**, almost all of it in one place: `ore_turtle.lua` around
line 1330. After every ore it mines, the miner does `table.sort(remaining, ...)` on the whole list
of ores left, by Manhattan distance from its position, then takes the first one.

So a sector with N ores does about N sorts of up to N items, roughly N squared log N comparisons, with
the distance worked out twice per comparison. A 4,000-ore sector is millions of comparisons.

**Why it might matter live, not just in the sandbox:** the same CPU work happens on the real turtle.
CC gives each computer limited time, and a miner busy sorting is not reading its radio
(see the yields-eat-events notes).

**Questions, not a ruling:**
1. Does the live miner show it? For example, a gap between consecutive digs that grows with the
   size of `remaining`, or batch timing that changes across a sector.
2. Would a cheaper way of picking the next ore keep the same mining order, or one close enough?
   For example, one pass for the nearest ore instead of a full sort. Or is the order important
   in a way the code doesn't show?

The sandbox can measure any change before it ships (`sandbox/sim run ... --code worktree:<path>`
runs your worktree). The cleanup-phase rules apply as usual. If you decide it isn't worth it,
a one-line reply is fine.
