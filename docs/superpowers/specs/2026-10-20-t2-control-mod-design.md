# The T2 control mod: deep control for the local test server

- **Status:** design. Written 2026-10-20 by the spec owner at the user's direction ("write the mod spec for the
  control for the server on here").
- **Parent:** `2026-10-20-testing-procedures-design.md` section 6.10 (layer 2, the local test server).
- **Builder:** the sandbox builder (mail `SANDBOX`), under the `sandbox/` rules.

## 1. Why

The local test server (T2) is real Minecraft. That is its value, but real Minecraft has no switch for the faults
the fleet's worst bugs came from, and it shows less than the simulator does. Phase 2 (`2026-10-20-t2-phase2-report.md`)
proved most controls with plain commands. Three things cannot be done that way:

- **Radio:** no way to see every message, or to lose or delay messages on purpose.
- **Chunk unload under a loader turtle:** Advanced Peripherals holds the ticket, and no command releases it.
- **What a computer was handed:** no record of the events each computer received.

This mod adds them, plus a few conveniences that are clumsy through commands. It runs **only** on T2.

## 2. Goals

1. **Radio log:** every wireless message, with time (game tick and real UTC), sender position, receiver computer,
   channel, reply channel, distance and the message body, written to the run folder.
2. **Radio faults on demand:** loss (a share, optionally per channel or per receiver) and latency (fixed or a
   range). Same names and arguments as the simulator's `radio_loss` / `radio_latency`.
3. **Event log:** every event queued to every computer (name, arguments summarised, tick, UTC), so "what reached the
   turtle, and in what order" can be answered.
4. **Chunk unload under a loader:** release a loader turtle's Advanced Peripherals ticket for a set time, then let it
   come back. The simulator's `chunk_unload`.
5. **Turtle controls:** move a turtle without a reboot (a script call, not a `/clone` dance), and save and restore one
   turtle (position, facing, inventory, fuel, upgrades and its disk folder).
6. **Peripheral stalls:** make a peripheral's calls slow or fail for a set time (Refined Storage bridge, geo scanner).
   The simulator's `rs_stall` family.
7. **Pause and step** the whole server.
8. **Every action recorded** in the run's INTERVENTIONS, automatically.
9. **Invisible when idle:** with every fault off, behaviour is unchanged and the cost is measured (section 8).

**Stretch, built last and only if cheap:** run a Lua snippet on a named computer mid-run (`eval`).

## 3. Non-goals

- Exact replay. Real Minecraft is not deterministic; the mod does not try to make it so.
- Any use outside T2. Never on the live server, never in the user's instance (section 5).
- Changing gameplay. The mod adds controls and logs; it changes no recipe, block, item or mob.
- A user interface. It is driven by script; the dashboard is still the window.

## 4. Where it hooks: checked in the pack's own jars, 2026-10-20

