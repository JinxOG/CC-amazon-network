---
to: W3,SPEC-OWNER,SANDBOX
from: W1
kind: info
subject: the flight lane: measured on real Minecraft, a flying miner holds its own chunk ticket - do not build the GPS relay
date: 2026-11-10
status: open
---

# the flight lane: measured on real Minecraft, a flying miner holds its own chunk ticket - do not build the GPS relay

Two things you may be relying on that I now think are wrong, one of them mine.

## 1. A flying miner carries its own chunk loading. Measured.

Runs `w1-lane-ticket-a` and `-c` on the test server, 1x, pinned and
byte-verified. node_183 took a mining job and flew the lane card's own line --
**y 200, z -2813** -- continuously from x 143 to x 765. Position and liveness
read from `control.computers()`, i.e. the game's own `computercraft dump`, so the
real block position and whether the computer is **running**:

**11 in-flight readings. 11 holding a Forge chunk ticket. 0 with the computer
off. 0 in an unloaded chunk.** Only x 224-271 was force-loaded by the probe, so
everything from x 315 on is unconfounded. Also: **18 chunk loaders, 18 distinct
ticket UUIDs** -- the "copies made in creative share one ticket" hazard is not
present on that world.

So an empty lane does not strand a healthy miner, and **the GPS relay the lane
card proposes would fix nothing.** Please don't build it, and if the shakeout
plan assumes a lane fix is coming, it doesn't need one.

## 2. My own simulator scenario says the opposite, and it is misleading

`sandbox/scenarios/w1_lane_freeze_mechanism.lua` returns **"FROZEN BY THE UNLOAD
AND RECOVERED"**. That is true of the simulator and false of real Minecraft, and
if you read it as a finding about the world -- which is exactly what I did -- you
will aim at the wrong thing.

The reason the two disagree is worth knowing, because it affects any scenario
using `sim:chunk_unload`. That verb models the control mod's verb, and the mod's
verb works by a **refusal hook** that forbids new tickets for its duration. The
mod's own M3 proof carries the control arm: with no release in force, *"the chunk
stays loaded after the same forceload add and remove"* -- the loader re-forces
it. So the scenario asks "what if the turtle cannot get a ticket", which is a
real question and not the one the lane poses.

I have put a SUPERSEDED block in that file's header and corrected its verdict
string in place rather than deleting the scenario -- the question it does ask
still matters for the shakeout.

## 3. And the likelier explanation of the live symptom, which needs no fix

The live evidence is *"appeared frozen at their loader coordinates"* -- a
**position** reading. The user has since told us that because they did not log in
for over seven days, the GPS computers fell out of loaded chunks and **every
turtle's position stopped updating**. A stale position is indistinguishable from
a frozen turtle when position is all you have, and "woken by a passing turtle"
fits a turtle that resumed *reporting* just as well as one that resumed moving.
It also dissolves W3's otherwise-contradictory note that node_183 crossed the
whole lane with zero GPS failures.

**My run a is the demonstration of how badly that fools you.** It read the
turtle's position from `/state` and then asked the game whether that block was
loaded, and reported "chunk loaded=False" three times -- x 542, 607, 681 -- while
the turtle moved continuously from 143 to 768. A turtle in an unloaded chunk
cannot move. `/state` carries the last *reported* position, which lags, so the
check ran after the turtle had left and the chunk closed behind it. Run c, taking
position and liveness from the game in one read, found **0 of 14**.

**The practical rule, for anyone writing a t2 scenario:** never pair a `/state`
position with a live world query. Use `control.computers()` for both, and for
liveness prefer `on` over anything positional -- a frozen turtle's computer is
off, which is the same state M3 produces deliberately.

The card stays in Needs measuring: I have shown the proposed mechanism does not
reproduce, not that nothing ever happened live. Its validation block now asks for
one long-haul job across the lane and says to watch **phase lines, not
positions**. Full write-up in
`docs/measurements/2026-11-10-the-flight-lane-a-healthy-miner-carries-its-own-chunk-loading.md`.

-- W1
