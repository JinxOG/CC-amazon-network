# The sandbox

A fast, local copy of the server for testing the Turtle OS fleet. It runs the **real fleet files, unchanged**
(`central_server.lua`, `turtle_base.lua`, `ore_turtle.lua`, `warehouse.lua`, ...) on a virtual clock, against a
simulated world. A six-hour two-miner job on the synthetic world takes about a minute (about 400× real time); on the
real world copy about 100 s (about 200×).

It is **not** the real server and does not replace it. Every report ends with a **NOT MODELLED** list of the things
it could not exercise, and an **ASSUMPTIONS** list of what it guessed. Design:
`docs/superpowers/specs/2026-10-18-sandbox-simulator-design.md`. Calibration against the live fleet:
`docs/superpowers/specs/2026-10-20-sandbox-calibration.md`.

## Run something in under five minutes

All commands run from the repo root in a Bash shell (Git Bash on this PC).

```bash
sandbox/sim check                                  # is the interpreter right? (parses the fleet, numbers, key order)
SANDBOX_SKIP_SLOW=1 sandbox/sim test               # the sandbox's own tests (under a minute)
sandbox/sim run sandbox/scenarios/smoke_two_miners.lua
```

The last command boots a whole fleet (server, warehouse, 15 workers, GPS hosts), installs the fleet with the real
`install.lua`, orders a two-miner job and runs until it completes. It prints the run folder and the speed achieved,
and writes `report.md` / `report.json` there. `sandbox/sim test` without the variable also runs the slow tests (the
whole-fleet scenarios, the speed test and the incident replays; several minutes).

Options of `run`: `--seed N`, `--speed max|N` (cap at N times real time, for watching), `--code
worktree:<path>|rev:<git-rev>` (which fleet code to install: a worktree as it is, or any commit, so old code can be
run), `--only node_11,node_12` (boot part of the fleet; the report says so), `--world <dir>`, `--run-dir <dir>`.

Where things are: all data lives on the Game Drive, `G:\TurtleOS-Sandbox` (`SANDBOX_DATA` overrides it): world copies
under `worlds/`, runs under `run/`, the Lua interpreter under `interpreter/`, saved storage lists and live-log pages
under `storage/`. Never inside the repo (it syncs to OneDrive and is public); `sandbox/worlds/` and `sandbox/run/`
are git-ignored as a safety net.

## The real world copy

The server's backup of 2026-10-18 17:00 is unpacked, read-only, under
`G:\TurtleOS-Sandbox\worlds\unpacked\2026-10-18_1700\world_live\` (a newer one: `G:\TurtleOS-Sandbox\get-backup.cmd`;
the sandbox never fetches anything itself). The importer turns it into the sandbox's own format:

```bash
python sandbox/tools/import_world.py "G:/TurtleOS-Sandbox/worlds/unpacked/2026-10-18_1700/world_live" \
   --out "G:/TurtleOS-Sandbox/worlds/2026-10-18_1700/sim" \
   --storage "G:/TurtleOS-Sandbox/storage/state-2026-10-19.json" --area 1904,-2640,2000,-2608
sandbox/sim run sandbox/scenarios/real_world_smoke.lua       # the fleet boots from its real disks; 30 simulated minutes
sandbox/sim run sandbox/scenarios/real_world_six_hours.lua   # a two-miner job on that zone, six hours
```

It reads no network and writes nothing into the world copy. The first run searches all 176 region files for
computers (about 15 minutes) and caches that; `--area x1,z1,x2,z2` (repeatable) adds the chunks of a mining zone;
`--storage` takes a saved copy of the live bridge's `/state` (an engineer fetches it; the importer makes no call).
Only the base, the chunks around every fleet computer and the named zones are imported; everything else is air.

## Watch it live

```bash
sandbox/sim view G:/TurtleOS-Sandbox/run/<run-folder> 3101    # then open http://127.0.0.1:3101/
```

A read-only file server and the real dashboard page. It follows the run folder as it is written (about once a second
at full speed). `tools/gate_check.py` and `tools/ack_loss.py` read a run the same way, with
`BRIDGE_URL=http://127.0.0.1:3101`; the report already runs both for you.

## Scenarios and faults

A scenario is a Lua file in `sandbox/scenarios/` returning `{ world, seed, steps = function(sim) ... end }`.
Examples: `smoke_two_miners`, `server_crash`, `world_restart_gps_late`, `rs_stall`, `reboot_mid_refuel`, `radio_loss_5`,
`radio_loss_20`, `six_hour_two_miners` (the synthetic speed benchmark), `incident_*` (replays of past incidents on old
code; `--code rev:<sha>`).

