# The flight lane: a healthy miner carries its own chunk loading

W1, 2026-11-10. Runs `w1-lane-ticket-a` and `w1-lane-ticket-c` on the local test
server (real Forge 1.20.1-47.4.10, 230 mods, 1x, fleet pinned and byte-verified).
Scenario: `sandbox/t2/scenarios/w1_lane_ticket_probe.py`.

Card: "Miners lose GPS and freeze on one stretch of the flight lane
(x ~1300-1550, y 200, z -2813)".

## What the card proposes, and why it needed checking

The card reads the symptom as a GPS coverage gap over one stretch of sky and
proposes a relay part-way along, or a different route. W3's update of 2026-10-20
points elsewhere: two frozen miners were each **woken by a passing turtle**
(node_177 on 10-15, node_178 on 10-20), and node_183 crossed the whole lane both
ways that day with **zero** GPS failures. Being woken by a passer is what chunk
loading looks like, not what a radio dead spot looks like.

The simulator agreed with the chunk theory — `w1_lane_freeze_mechanism.lua`
returns "FROZEN BY THE UNLOAD AND RECOVERED". That verdict is the simulator's
**model** of chunk loading answering a question about the real one, and reading
the control mod's own M3 proof shows the gap: its `chunk unload` works by a
**refusal hook** that forbids new tickets, and M3's control arm records that with
no release in force "the chunk stays loaded after the same forceload add and
remove" — the loader re-forced it. The simulator was answering "what if the
turtle cannot get a ticket", which is not what an empty lane does.

## Measured

A mining job was dispatched to (1920,-2624) and node_183 flew the lane. Position
and liveness read from `control.computers()` — the game's own `computercraft
dump`, so the real block position and whether the computer is **running**.

| x | y | z | computer running | chunk loaded | holds a ticket | moved |
|---|---|---|---|---|---|---|
| 143 | 149 | -2813 | yes | yes | yes | — |
| 165 | 200 | -2813 | yes | yes | yes | yes |
| 240 | 200 | -2813 | yes | yes | yes | yes |
| 315 | 200 | -2813 | yes | yes | yes | yes |
| 390 | 200 | -2813 | yes | yes | yes | yes |
| 465 | 200 | -2813 | yes | yes | yes | yes |
| 540 | 200 | -2813 | yes | yes | yes | yes |
| 615 | 200 | -2813 | yes | yes | yes | yes |
| 690 | 200 | -2813 | yes | yes | yes | yes |
| 765 | 200 | -2813 | yes | yes | yes | yes |

- **11 in-flight readings, 11 holding a chunk ticket, 0 with the computer off, 0
  in an unloaded chunk.** The miner flew the card's own altitude and z line,
  continuously, from x 143 to x 765.
- Only x 224-271 was force-loaded by the probe, so every reading from x 315
  onwards is unconfounded by that.
- **18 chunk loaders, 18 distinct Forge ticket UUIDs — none shared.** The
  "copies made in creative share one ticket, and only the last placed holds it"
  hazard is not present on this world.

## Run d: the stretch the card actually names

Runs a and c both stopped sampling at 14 samples with the miner still at x 765
and climbing east. **The card is about x ~1300-1550.** So both measured the
*approach* to the lane and never the lane, and I wrote the conclusion up as
though the question were settled. Run d watches until the miner is past x 1600
instead of until a sample count.

| x | y | z | computer running | chunk loaded | holds a ticket |
|---|---|---|---|---|---|
| 1314 | 200 | -2813 | yes | yes | yes |
| 1377 | 200 | -2813 | yes | yes | yes |
| 1439 | 200 | -2813 | yes | yes | yes |
| 1502 | 200 | -2813 | yes | yes | yes |

30 samples, 27 of them in flight, **0 with the computer off, 0 in an unloaded
chunk, 27 of 27 holding a Forge ticket**, furthest x reached **1627**. Four
readings fall inside x 1300-1550, and all four are clean.

The probe now reports **INCONCLUSIVE ABOUT THIS CARD** if a run never reaches
that stretch, so the gap that let runs a and c read as a pass cannot recur.

## Conclusion

**A healthy miner carries its own chunk loading, and an empty lane alone does not
strand it — including across x 1300-1550, the stretch this card names.** Both the card's GPS framing and the chunk-unloading theory fail to
reproduce on real Minecraft. **A GPS relay on the lane would fix nothing, and
should not be built on the strength of this card.**

For the live freezes to have happened, the *ticket itself* must have failed, or
the turtles were never frozen at all.

## The second explanation, which now looks the more likely one

The live symptom was read as "appeared frozen at their loader coordinates" — a
**position** reading. The user has since said that because they did not log in
for over seven days, the GPS computers fell out of loaded chunks and **every
turtle's position stopped updating**. A stale position is indistinguishable from
a frozen turtle when position is all you have, and "woken by a passing turtle"
fits a turtle that resumed *reporting* just as well as one that resumed moving.

**My own run a demonstrates how easily this fools you.** It took the turtle's
position from the bridge's `/state` and then asked the game whether that block
was loaded, and reported "chunk loaded=False" three times — at x 542, 607 and 681
— while the turtle moved continuously from 143 to 768. A turtle in an unloaded
chunk cannot move. `/state` carries the last *reported* position, which lags, so
the check ran after the turtle had left and the chunk had closed behind it. Run c,
reading position and liveness from the game in one go, found **0 of 14**. Three
confident false positives from exactly the class of evidence the card rests on.

## What would settle it

A single live job across the lane now that the GPS chunks are loaded again.
Watch, per miner: the computer's own phase lines (a frozen turtle reports
nothing) rather than its position, and whether any `gps` failure line appears at
all. The card's validation block has been rewritten to ask for that.

Not deployed, not changed: this measurement altered no fleet code.
