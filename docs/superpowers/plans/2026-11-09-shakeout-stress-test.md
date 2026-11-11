# Shakeout Stress Test Implementation Plan

> **For agentic workers:** this project runs plans through its **baton** (docs/mail/BATON.md): one engineer at a
> time, and each holder works its own tasks with superpowers:executing-plans, running layer 1 (simulator) and
> layer 2 (test server) itself. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build everything the approved shakeout design needs, then run it: per-bay turtle types, a test kit that
builds a 160-turtle test world, a seeded fault schedule, a job feeder, a schedule-aware watchdog, a speed ramp, a
statistics report, and the runs themselves.

**Architecture:**
- **Fleet change (W3).** Bay type becomes a setting in `waypoints.lua`, and the central server picks docks by
  type.
- **The test kit (SANDBOX).** A new package, `sandbox/t2/shakeout/`, builds on `sandbox/t2/control.py`. It has
  one module per job: world, fleet, schedule, feeder, report, ramp. A T2 scenario,
  `sandbox/t2/scenarios/shakeout.py`, drives the run.
- **Replays.** The schedule uses the simulator's fault names, so it also replays in `sandbox/` (the simulator).

**Tech Stack:** Lua 5.2 (fleet; CC:Tweaked, the 200-local limit applies), Python 3 (sandbox/t2), the t2control
mod and rcon, the sandbox simulator (`lua52_det`).

**Spec:** `docs/superpowers/specs/2026-11-09-shakeout-stress-test-design.md` (approved by the user 2026-11-09).
Executors read both.

## Global Constraints

- Test server (T2) only. **Never the live server**; the live deploy ban (since 2026-10-28) stands.
- Fleet layout: worker bay 1 delivery 16; support bay 1 support 16; the other 8 bays miners 128; total 160.
- Every turtle placed **fresh**, never copied. Never `/clone` a bay that has turtles in it.
- Main run: **24 real hours, no matter what**, at the fastest speed whose mean tick stays under **80% of its
  budget**. If 1x does not hold with 160 turtles, **stop and tell the user**.
- No person and no script rescues a turtle during a run.
- Every check must be able to fail, with a **control run that shows it failing** before it is trusted. Every
  verdict states its evidence count.
- Defaults the fleet must live within: CC disk 1,000,000 B. CC refuses a file whose live locals exceed 200 in a
  function plus its enclosing ones; `tests/test_cc_local_limit.lua` guards that.
- 150-turtle simulator runs use `SANDBOX_NO_TRACE=1`, because the G: drive is 95–99% full.
- `delivery_turtle.lua` and `support_turtle.lua` stay frozen. Turtle-side changes go in `turtle_base.lua`.
- Commit only named files (never `git add -A`). Push with `git push origin HEAD:master` and verify with
  `git merge-base --is-ancestor HEAD origin/master`.

## Review Focus

1. **Live docks assigned before per-bay types.** A miner already sitting in a DELIVERY dock on the live server
   must be moved to a free MINER dock at registration, said once in the log. It must never be stranded dockless,
   and it must never double-book a dock. (Task 2.)
2. **The harness survives its own server dying.** A restart burst ("up then straight down", 5 in a row) must not
   crash the runner. rcon and the bridge reconnect, and the scheduler keeps its place by wall clock. (Task 5.)
3. **A filler file left on the server disk.** If a crash lands while the disk is full, the filler must still be
   removed when the window ends and at teardown. A filler left behind poisons every later count. (Task 5.)
4. **A turtle hit by two faults in one window** is counted once per finding, not twice. Its recovery time is
   measured from the LAST fault that touched it. (Task 7.)
5. **The bridge down while the report reads.** The report reads the run folder's log files directly, never only
   through the bridge, and marks any gap it cannot fill as TRUNCATED. (Task 7.)

---

## Part 0: prerequisites (already carded, in baton order)

- [ ] **W5:** card "Bridge: 107 slow pushes in one test-server run, cause unknown". It has the baton since
  2026-11-09.
- [ ] **W1:** card "After a restart, turtles resume the job where they stand instead of flying home".

Parts 1 and 2 may be built before Part 0 is done. Part 3, the runs, waits for it.

## Part 1: per-bay turtle types (W3)

### Task 1: Bay types in waypoints.lua