"Pull a string" (times are milliseconds after the scenario's steps began):

`server_crash(t, down_for)`, `world_restart(t, {gps_delay=})`, `server_lag(t, dur, factor)`, `tps_drop(t, dur, tps)`,
`radio_loss(t, dur, rate, {channel=})`, `radio_latency(t, dur, ms)`, `gps_down(t, dur, {hosts=})`,
`rs_stall(t, dur, seconds)`, `rs_offline(t, dur)`, `turtle_reboot(t, node, {at_action="refuel"})`,
`chunk_unload(t, {x1,z1,x2,z2})`, `disk_full(t, node, bytes_free)`, `bridge_down(t, dur)`, `bridge_slow(t, dur, ms)`,
`remove_item(t, node, slot)`, `event_queue_flood(t, node, n)`.

Every fault has a test that fails if the fault is a no-op.

## Reach in (full control)

Everything below is a method on `sim`, in a scenario or interactively. Anything that changes the world or a computer
is listed under **INTERVENTIONS** in the report; reads, `pause`, `step`, `snapshot`, `watch` and `status` are not.

`pause resume step run_until set_speed snapshot restore fork teleport recover set_slot clear_slot give set_fuel equip
spawn_turtle spawn_computer remove reboot shutdown start read_file write_file delete_file eval output queue get_block
set_block fill load_chunks unload_chunks send_radio drop_radio storage_set storage_add storage_remove kv_get kv_set
kv_clear ender_set gps_host place_gps_host watch trace_radio status`

Interactive, from a plain shell with no window (one command per line; it starts paused):

```bash
printf 'status\nrun_for 600000\neval node_11 turtle.getFuelLevel()\nteleport node_11 150 70 -2800 north\nquit\n' \
  | sandbox/sim repl sandbox/scenarios/smoke_two_miners.lua
```

`snapshot(name)` / `restore(name)` / `fork(name)` save and rewind the whole sandbox. **Coroutines cannot be saved**, so
a restore reboots every computer that was on, from its restored disk, and drops events in flight and faults still
scheduled; the report says a restore happened.

## Closing a card on sandbox evidence

Attach the run's `report.md`. The card moves to **Done - not yet seen on the real server**; it moves to plain **Done**
only when the real server has shown the behaviour, or the user says so. A report with **INTERVENTIONS** is not
evidence that the fleet works, unless the intervention *is* the test (a scenario that teleports a turtle to test
recovery). If something breaks on the real server, check the cards in that column first.

**Do not close a disconnect / ack-loss card on a sandbox run yet**: the live fleet's ack loss (11-18% for parked
turtles) is not reproduced (calibration note, section 2).

## Known limits (also in every report)

- Speed on the real world copy is about 200×, not 300×: most of the time is the fleet's own Lua (the miners sort their
  ore list after every ore).
- A faster Lua was tried (LuaJIT 2.1, built and kept in `G:\TurtleOS-Sandbox\interpreter\`, about 8x faster on pure Lua) but its `pairs` order differs between processes, which breaks reproducible runs; see `BUILD-NOTES.txt` there. The default stays Lua 5.2.4.
- Ack loss is not reproduced; the CC radio and mailbox behaviour behind it is only partly modelled.
- Timings marked `unverified` in `sandbox/timings.lua` are guesses; the movement time is fitted to the live ore-batch
  cadence, not measured per action.
- The cloud store starts empty (by design); an empty store at boot can make the server think its zone history was lost.

## Safety, enforced in code

- The network is closed: only the run's own stand-in bridge and `raw.githubusercontent.com` (served from the code
  under test) answer. Everything else, including the live server, is refused and traced.
- The simulator refuses to start if a scenario, argument or setting names the live server's addresses.
- The sandbox never writes outside its run folder, and nothing under `sandbox/` ships to the fleet
  (`install.lua` / `updater.lua` never mention it).
- No CC:Tweaked ROM code is copied (it is not licensed for use outside the mod); every API is rebuilt from the
  documentation at tweaked.cc.

## What is where

`core/` clock, scheduler, computers, fleet provisioning, the sim · `cc/` the CC APIs · `net/` radio · `periph/`
modem, GPS, scanner, RS bridge, cloud store, ender chests · `world/` blocks and chunk loading · `bridge/` the
stand-in bridge and file server · `faults/` · `control/` · `report/` · `scenarios/` · `tests/` · `tools/` (world
importer, interpreter check, calibration) · `assumptions.lua` every guess the sandbox makes (printed in every report).
