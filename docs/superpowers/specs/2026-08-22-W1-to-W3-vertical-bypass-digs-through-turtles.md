# W1 → W3: the vertical bypass digs through turtles — one miner has destroyed another

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-22
**Severity:** **Critical — turtles are destroying each other. Recommend no further mine orders until this is resolved.**
**File:** `turtle_base.lua` (W3-owned; W1 has not touched it)
**Observed at:** server and full fleet on 1.9.34

---

## Observed — this part is not an inference

An in-world inventory check of `node_139` shows it carrying an item named
**"Advanced Ender Mining Turtle", Computer ID: 119**.

`node_119` is a **miner**, not a loader. It is absent from the server registry
entirely. It has not gone offline, or got lost, or stranded — **it has been mined,
and it is sitting in another miner's inventory as an item.**

`node_139`'s terminal at the time of the check:

```
[node_139][INFO] Descending through arrivals hole...
[node_139][INFO] Docked at bay 1 row B
[node_139][INFO] Refuelling at dock station...
[node_139][INFO] Dock refuel +38171 (now 100000/100000)
[MINER] Dock tidy: no free space below for the ore chest — travel debris kept aboard
[MINER] phase DOCKED
```

Its inventory is otherwise full of travel debris — coal blocks, cobble, mob drops,
assorted junk — consistent with a flight home that dug through whatever was in the
way. `node_119` is one of the things it dug through.

## The defect

`tryMove` gets this right. Line 620 checks `isTurtleBlock(dir)` before digging and
waits instead, for **every** direction including up and down:

```lua
if isTurtleBlock(dir) then
    -- Another turtle is in the way — wait, then try to route around it
    ...
else
    -- Static block (terrain, gravel, etc.) — dig it
```

**The bypass path it falls through to does not.** The chain:

| Step | Line | Behaviour |
|---|---|---|
| forward blocked by a turtle | 620 | correctly identified, waits |
| after ~3 s | 627–629 | calls `bypassForward()` |
| lateral bypass fails | 567–568 | calls `tryVertical(true)`, then `tryVertical(false)` |
| **`tryVertical` step 1** | **519** | **`if detectLayer() then digLayer() end`** |

Line 519 has a `detect` check and **no `isTurtleBlock` check**. `detect` returns
true for a turtle exactly as it does for stone. So the sequence is:

1. Notice correctly that a turtle is blocking us.
2. Decline to dig it.
3. Attempt to go around by digging vertically.
4. **Dig a different turtle instead.**

Lines 543, 544 and 551 — the return-to-level digs in steps 2 and 3 of the same
function — have the same shape and the same gap.

`isTurtleBlock` itself is fine (`data.name:find("turtle")` matches
`computercraft:turtle_advanced` whether the turtle is powered or placed as a
block). It is simply not consulted on these four calls.

## Why the arrivals hole makes this systematic

This is not a rare geometric accident. The arrivals hole is a **single-block
vertical chokepoint** (Invariant I), and returning miners queue in it. That queue
is a column of turtles stacked vertically.

A turtle in that column that cannot move forward will, by design, try to bypass by
digging **up or down** — which is precisely the axis the queue occupies. **The
chokepoint's geometry and the bypass's escape strategy are the same axis.** Every
concurrent return is an opportunity.

`node_139`'s log shows it descending through the arrivals hole immediately before
docking with node_119 aboard.

## Second unguarded site

`turtle_base.lua:1051–1060`, the "surrounded" fallback when deploying a chest:

```lua
logWarn("Surrounded — digging temporary refuel hole...")
if turtle.digDown() then ...
if turtle.digUp()   then ...
if turtle.dig()     then ...
```

Three raw digs, no `isTurtleBlock`, no `detect`. A turtle that finds itself
surrounded **at a dock** — where the things surrounding it are, by construction,
other docked turtles — will dig one of them. W1 did not see this fire in the
captured log (its distinctive warning line is absent), but the gap is real and it
sits in the most crowded part of the map.

## What this probably also explains

Loaders are placed at the miner's own travel altitude (`mine_flow.lua:333`,
`loader_state.record(tx, p.y, tz, ...)`), and miners fly at that same band. A
standing loader is a turtle block in a flight lane.

The repeated "miner lost its loader" reports — including two of four miners on one
job — have been investigated as *retrieval* failures. **They may never have been
retrieval failures at all.** A loader dug up by a passing miner is gone before its
owner returns for it, and the owner's retrieval then fails for reasons that look
like a mismatch or a missing beacon.

W1 raises this as a hypothesis, not a finding. But it fits the evidence better
than the retrieval explanations W1 has been shipping fixes against, and it would
mean several of those fixes were treating a symptom.

## Suggested fix

**Route every dig through one guarded helper.** There should be no raw
`turtle.dig`/`digUp`/`digDown` in movement code. Something like:

```lua
-- Never dig a turtle. Not in the bypass, not when surrounded, not anywhere.
-- Hardware loss is unrecoverable in a way terrain loss is not: the mined turtle
-- takes its ID, its files and its loader_state with it, and its placed loader is
-- orphaned permanently. Observed 2026-08-22 -- node_139 arrived at its dock
-- carrying node_119 as an item.
local function digGuarded(dir)
    if isTurtleBlock(dir) then return false, "would_dig_turtle" end
    return DIG[dir]()
end
```

Then make `tryVertical` fail cleanly rather than dig blind: if the layer above and
the layer below are both turtles, the correct outcome is to **keep waiting** — the
column is transient by definition, since everyone in it is trying to leave.

**And treat the arrivals hole as no-dig.** Inside the chokepoint the only thing a
dig can hit is a queue-mate or the structure. `returnToDockFromSky` already knows
when it is in the descent; a flag that forbids digging for its duration removes
the whole class.

## Cost of leaving it

A destroyed turtle is not a recoverable failure. It takes its computer ID, its
`role.txt`, its `loader_state.dat` and any carried hardware with it, and its placed
loader is stranded permanently with nothing left to reclaim it — `node_160` is
standing at 1160, 200, −2743 right now for exactly this reason.

It is also silent. The registry simply stops hearing from a turtle, which reads as
"offline" and gets pruned. **W1 spent this session diagnosing node_119 as a missing
turtle when it was an item in a slot.**

## Confirming which path did it

A checkable prediction, so this does not rest on inference. `bypassForward` logs on
success (lines 567–568):

```
Bypass: dug UP over blocker
Bypass: dug DOWN under blocker
```

If either appears in `node_139`'s terminal scrollback before the arrivals-hole
descent, the `tryVertical` path is confirmed. If neither does, the surrounded-dig
path at 1051 becomes the likely one and its warning line should be present instead.

**What is proven:** node_119 was destroyed by another turtle and recovered as an
item. **What is inferred:** which of the two unguarded paths did it. Both need
fixing regardless of the answer.

## Recovery

`node_119` is not lost. Placing the item back down restores the computer with its
ID, filesystem and role intact; it will boot, re-register, and `recoverPlacedLoader`
should send it after `node_160`. Worth placing it in a clear spot rather than back
in the dock row, and watching that first recovery.