**Files:**
- Modify: `waypoints.lua` (CFG, `generateBays`, `W.docks`, the dock lookups)
- Test: `tests/test_bay_types.lua`

**Interfaces:**
- Produces:
  - `CFG.BAY_TYPES = { WORKER = { "DELIVERY", "MINER", "MINER", "MINER", "MINER" }, SUPPORT = { "SUPPORT", "MINER", "MINER", "MINER", "MINER" } }`, indexed by bay number;
  - `W.docks` gains a `MINER` list;
  - `W.dockTypeFor(role) -> "DELIVERY" | "SUPPORT" | "MINER"`, where LOADER returns nil;
  - `W.assignDock` / `W.getDockFor` / `W.freeDocks` / `W.totalDocks` take a dock type.

- [ ] **Step 1: Write the failing tests** in `tests/test_bay_types.lua`:
  - `totals`: `W.totalDocks("DELIVERY") == 16`, `W.totalDocks("SUPPORT") == 16`, `W.totalDocks("MINER") == 128`;
  - `miner_docks_span_both_sides`: there are 64 MINER docks with z in the worker rows and 64 in the support rows;
  - `routes_are_single_axis`: for every dock, each leg of `departureRoute` and `returnRoute` changes exactly one of
    x and z;
  - `routes_avoid_dock_cells`: no route leg passes through any other dock's cell.
- [ ] **Step 2: Run** `lua tests/test_bay_types.lua`. Expected: FAIL on `totals` (MINER is unknown).
- [ ] **Step 3: Implement it.** `generateBays` reads each bay's type from `CFG.BAY_TYPES`. Rows A and B keep
  their z values.
- [ ] **Step 4: Run** `lua tests/test_bay_types.lua` and `lua tests/test_cc_local_limit.lua`. Expected: PASS.
- [ ] **Step 5: Commit** `waypoints.lua` and `tests/test_bay_types.lua`.

### Task 2: The server picks docks by type, and moves misplaced live miners once

**Files:**
- Modify: `central_server.lua`, about line 278 (`dockRole = ...`, the dock recovery in `registry.register`)
- Test: `tests/test_bay_types_server.lua`; `sandbox/scenarios/w3_bay_types150.lua`;
  `sandbox/t2/scenarios/w3_bay_types.py`

**Interfaces:**
- Consumes: `W.dockTypeFor`, and the typed `W.getDockFor` / `W.assignDock` from Task 1.
- Produces: the log line `Dock moved: <id> from bay <b> row <r> (<oldType>) to bay <b> row <r> (MINER) -- per-bay types`, written once per move.

- [ ] **Step 1: Write the failing unit test** `misplaced_miner_moves_once`. A saved `dock_assignments.dat` holds
  a MINER-role id in a DELIVERY dock. After `registry.register`:
  - the id holds a MINER dock;
  - the DELIVERY dock is free;
  - the line was logged exactly once;
  - a second register logs nothing.

  Add `no_free_miner_dock_keeps_old`: when every MINER dock is full, the turtle keeps its old dock and a WARN is
  logged. It is never left dockless.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement it** in `registry.register`, using `W.dockTypeFor(role)`.
- [ ] **Step 4: Layer 1.** `w3_bay_types150.lua`, with 150 turtles from the capacity world and the ATC on. It
  checks:
  - every turtle ends on a dock of its type;
  - deliveries, support and mining all complete;
  - no corridor wait exceeds the ATC bound.

  It must FAIL on today's master, where miners land on DELIVERY docks.
- [ ] **Step 5: Layer 2.** `w3_bay_types.py`: one delivery pair, plus one miner docked in a **support-side** bay.
  The miner mines and gets back to its north-side dock through the ATC.
- [ ] **Step 6: Commit,** then move the board card to "Done - not server validated" with its VALIDATION block.

## Part 2: the test kit (SANDBOX)

All files are new under `sandbox/t2/shakeout/` unless they are named otherwise. Unit tests go in
`sandbox/tests/test_shakeout_*.py`. They use a fake `ctx` whose `command()` records the rcon text, which is the
pattern `sandbox/tests/test_t2_scenario.py` already uses.

### Task 3: Item NBT in set_slot

**Files:**
- Modify: `sandbox/t2/control.py`, `set_slot`
- Test: `sandbox/tests/test_shakeout_control.py`

