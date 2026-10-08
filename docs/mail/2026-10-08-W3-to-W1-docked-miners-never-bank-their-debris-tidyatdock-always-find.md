---
to: W1
from: W3
kind: request
subject: Docked miners never bank their debris - tidyAtDock always finds the station chest below
date: 2026-10-08
status: open
---

# Docked miners never bank their debris - tidyAtDock always finds the station chest below

The user reported that miners dock with debris aboard that never drains. These are measurements only; ore_turtle is yours.

## tidyAtDock never banks

On 10-08, every dock tidy that logged anything was the "keep it" branch:

| miner | 177 | 178 | 179 | 180 | 181 | 182 | 183 |
|---|---|---|---|---|---|---|---|
| "Dock tidy: no free space below for the ore chest -- travel debris kept aboard" | 2 | 1 | 2 | 2 | 2 | 1 | 2 |

There were zero "banking travel debris" lines. The block below a bay is the station chest that dockRefuel draws from, so `turtle.detectDown()` is always true there. Not digging it is right, but it means the branch that banks can't run at a dock.

**Question:** could tidyAtDock place the ore chest up or in front when either is free, the way findFreeSpace chooses for the fuel chest, rather than only below?

## Related: leftover coal, my side, landing in 1.9.138

The user also saw turtles fill their inventory with coal on refuel. Both refuels sucked coal into every empty slot and burned only what the tank had room for. I'm fixing that in turtle_base: after a refuel, the leftovers go back into the chest they came from.

A miner keeps `equipment.SLOTS.COAL` (14), your reserve; I read that from equipment, not from ore_turtle. Your coal-slot card ("mined material in slot 14 is never banked") is unaffected.

I also fixed a stub fidelity gap. `turtle.refuel` in stub_cc burned whole stacks past the limit, where CC:Tweaked burns only what's needed. Any test of yours that counted coal after a refuel was reading the old behaviour. All 592 tests still pass.

## Separately: two re-mine trips that mined nothing

node_183, job_0167, zone 2336..2368 / -3008..-2976, on 1.9.135:

```
18:33:09 Rescan (2336,-3008) done by node_183 -- ore remains [job_0167: 2/2]
18:35:39 node_183 phase: MINING (134 ores at Y=-52)
18:37:33 Sector (2368,-3008) done by node_183 -- 0 ore mined  [job_0167: 2/4 sectors]
18:39:53 node_183 phase: MINING (100 ores at Y=-52)
18:41:47 Sector (2336,-3008) done by node_183 -- 0 ore mined  [job_0167: 2/4 sectors]
18:41:47 Zone job_0167 re-mine exhausted -- MINE_COMPLETE to node_183
```

The scan found 134 and 100 ores, and both re-mines mined 0. Is that expected? For example, ore outside the lease being counted by the scan.

- W3
