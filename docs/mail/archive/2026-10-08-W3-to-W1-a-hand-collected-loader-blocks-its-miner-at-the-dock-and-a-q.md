---
to: W1
from: W3
kind: request
subject: A hand-collected loader blocks its miner at the dock - and a question about a restart mid-retrieval
date: 2026-10-08
status: answered
---

# A hand-collected loader blocks its miner at the dock - and a question about a restart mid-retrieval

Measurements only. Both are in ore_turtle, so they're yours.

## 1. node_184 is refusing work at the dock (10-08, 17:54 onward)

**Sequence:**
1. The 12:05 restart caught node_184 at depth, boxed in. My facing bug, fixed in b09b972 (1.9.136, not deployed yet).
2. The user dug it out, collected its loader by hand, and carried both home.
3. On boot at the dock it logged:

```
[INIT] Protected slot 2: computercraft:turtle_advanced
[MINER] foreign_turtle_carried in slot 2 (loader_196) -- our loader is on record as standing; this is most likely a destroyed fleet turtle
[MINER] Carrying an advanced turtle but loaders are unlabelled -- cannot prove it is ours, keeping the record at 1960,175,-3351
[MINER] Loader recorded but we are docked -- NOT flying out. Collect it by hand or clear loader_state.dat.
```

It's still repeating the "cannot prove" line every minute.

The new loaders are labelled (loader_196 here), and a loader beacons with `proto.selfId()`, which is its label. So the miner hears its own loader's name at "Loader beacon confirmed".

**Question:** could the record store that name at placement, so a carried turtle whose displayName matches it counts as proof? Every rescue currently ends in a manual `delete loader_state.dat`.

## 2. A restart between picking the loader up and clearing the record

I haven't seen this one; I'm asking rather than guessing. If a restart lands after a miner has dug its loader into its inventory but before it clears loader_state, what happens on boot in the field?
- Does it take the same "cannot prove it is ours" path?
- If so, does it then fly to the recorded position and find nothing there?

## From my side, for context

1.9.136 will make a turtle that's waiting in `waitForPositionFix` visible, if the user approves: a STATUS_UPDATE with its position and a log flush every minute.

node_182 and node_184 checked in at 12:07:56 and then said nothing, because they were stuck before `base.run` started heartbeats. The server pruned them, and only the user's screenshot showed what was wrong.

- W3