**Interfaces:**
- Produces: `Control.set_slot(computer_id, slot, item, count=1, tag=None)`. `tag` is an SNBT string such as
  `'{Frequency:{left:0,middle:0,right:14}}'`, appended to the stack as `tag:<tag>`.

- [ ] **Step 1: Write the failing test** `set_slot_with_tag_sends_tag`. The recorded command contains `tag:{Frequency:`.
  Add `set_slot_without_tag_unchanged`: the command is byte-identical to today's.
- [ ] **Step 2: Run** `python -I -m pytest sandbox/tests/test_shakeout_control.py`. Expected: FAIL.
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run.** Expected: PASS. Then **prove it on T2:**
  - an ender chest given with bay 1's frequency reads back from `get_slot` with the same tag;
  - placed from a turtle, it connects to bay 1's storage, meaning items moved in show up on the other side.
- [ ] **Step 5: Commit.**

### Task 4: World builder: bays, under-dock blocks, ATC, GPS towers, forceload, save point

**Files:**
- Create: `sandbox/t2/shakeout/world.py`; `sandbox/t2/shakeout/dock_cells.lua`, a dumper that runs `waypoints.lua`
  in the sandbox interpreter and prints JSON
- Test: `sandbox/tests/test_shakeout_world.py`

**Interfaces:**
- Produces:
  - `dock_cells() -> list[dict(type, bay, row, x, y, z, facing)]`, read from `waypoints.lua` through
    `dock_cells.lua` and never re-typed in Python;
  - `BASE_AREAS: list[(x1, z1, x2, z2)]`, which covers the building, both tunnels, x 224–271 z -2816..-2769, and
    every GPS tower;
  - `GPS_TOWERS: list[(x, y, z)]`, at least 8 more than the existing 4 and spread out;
  - `build_world(ctx) -> dict(report)`;
  - `save_point(ctx, "shakeout-world")`, the existing control verb.

- [ ] **Step 1: Write the failing tests:**
  - `dock_cells_match_waypoints`: 160 cells, with the types from Task 1;
  - `build_never_clones_turtles`: no recorded command is `clone`, unless a later `fill ... replace computercraft:turtle_*` covers the same box before any `tick`/`resume`;
  - `under_dock_copies_nbt`: for each new cell, the `setblock` below it carries the NBT read from bay 1's matching
    cell;
  - `forceload_covers_arrivals`: `BASE_AREAS` covers x 224–271, z -2816..-2769.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement `build_world`.**
  1. Forceload `BASE_AREAS`.
  2. Build the bay 2–5 floor, pillars and aisles from the `dock_cells` geometry.
  3. Copy each cell's under-block, with its NBT, from bay 1's cell in the same row and slot.
  4. Place the ATC computer with `spawn_computer` and the atc profile's files from the pin (reuse `w3_atc_pair.py`'s `show()` and `ATC_FILES`).
  5. Place each `GPS_TOWERS` entry with `spawn_computer` running `gps_host.lua`, configured with its coordinates.
- [ ] **Step 4: Run the unit tests,** then **prove it on T2:**
  - `build_world` on a fresh copy;
  - every dock cell is air;
  - every under-block's `data get` equals bay 1's;
  - `gps.locate` from a probe computer in each of three far corners of the base gets a fix from at least 6 hosts;
  - the ATC logs that it is online.

  Then `save_point`.
- [ ] **Step 5: Commit.**

### Task 5: Fleet placement, the fault scheduler and the run loop

**Files:**
- Create: `sandbox/t2/shakeout/fleet.py`, `sandbox/t2/shakeout/schedule.py`, `sandbox/t2/scenarios/shakeout.py`,
  `sandbox/scenarios/shakeout_replay.lua`
- Test: `sandbox/tests/test_shakeout_fleet.py`, `sandbox/tests/test_shakeout_schedule.py`