Versions: **CC:Tweaked `cc-tweaked-1.20.1-forge-1.120.2`**, **Advanced Peripherals `0.7.46r`**, Forge
**`1.20.1-47.4.10`** (the live server's, confirmed by the user).

| Goal | Hook (Mixin unless stated) | Note |
|---|---|---|
| Radio log, loss, latency | `dan200.computercraft.shared.peripheral.modem.wireless.WirelessNetwork#tryTransmit(PacketReceiver, Packet, double, boolean)`, called once per receiver | Per-receiver, so loss and latency can be per receiver. A delayed packet is re-delivered later on the server thread through the original call; if the receiver is gone by then, it is dropped and logged as `dropped_receiver_gone` |
| Event log | `dan200.computercraft.shared.computer.core.ServerComputer#queueEvent(String, Object[])` | Logs what was queued. Whether the program then *consumed* it, or a filtered yield ate it, is not visible here; the log says so |
| Turtle move without reboot | `dan200.computercraft.shared.turtle.core.TurtleBrain#teleportTo(Level, BlockPos)`, called (not hooked) | The same path a turtle uses to move itself. Facing: set separately; to be proven in M4 |
| Chunk unload | `de.srendi.advancedperipherals.common.util.ChunkManager#removeForceChunk(ServerLevel, UUID)`, called, plus a hook on `ChunkManager#serverTick` / `addForceChunk` that refuses to re-force that UUID until the fault expires | The loader re-asks for its ticket every tick; without the refusal the unload would undo itself at once |
| Peripheral stall | **To be found in M5:** the call path where CC:T dispatches a peripheral method; Advanced Peripherals' bridge methods if a generic point is not clean | Must stall without blocking the server thread for other computers |
| Pause / step | Server tick loop, or the tick-rate mod's own control if it pauses cleanly | Computers mid-run keep running until they yield. Timers freeze, but `os.epoch` (real clock) does not; the report says so |
| Turtle save/restore | Block-entity NBT plus the computer's disk folder, by command | Mostly commands; the mod makes it one atomic call |

**A pinned target:** the Mixins are tied to these exact versions. The mod refuses to load if CC:Tweaked or Advanced
Peripherals is any other version (section 5). An update of either means updating the mod first.

## 5. Safety: it can never leave T2

1. **Load guard.** At start-up the mod checks three things:
   - the server's `server-ip` is `127.0.0.1`;
   - a file `t2control.allow` exists in the server folder, written by `sandbox/t2/run.py` with the run id;
   - the CC:Tweaked and Advanced Peripherals versions match section 4.

   If any check fails, it **stops the server** with a message naming the reason. A copied jar on the live server
   therefore cannot run.
2. **Placement guard.** `run.py` refuses to start a run if the mod's jar, by file name or by its mod id inside, is
   found anywhere outside `G:\TurtleOS-Sandbox\testserver\server\mods`. That includes the user's instance
   (`...\ModrinthApp\profiles\SakuraPack 1.0.0\mods`), which the sync program shares with the server.
3. **Server-side only.** It is declared server-only, so no client needs it and no client is sent it.
4. **Off by default.** Every fault starts off, and every fault has a duration and expires by itself. Logging can be
   switched per run.
5. **The repo holds source only.** No CC:Tweaked or Advanced Peripherals jar is committed. They are compile-time
   references read from the pack folder or their public Maven repositories.

## 6. How scripts drive it

- **Commands over RCON**, which T2 already uses (`sandbox/t2/rcon.py`). One command family, `/t2 <verb> ...`, each
  returning one line of JSON:

```
/t2 radio log on|off
/t2 radio loss <rate 0..1> <duration_s> [channel <n>] [to <computer id>] [seed <n>]
/t2 radio latency <min_ms> <max_ms> <duration_s> [channel <n>]
/t2 events log on|off [computer <id>]
/t2 chunk unload <computer id> <duration_s>
/t2 turtle move <computer id> <x> <y> <z> [facing n|e|s|w]
/t2 turtle save <computer id> <name>     /t2 turtle restore <name>
/t2 peripheral stall <type> <extra_ms> <duration_s>      /t2 peripheral fail <type> <duration_s>
/t2 pause     /t2 step <ticks>     /t2 resume
/t2 status
```

- **The verb names in `sandbox/t2/control.py` match the simulator's** (`radio_loss`, `radio_latency`, `chunk_unload`,
  `teleport`, `rs_stall`, ...). A scenario written for T1 runs on T2 wherever the verb exists. A missing one raises
  `Unsupported`, never a silent no-op.
- **Durations are game seconds**, so a fault scales with the tick rate exactly as the game does. The log records
  both game time and real UTC.
- **Randomness** (loss) uses a seed given or recorded, so a run states which seed it used.

## 7. Outputs

