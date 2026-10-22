# T2 control mod - M6 report: pause and step

Date: 2026-10-21. Forge 1.20.1-47.4.10 (matches live), CC:Tweaked 1.120.2, Advanced Peripherals 0.7.46r, mod t2control 0.1.0.

## What M6 adds

- `/t2 pause`: the server stops running game ticks. No world, no computers, no timers, no radio.
- `/t2 step <ticks>`: lets exactly that many ticks run, then pauses again (steps add up; a step on a running server means "pause after these").
- `/t2 resume`: runs normally again and forgets any steps still owed.
- Python: `pause()`, `resume()`, `step(ticks)`. Console commands (RCON) keep working while paused, so a script can pause, look at the world, change something, and step.

How: a tick that is not allowed to run is cancelled at the start of `MinecraftServer#tickServer`, before anything in it happens (the tick counter and the game clock do not move either).

## Proof, both ways (run m6-a, `prove_mod.py m6`, 9 of 9)

| claim | evidence |
|---|---|
| running | the game clock advances 100 ticks in 5 s |
| paused | the game clock is identical before and after 12 s; the probe turtle's file gets no new row (17 -> 17); the console and `/t2 status` still answer |
| step 10 | exactly 10 ticks ran (clock +10), then it stayed paused |
| steps add up | two steps of 7 give exactly +14 |
| step 200 | exactly +200 ticks (10 game seconds); the probe turtle writes 11 rows in them (one per game second) |
| resume | 100 ticks in 5 s again |
| computers are not restarted | the probe turtle's own uptime counted 1.0 .. 38.0 with no reset across the pause and steps |
| logged | pause, four steps, resume in interventions.jsonl |

Unit tests: `PauseControlTest` (5).

## The clock caveat (read this before using pause in a scenario)

While paused, the game clock stands still but **the real clock does not**. Anything a program measures with `os.epoch("utc")` (the fleet's own deadlines and timeouts, the warehouse's probe cadence, the server's pacing) keeps running. After a long pause the fleet may see "everything took 10 minutes" and react, exactly as at a raised tick rate but in the other direction. Pausing is for inspecting and for stepping through short sequences, not for suspending a long scenario and expecting the fleet not to notice.

## Not covered

Pausing across a server save or a crash (the pause state is not saved; a restarted server runs normally). Pause does not stop the bridge, which keeps its own real-time clock.