**Interfaces:**
- Consumes: `dock_cells()` (Task 4), and `set_slot(..., tag=)` (Task 3).
- Produces:
  - `ROLE_KIT: dict[role -> dict(right, fuel, items={slot: (item, count, tag)})]`, copied from what the live
    turtles carry (read one of each role from T2's bay 1 with `get_slot`);
  - `place_fleet(ctx, layout=dock_cells()) -> dict[node_id -> cell]`, which also seeds the server's
    `dock_assignments.dat` before the server computer starts;
  - `make_schedule(seed, hours, rates) -> list[dict(t_ms, fault, args, quiet_ms)]`;
  - `FAULTS`: the simulator's fault names (`server_crash`, `world_restart`, `radio_loss`, `radio_latency`,
    `gps_down`, `chunk_unload`, `rs_stall`, `rs_offline`, `tps_drop`, `bridge_down`, `bridge_slow`, `disk_full`,
    `turtle_reboot`, `remove_item`), plus `atc_crash`, `warehouse_crash`, `restart_burst5`, `put_back_turned`,
    `low_fuel` and `full_inventory`. Each is mapped to a control verb in `schedule.APPLY`;
  - `write_schedule(path, schedule)`, writing `schedule.json` in the run folder;
  - `run_due(ctx, schedule, wall_ms)`.

- [ ] **Step 1: Write the failing tests:**
  - `fleet_is_fresh`: 160 distinct computer ids, no `.dat` or `.log` files on any new disk, and every loader item
    without a copied UUID tag;
  - `seeded_docks_match_positions`: every seeded assignment equals the cell the turtle stands in;
  - `schedule_is_deterministic`: the same seed gives an identical list;
  - `every_fault_type_fires`: over 24 h each type fires at least 3 times, and `restart_burst5` fires at least once;
  - `some_faults_land_in_recovery`: at least 10% of faults start within 10 minutes after the previous one;
  - `replay_loads_in_sim`: `shakeout_replay.lua` reads a `schedule.json` and calls only known simulator verbs, with
    unknown names refused by name;
  - `disk_filler_always_removed`: a `disk_full` whose window contains a `server_crash` still removes the filler at
    the window's end and at teardown (Review Focus 3);
  - `runner_survives_restart_burst`: with a fake rcon that drops during the burst, `run_due` reconnects and the
    next fault fires at its wall-clock time (Review Focus 2).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement them.** Bake the minimum-count rules into `make_schedule`. The defaults for `rates` go
  in the schedule file.
- [ ] **Step 4: Run them.** Expected: PASS. Then **prove it on T2:**
  - **Placement:** place the fleet and check every turtle registers on the dock it stands on, with no "Assigned
    dock" line for a different dock.
  - **Loader identity:** two miners place their loaders at least 1,000 blocks apart, and `control.chunk_loaders()`
    shows 2 tickets that both hold.
  - **Faults:** fire each fault type once, in order, with a short schedule.
- [ ] **Step 5: Commit.**

### Task 6: Feeder, housekeeping and a schedule-aware watchdog

**Files:**
- Create: `sandbox/t2/shakeout/feeder.py`
- Modify: `sandbox/t2/watch_run.py`, adding `--schedule PATH`; raise the default for `--max-hours` only when
  `--schedule` is given
- Test: `sandbox/tests/test_shakeout_feeder.py`, `sandbox/tests/test_watch_run_schedule.py`

**Interfaces:**
- Produces:
  - `Feeder(ctx, min_jobs=10, max_idle_s=600, sites=3, destinations=4).tick(now)`, which places orders through the
    T2 bridge's `POST /command` (T2 only);
  - `ZONES`: fresh mining zones, never overlapping and rotated;
  - `housekeep(ctx, now)`: drains ore and tops up delivery stock on a fixed timetable, and logs each action as
    `HOUSEKEEPING <what>` in the run folder, apart from the INTERVENTIONS.

- [ ] **Step 1: Write the failing tests:**
  - `feeder_keeps_ten_jobs`;
  - `feeder_never_reuses_ground`, with no zone overlapping another;
  - `housekeeping_is_logged_not_intervention`;
  - `watch_excuses_scheduled_quiet`: a 15-minute silence covered by a schedule entry's `quiet_ms` does not fail;
  - `watch_fails_unscheduled_quiet`: the same silence with no schedule entry fails, exactly as today.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement them.**
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 7: The report, and the speed ramp

**Files:**
- Create: `sandbox/t2/shakeout/report.py`, `sandbox/t2/shakeout/ramp.py`
- Test: `sandbox/tests/test_shakeout_report.py`, `sandbox/tests/test_shakeout_ramp.py`