All under the run folder, `<run>\t2control\`:

| File | Content |
|---|---|
| `radio.jsonl` | one line per delivery attempt: tick, UTC, from position, to computer, channel, reply channel, distance, body (truncated at 2 KB, with its full length), outcome `delivered` / `lost` / `delayed:<ms>` / `dropped_receiver_gone` |
| `events.jsonl` | one line per queued event: tick, UTC, computer, event name, arguments summarised |
| `interventions.jsonl` | every `/t2` command that changed anything, with its arguments, start and expiry |
| `saves\<name>\` | turtle save points |

- **Writing never blocks the server thread.** Lines go to a queue and a writer thread.
- If the queue overflows, lines are dropped **and counted**, and the count appears in the report. A log that
  silently lost lines would look like evidence (`feedback-checks-must-be-able-to-fail`).
- Files rotate at 256 MB.
- The T2 run report (testing spec 6.9) reads these files. INTERVENTIONS is filled from `interventions.jsonl`, and
  **NOT STAGED** drops `radio_loss`, `radio_latency` and `chunk_unload` once the mod is in.

## 8. Cost: measured, not assumed

The mod must not change what it observes. Measured on the three-sector job at 1x and at 10x:

| Setting | Bar |
|---|---|
| Mod loaded, everything off | mean tick time within **2%** of no mod; job results identical (ore by sector, batches, problems) |
| Radio log + event log on | mean tick time within **5%** at 10x; results identical |

If a bar is missed, the report says by how much, and logging stays off by default until it is fixed.

## 9. Proof: every control must be able to fail

Like the simulator's faults, each verb is proven **both ways** on a live T2 run (`sandbox/t2/prove_mod.py`):

| Verb | Proven by |
|---|---|
| radio log | a scripted message from a known computer appears with the right channel and body; with logging off, nothing is written |
| radio loss | at rate 1.0 on a channel, the fleet's ack counters show the loss (`tools/ack_loss.py`) and `radio.jsonl` shows `lost`; at 0.0, nothing is lost |
| radio latency | the measured gap between a send and its delivery matches the setting |
| events log | a known `turtle_response` / timer event appears for the right computer |
| chunk unload | the loader's chunk unloads (its computer shuts down, per CC behaviour) and comes back when the fault expires; without the refusal hook, the test shows it re-forced at once |
| turtle move | the computer stays on (same uptime) and is at the new position; facing as asked |
| turtle save/restore | a changed inventory and fuel return to the saved values |
| peripheral stall | the warehouse's own probe line (`RS probe: listItems Nms`) shows the added time; it is back to normal after expiry |
| pause/step | the tick count advances by exactly the steps given |
| safety | the server refuses to start without the allow file, with `server-ip` not local, or with a wrong CC:T version; `run.py` refuses when the jar is in the instance folder |

## 10. Build

- **Toolchain:**
  - JDK 17;
  - the Forge 1.20.1-47.4.10 mod development kit, with ForgeGradle and Mixin;
  - Gradle's cache and build output under `G:\TurtleOS-Sandbox\gradle\` (`GRADLE_USER_HOME`), not on C: (37 GB free)
    and not in OneDrive.

  **Every download and install needs the user's OK** in the builder's session.
- **Source:** `sandbox/t2mod/` in the repo, a Gradle project.
- **Output:** the jar goes to `G:\TurtleOS-Sandbox\testserver\server\mods\` only.
- **Unit tests** (JUnit): loss decision with a seed, latency queue order, log line format, load-guard logic.

### Phases. Stop and report after each; the user can stop at any phase

| Phase | Delivers | Done when |
|---|---|---|
| M0 | Toolchain, an empty `t2control` mod that loads on T2, the load guard and placement guard | the guard tests in section 9 pass; tick time unchanged |
| M1 | Radio log, event log, interventions log; the report reads them | proven both ways; cost bar (section 8) met; the listener computer is retired |
| M2 | Radio loss and latency | proven both ways; a T1 scenario using `radio_loss` runs unchanged on T2 |
| M3 | Chunk unload under a loader | proven both ways, including the re-force refusal |
| M4 | Turtle move (API), turtle save/restore | proven; facing confirmed |
| M5 | Peripheral stall and fail | hook point found and written into section 4; proven |
| M6 | Pause and step | proven; the clock caveat stated in the report |
| M7 (stretch) | `eval` on a computer | only if a clean, version-pinned way exists; otherwise recorded as not done |

**The first payoff** after M2 is the old ack-loss replay on real Minecraft. The simulator reproduced 9.08% loss on code
from before the private channel. M1's logs on T2 show whether real CC agrees, closing that loop with ground truth.

## 11. Open points

1. **Body logging.** Message bodies can be large. They are truncated at 2 KB with the length kept; full bodies only
   with a per-run flag.
2. **Event log volume.** The fleet queues many timer events. Filtering by computer or event name may be needed for long
   runs; decided from M1's measured volume.
3. **The peripheral stall hook (M5)** is the one hook not yet located in the jars.
