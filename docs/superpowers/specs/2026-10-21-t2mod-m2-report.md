# T2 control mod - M2 report: radio loss and latency

Date: 2026-10-21. Forge 1.20.1-47.4.10 (matches live), CC:Tweaked 1.120.2, Advanced Peripherals 0.7.46r, mod t2control 0.1.0.

## What M2 adds

Two faults on the radio, both off until asked for, both with a duration in GAME time so they expire by themselves:

- `/t2 radio loss <rate> <seconds> [channel n] [to id] [seed n]` - each packet that WOULD reach a program is thrown away with that chance.
- `/t2 radio latency <min_ms> <max_ms> <seconds> [channel n]` - each such packet is delivered later, in whole ticks (50 ms).
- `/t2 radio clear` removes every rule. Every rule is written to `interventions.jsonl`, so a run can show exactly what was done to it.

Python verbs (same names and arguments as the simulator): `radio_loss(t, dur, rate, channel, to, seed)`, `radio_latency(t, dur, ms, channel, max_ms, seed)`, `radio_clear()`.

How it works: the hook in `WirelessNetwork#tryTransmit` repeats CC's own range and channel test, so a packet that could not have reached anybody is never counted as "lost". Loss cancels the call; latency cancels it and calls the original method again later from the server tick (a flag stops a delayed packet being delayed twice). A packet whose receiver was removed while it waited is logged `dropped_receiver_gone`.

## Proof, both ways (run m2-a, `prove_mod.py m2`, 12 of 12)

| claim | evidence |
|---|---|
| no rules = no effect | added delay at most 1 ms |
| loss 1.0 on one channel | 19 lost lines, 0 reached the program; fleet traffic on channel 1 untouched (106 deliveries) |
| rule expires by itself | delivery resumes after the duration |
| loss 0.0 | 0 lost, 22 delivered |
| loss 0.5, seeded | 28 lost / 25 delivered; the set of messages in the log and the set the program saw are identical |
| latency 1000 ms | measured delays 1004-1014 ms; back to 0 after expiry |
| range unchanged | packets from 106 to 1466 blocks still delivered under range 0..1500 |
| receiver removed | 3 `dropped_receiver_gone` |
| interventions logged | yes; 0 log lines dropped |

Unit tests: `FaultsTest` (9) - zero rules do nothing, rate 1 and 0, same seed same decisions, channel and receiver filters, expiry by game time, whole-tick delays inside the range, due-order delivery, loss tried before latency, clear.

## First payoff: the acknowledgement-loss question on real Minecraft

Question: do idle ("parked") turtles on the old code lose about 9% of their heartbeats' acknowledgements, as the simulator reproduced for the code before 23f5a97 (T1: 9.08% before the fix, 0.03% after; live measured 11-18% parked)?

Run ack-old2: fleet code from `6cc2bae` (1.9.107, the commit before the fix), 16 turtles all parked, 4.02 game hours at 10x, control mod logging on.

- Result: **2.42% lost** (3747 acks for 3840 beats, 64 baseline lines; per turtle 1.25% to 3.75%, 240 beats each).
- So the real server on one PC does NOT reproduce the 11-18% seen live, and does not reproduce T1's 9%. The loss that is there (2.4%) is higher than the 1.06% a working miner shows live, so something is lost, but not the live mechanism.
- Evidence is thin: 240 beats per turtle. The turtles log a baseline line far less often at 10x than at 1x, because the log shipping is paced by real time. Do not read the per-turtle spread as signal.
- Plain reading: the live parked-turtle loss needs something the test server does not have (live has other players, other mods' radio, a busier server). The control mod can now ADD radio loss, which is the next lever, but choosing a rate to "match live" would be fitting, not measuring.

### Why this needed a new way to install old code

The real update path cannot reach this commit. The updater before 1.9.128 ignores the pinned commit and fetches master, so pinning to 1.9.107 made the server flip between two versions forever (it replaced protocol.lua with the old one, then the old updater pulled master's again). This is the "an updater cannot ship a module it does not know about" trap already in memory, seen from the other side: you cannot go back past the commit that taught the updater to take a commit.

New: `scenario.py --install <sha>` copies that commit's files onto every computer before the first boot (each .lua the computer already holds that exists at that commit, and startup.lua for its role). It is a file copy, not the update path, and the report says "copied from". For commits at or after 1.9.128 keep using `--pin`.

## Second scenario: five percent loss for a whole mining job

`radio_loss_5.py` is the port of the simulator's `radio_loss_5.lua`: same verb and arguments (5% loss from game time 0 for 12 hours), then the three-sector calibration job. Run rl5-a, 5x, 3.39 game hours, 2438 s real.

- The fault does what it says: 8722 of 175999 packets that would have reached a program were lost (4.96%).
- **The job failed.** `Job permanently failed: job_0206 (sector_setup_failed: placement_blocked)`; a sector was blacklisted after 4 failures; the job was handed from one miner to another three times. Checks: job completes FAIL, three sector lines FAIL (2).
- Control runs of the same job at similar speed with no fault (cmp-6x, new-6x): 0 "GPS locate failed" lines and 0 placement_blocked. With 5% loss: **174 "GPS locate failed" lines and 6 placement_blocked**. The miners fell back to dead-reckoned positions and then could not place their equipment where they thought they were.
- What this shows: on real CC, GPS needs several replies to one request, and a 5% loss rate is enough to make it fail often. Whether the simulator's version of this scenario passes because its GPS does not go through the lossy radio is not yet known; the simulator's passing result should not be read as confirmation until that is checked. This is for the Head Engineer: it is both a fidelity gap in T1 (if T1's GPS ignores loss) and a real fragility in the fleet (a miner that cannot locate itself should not place equipment on a guess).
- Evidence caveat: one run, one seed (the mod drew a seed and recorded it in interventions.jsonl).

## NOT STAGED (updated)

- Radio loss and latency: now supported. Still unsupported: chunk unload (M3), turtle move failures (M4), peripheral stall (M5), pause/step (M6).
- Citadel and Alex's Mobs left out at speed; five client-only jars; speed caveat (deadlines in real time get N times longer in game time); no exact replay.

## Addendum (2026-10-22): the same replay on current master

Run ack-new: fleet pinned (real update path) to `aa00793` = proto 1.9.150, same scenario (16 parked turtles, 4.03 game hours, 8.1x): **0.64% lost** (4173 acks of 4200 beats, 70 baseline lines).

| code | parked ack loss on real Minecraft | simulator (T1) |
|---|---|---|
| 1.9.107 (before the fix) | 2.42% | 9.08% |
| 1.9.150 (current master) | 0.64% | 0.03% |

The direction agrees with the simulator (the fix lowers the loss, by a factor of about 4) but the sizes do not: real Minecraft on one PC loses less before the fix and more after it than the simulator says. Same thin-evidence caveat as above (about 250 beats per turtle, one run each).