**Interfaces:**
- Consumes: the run folder's log files (read directly, Review Focus 5), `schedule.json`, the HOUSEKEEPING lines and
  `/state` snapshots.
- Produces:
  - `classify(turtle_timeline, schedule) -> one of "ok", "stuck_recovered", "decommissioned", "lost",
    "expected_hands"`, with the spec's rules: stuck means off-dock with no progress for **10 real minutes**
    outside an active fault; gone means no heartbeat for **30 real minutes** outside an active fault;
  - `JAM`: at least 3 turtles stuck within the `BASE_AREAS` box at once, cleared when fewer than 3 remain;
  - `write_report(run_dir) -> report.md` with these sections:
    - stuck or failed turtles, with quoted log lines;
    - jams, with clear times;
    - jobs completed by type;
    - faults fired by type;
    - decommissioned turtles and why;
    - expected hands;
    - first 6 h against last 6 h;
    - draft board cards, each with its seed and schedule.

    Every number in it carries an evidence count, and any gap is marked TRUNCATED;
  - `write_report(run_dir, expected=EXPECTED_ISSUES)`: `EXPECTED_ISSUES` lists, by log pattern, the board cards
    still open at run time. Matches are reported under EXPECTED, apart from new findings, so they do not drown
    them out;
  - `ramp(ctx, steps=(1, 2, 3, 4), hold_min=20) -> chosen_speed`, picking the highest step with mean tick under
    80% of 50 ms / speed. It raises `RampFailed` when 1x fails.

- [ ] **Step 1: Write the failing tests:**
  - `stuck_vs_active_fault`: a turtle off-dock for 15 minutes inside a fault window is not stuck, but 15 minutes
    after the window it is;
  - `two_faults_one_count`: a turtle hit twice in one window gives one finding, with recovery measured from the
    last fault (Review Focus 4);
  - `growth_fails_flat_passes`: server disk used rising steadily over the run fails the judged drift check, while
    jitter around a level passes;
  - `bridge_gap_is_truncated`: a missing log hour is reported as TRUNCATED, never as zero;
  - `ramp_picks_and_stops`: given synthetic tick means, it picks the right step and raises `RampFailed` when 1x is
    over 40 ms.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement them.**
- [ ] **Step 4: Run them.** Expected: PASS. Then run the **control that must fail:** point `write_report` at W3's
  simulator run of today's master without the ATC (the 2026-11-04 `w3_atc_base150` old-code run). It must report
  at least 1 uncleared JAM and at least 100 stuck turtles.
- [ ] **Step 5: Commit.**

## Part 3: the runs (after Part 0)

### Task 8: Dress rehearsal, the 1x side test, and the 24-hour run

**Files:**
- Create: `docs/measurements/2026-11-XX-shakeout-report.md`, copied from the run's `report.md`; new board cards
  for its findings

- [ ] **Step 1: Dress rehearsal (simulator).** `shakeout_replay.lua` with 160 turtles, a 24 h schedule (seed 1),
  `SANDBOX_NO_TRACE=1`, for a simulated week. Fix kit bugs only. Fleet bugs become cards.
- [ ] **Step 2: Speed ramp on T2,** ON THE PLACED FLEET WITH THE FEEDER RUNNING, not on the empty `shakeout-world`
  (an idle server holds any speed; amended 2026-11-11 after the final review): `sandbox/t2/scenarios/shakeout_ramp.py`
  runs `shakeout.setup` (all 160 turtles placed), then `ramp.ramp` with the job feeder's `tick` called at every tick
  sample of every hold, so each speed is measured with the whole fleet working. Record the chosen speed. If
  `RampFailed`, stop and mail the spec owner, who tells the user.
- [ ] **Step 3: The 1x side test.** Bay 1 only: 16 turtles plus 4 miners, 6 real hours. Faults: radio loss and
  latency bursts, 1 world restart, 1 central-server crash, 1 ATC crash. Write the report.
- [ ] **Step 4: Confirm with the user** that Windows Update is held off and the PC will be left alone. Then start
  the **24-hour run** at the chosen speed, with `watch_run.py --schedule`.
- [ ] **Step 5: Write the report, then:**
  - copy it to `docs/measurements/`;
  - make one board card per finding, with its seed and schedule;
  - mail the spec owner a summary that gives the pass bar's four counts first.
- [ ] **Step 6: Commit.**
