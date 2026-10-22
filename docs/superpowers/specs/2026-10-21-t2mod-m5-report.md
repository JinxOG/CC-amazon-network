# T2 control mod - M5 report: peripheral stall and fail

Date: 2026-10-21. Forge 1.20.1-47.4.10 (matches live), CC:Tweaked 1.120.2, Advanced Peripherals 0.7.46r, mod t2control 0.1.0.

## What M5 adds

- `/t2 peripheral stall <type> <extra_ms> <duration_s>`: every call a program makes to a peripheral of that TYPE (the name it finds it by, such as `rsBridge`) takes `extra_ms` longer.
- `/t2 peripheral fail <type> <duration_s>`: every such call raises an error (`T2 fault: <type> is not reachable`).
- `/t2 peripheral clear`, `/t2 peripheral status` (rules active, calls stalled, calls failed).
- Python: `rs_stall(t, dur, seconds)` and `rs_offline(t, dur)` (the simulator's names and meaning), and the generic `peripheral_stall` / `peripheral_fail` / `peripheral_clear`. Times in game ms, as for the other faults. Every rule is in the interventions log and ends by itself.

## The hook point (written into section 4 of the spec)

`dan200.computercraft.core.apis.PeripheralAPI$PeripheralWrapper#call`, a private method that every peripheral call from a program goes through, on that computer's own thread. One generic point, so it covers every kind of peripheral and does not depend on Advanced Peripherals. A stall sleeps on the computer's thread before the call runs: the program sees the call take longer, and the server tick and other computers are not touched. (Stalls were proven up to 2.5 s. CC has its own limit on how long a program may run without yielding; whether a long sleep inside a call counts against it was not tested, so treat stalls above a few seconds as unproven.)

## Proof, both ways (run m5-a, `prove_mod.py m5`, 9 of 9), on the real warehouse

| claim | evidence |
|---|---|
| baseline | the warehouse probes its RS bridge every 10 s; each `listItems` takes 59, 64, 60 ms (real RS network, 495 kinds of item) |
| fail | for 45 s the warehouse logs `RS listItems failed: T2 fault: rsBridge is not reachable` (4 lines) and gets no listing |
| fail ends by itself | 3 good probes afterwards, 0 failures |
| stall 1.5 s | every probe during it reads 1559, 1507, 1556, 1555, 1520 ms |
| stall ends by itself | 56, 57 ms afterwards |
| another type | a stall on a type that does not exist changes nothing: 56, 55, 55 ms |
| counted | the mod counted 5 stalled and 4 failed calls |
| the fleet's own rule | a 2.5 s stall: the warehouse itself logs `RS probe: listItems 2517ms ... slow, next in 600s`, so its slow-reading back-off is now reproducible on the real server |
| logged | `peripheral_fail` once and `peripheral_stall` three times in interventions.jsonl |

Unit tests: `PeripheralFaultsTest` (4): nothing by default, a stall applies to its type only and ends by itself, a failure wins over a stall and is counted, clear.

## Worth knowing

- A real RS `listItems` on this world takes about 60 ms. The simulator's `rs_stall` models the same call; this is now a measured number to compare it against.
- Not covered: stalling by game ticks instead of real time (the sleep is real milliseconds, so at a raised tick rate a stall spans more game time than at 20 tps, like every other real-clock timer here); per-method rules (the fault applies to all methods of the type).
