# T2 control mod, phase M1: radio log, event log, interventions log

Written 2026-10-21 by the sandbox builder. Spec: `2026-10-20-t2-control-mod-design.md`. Code: `sandbox/t2mod/` (`Logs`, `LogWriter`,
`T2Commands`, `mixin/WirelessNetworkMixin`, `mixin/ComputerExecutorMixin`, `mixin/ModemPeripheralAccessor`; 13 JUnit tests, all
passing); the Python side in `sandbox/t2/control.py` (`radio_log`, `events_log`, `t2_status`, `t2_lines`, `spawn_computer`),
`scenario.py` (`--t2logs`, report section) and `prove_mod.py m1`. New download for the mod build: Sponge's Maven
(`repo.spongepowered.org`: Mixin 0.8.5 and the MixinGradle plugin), which the design assumed; CC:Tweaked 1.120.2 and Advanced
Peripherals 0.7.46r are compile-time references copied from the test server's mods folder to `G:\TurtleOS-Sandbox\gradle\refmods`
(never committed or shipped).

## What it does

- `/t2 radio log on|off|all`, `/t2 events log on|off`, `/t2 status`, each answering one line of JSON. Both logs are off at start.
- **Radio**: `WirelessNetwork#tryTransmit` is called once per receiver of a packet, in range or not, channel open or not. The hook
  repeats CC's own range test (receiver range, interdimensional) and the modem's `isOpen(channel)` test, so `radio.jsonl` holds the
  packets that actually reach a program (`outcome: delivered`); `radio log all` also records the rest with the reason
  (`not_reached:out_of_range`, `not_reached:channel_closed`; about 14 times as many lines). Each line: game tick, UTC ms, sender id and
  position, receiver computer id, channel, reply channel, distance, body (clipped at 2 KB, true length kept).
- **Events**: the design named `ServerComputer#queueEvent`; that misses `modem_message` and peripheral events, which reach a computer
  through `IComputerAccess`. The hook is `ComputerExecutor#queueEvent`, the one place every event passes (design section 4 amended).
  It logs what was QUEUED; whether the program consumed it is not visible there.
- **Interventions**: every `/t2` command that changes anything, with its arguments, to `interventions.jsonl` (always on).
- Writing never blocks the server thread: lines go to a bounded queue and a writer thread; a full queue drops the line and COUNTS it
  (shown by `/t2 status` and in the report); files rotate at 256 MB.
- The run report (`scenario.py --t2logs`) reads the files: line counts, outcomes, lines by channel, most frequent events, dropped
  counts, interventions. `spawn_listener` (the listener computer) is retired.

## Proof (`sandbox/t2/prove_mod.py m1`, run `m1-b`; every proof can fail)

| Proof | Result |
|---|---|
| logs are off after start and nothing is written | proved (status all zero) |
| a scripted sender (computer #200, channel 777, reply 778, text `T2-PROBE #n` every 5 s) and a listener (#199 on 777) | proved: the log has the lines with `to` = #199, channel 777, reply 778, `outcome delivered`, the right body |
| the sender position in the log is the sender's | proved: 160,67,-2787 against the spawn spot |
| fleet traffic is logged too | proved: 164 heartbeat lines in 40 s |
| event log: the receiver's `modem_message` with the probe text, the sender's own `timer` events | proved: 8 and 8 in 40 s |
| with logging switched off nothing more is written, while the same sender keeps sending | proved: radio 268 -> 268 and events 508 -> 508 over 20 s |
| interventions: every switch recorded with its arguments, in order | proved |
| no line dropped | proved (0) |
| `radio log all` records unreached attempts with the reason | proved: 2,090 `not_reached` lines in 10 s |

## Cost (the bar: mean tick within 5% at 10x with both logs on; results identical)

- **Alternating windows** of the same job at 10x (`scenarios/cost_ab.py`, run `cost-ab1`: off, on, off, on, 150 s each): off 5.16 and
  4.84 ms, on 4.40 and 5.26 ms; mean on against mean off **-3.3%**. The window-to-window noise (about +/-10%) is larger than any effect,
  so the bar is met and the true cost is below what this PC can resolve.
- **Full job at 10x with both logs on** (run `m1-cost10`, 4.03 game hours in 1497 s, 156,080 radio lines, 285,027 events, 0 dropped,
  118 MB): job completed, 187 batch lines, ore 4168/0/0, rescans and re-mines as before, 0 problem lines: **results identical**.
  Its mean tick time was 4.95 ms; the earlier no-mod run (`new-10x`) read 3.72 ms. The off windows of the alternating test read
  5.0 ms on average, the same as the logs-on job, so the difference between those two full runs is machine load on the day, not the
  mod. Noted rather than hidden.
- Mod loaded, logs off: -0.4% (M0).

## Open / next

- Volume: 156k radio lines and 285k event lines for a four-hour job (about 120 MB); a long soak needs a filter by channel or event
  (open point 2 in the design), not needed yet.
- M2: radio loss and latency at the same hook; then the first payoff, the ack-loss replay on real Minecraft.
