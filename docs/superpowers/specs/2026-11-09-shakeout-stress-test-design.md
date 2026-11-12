# Shakeout stress test — design

Status: **APPROVED by the user, 2026-11-09.** Written by the spec owner from the user's brainstorm of
2026-11-02 to 11-09. Plan: `docs/superpowers/plans/2026-11-09-shakeout-stress-test.md`.

## 1. Why

The fleet has had about 70 fixes since September. Before the user scales up the live server and adds features,
they want proof that the fleet stays consistent **over a long time, under the worst conditions**, close to
"perfect", so that they stop recovering turtles by hand. In their words: shake everything out and put the
turtles in the worst situation possible for as long as possible, so that when the live server scales up, these
problems are not a thing.

The test runs on the **local test server (T2) only, never the live server**.

## 2. What the test proves (the primary test)

All of these hold together, at full scale, for the whole run:

1. **Teamwork at scale.** 160 turtles, with every turtle on a job and 10 or more jobs running at all times.
   The jobs are deliveries, several mining sites, and long-running mining sites.
2. **The server copes.** The central server, the ATC computer, the warehouse and the bridge keep up with that
   many turtles.
3. **Everyone recovers.** After every fault, each turtle either **resumes its job where it stands** (the W1
   card, section 8) or, when it has a stated reason to (no GPS, missing tools, low fuel, inventory full, job
   cancelled, job failed), **gets itself home** through the arrival hole and back to work. Nothing clogs, and
   every traffic jam clears. A fault's **recovery window closes** when every turtle it touched is working again
   or parked IDLE at its dock. The schedule uses that moment when it places a crash during a recovery.
4. **It lasts.** Day 1 and the last day look the same: no slow drift, no pile-up, no growth.

**A separate, smaller side test** runs at 1x (normal speed). It covers what running fast hides: radio loss and
timeouts. At 10x the measured ack loss was 2.42%; at 1x it was 22.82%. The main run proves mechanics. The 1x
run proves timing.

**The 1x side test (spec owner's call):**
- **Fleet:** the live fleet's size, bay 1 only (16 delivery and support turtles plus a handful of miners).
- **Length:** 3 real hours (the user's call, 2026-11-12; it was 6). The four one-off faults are spread about 40 minutes
  apart, so each one's recovery is read on its own. Six hours would have added samples of rare timing failures, and
  the 24-hour run gives those; slow drift is the 24-hour run's job either way.
- **Faults:** radio loss and latency bursts, one world restart, one central-server crash and one ATC crash.
- **Pass bar:** the same as the main run.
- **If it fails:** it makes cards, but it does not block the 24-hour run unless a turtle is decommissioned.

### Where the work comes from (spec owner's call)

- **The feeder.** A feeder places orders so that **at least 10 jobs are always running and no turtle sits idle
  for more than 10 minutes** outside a fault. That is a load target, not a pass check. Turtles between jobs or
  recovering are fine.
- **Mining sites.** Mining goes to fresh zones, rotated so that ground is never re-mined. At least 3 sites are
  long-running and stay open for most of the run.
- **Deliveries.** Deliveries carry ordinary stock the warehouse holds, to at least 4 destinations.
- **Storage.** The harness keeps storage in its normal range: it drains ore and tops up delivery stock on a fixed
  timetable. Every top-up or drain is logged as **housekeeping**, apart from faults. Storage filling up happens
  only as a **scheduled fault** ("storage full for N minutes"), never by accident.

### Pass bar (the user's)

- **No turtle lost.**
- **Everything recovered.**
- **A turtle that fails a job gets itself home and back to work.**
- **The true win: no turtle decommissioned** (needing a person) over the whole run.

The report states each of these as a count, with its evidence count (see section 7).

**How the tooling decides (spec owner's call, since nobody watches a 24-hour run):**

| Term | Rule |
|---|---|
| **Stuck** | Off its dock and making no progress (position unchanged and no new phase) for more than 10 real minutes, outside a fault that is still active. |
| **Recovered** | A stuck turtle that later works again or parks at its dock without help. The report gives how long it took. |
| **Decommissioned** (needs a person) | Stuck at the end of the run; or the server raised NEEDS HANDS for it and the turtle never cleared; or it is gone, meaning no heartbeat for 30 real minutes outside an active fault. |
| **Lost** | Decommissioned and not physically findable at its last reported position, or destroyed. |

**No person and no script rescues a turtle during the run.** A stuck turtle stays stuck, and that is the
finding. One decommissioned turtle means the pass bar is missed, but the run carries on to 24 hours, because
later findings still count.

## 3. Non-goals and anti-goals

- **Not on the live server.** Nothing in this test touches it. The live deploy ban (since 2026-10-28) stands.
- **Not a benchmark.** Speed is chosen so that the server holds steady, not to set records.
- **Anti-goal: a "pass" that could not have failed.** Every check in the report must be able to fail, and must
  be shown to fail at least once before the run. For example, the jam detector must fire on today's master
  without the ATC.
- **Anti-goal: a run that is quietly void.** If the host sleeps, the game server dies, or the fleet goes silent,
  the run is marked VOID in the report. It is never counted as a pass. `sandbox/t2/watch_run.py` already
  detects all three.
- **Not android work.** Androids stay on hold.

## 4. The fleet and the world

### 4.1 Layout (agreed with the user)

Each bay holds ONE turtle type:

| Bay | Type | Turtles |
|---|---|---|
| Worker bay 1 | delivery only | 16 |
| Support bay 1 | delivery support only | 16 |
| The other 8 bays (worker 2–5, support 2–5) | miners | 128 |
| **Total** | | **160** |

- **The bay type is a setting**, so a future role (builders) can take bays. Today
  `central_server.lua` sends miners and delivery turtles to the same worker docks
  (`dockRole = SUPPORT or DELIVERY`). That changes.
- **Miners in the north (support-side) bays** need working routes in and out. Today those bays only ever hold
  support turtles.
- **The live server has miners in worker bay 1.** They move to miner bays once, whenever the user rolls this
  out. That is not part of this test.

### 4.2 Building the test world

The T2 world is a copy of the live base with only bay 1 built. Before the run, the test kit must:

1. **Build bays 2–5 on both sides,** matching `waypoints.lua` (floor, pillars, aisles), with **the same block
   under each dock slot as bay 1 has, including its NBT.** The ender chest under a docked turtle must keep bay
   1's frequency. Read it with `control.block_data` and copy it.
   **Do not `/clone` bay 1 with its turtles in it.** A cloned turtle is a copy of a computer: same ID, same files,
   and the same chunk-loader identity (see "Copied turtles share a chunk ticket"). Build from blocks, or clone the
   structure and remove every turtle before anything can tick.
2. **Place the ATC computer** with `control.spawn_computer` and the atc profile's files, as W3's
   `w3_atc_pair.py` already does.
3. **Add GPS towers:** at least 4 more than the 4 the live world has, spread out, each kept force-loaded. Use
   `spawn_computer` with `gps_host.lua`. This is the T2 proof for the "GPS 1" card **before the user builds the
   towers live.** The user asked for exactly that.
4. **Keep the whole base area loaded:** the building, both tunnels, the arrivals column and holding line
   (x 224–271), and the GPS towers. The arrivals-side chunk column in the T2 copy does not tick on its own (see
   "T2 Arrivals Side Dead").
5. **Place 160 fresh turtles,** each **already in the dock it will be assigned**, so the first switch-on is not
   a 150-turtle stampede (which W3 measured, 2026-11-04). Either seed the server's `dock_assignments.dat` to
   match where they stand, or register them in dock order. Every turtle must be **fresh**, never copied. Per
   role, each turtle needs:
   - its tools and upgrades;
   - fuel;
   - its slot items, **with their NBT**: the fuel and ore ender chests at the right frequencies, and each miner's
     loader turtle item.

   **Each loader item must get its own chunk-loader identity.** Prove it before the run: two loaders placed far
   apart must both hold their chunks. `control.set_slot` cannot set item NBT today; it needs that.
6. **Save a checkpoint** (`control.save_point`) of the finished world, so a void run can restart from it
   without rebuilding.

### 4.3 What the control mod and the runner can already do

The kit is mostly assembly of existing pieces:

| Need | Exists today | Missing |
|---|---|---|
| Place a fresh turtle with role code, fuel, upgrades | `control.spawn_turtle` | item NBT in `set_slot` |
| Place the ATC computer | `control.spawn_computer` + atc profile (W3) | — |
| Place GPS towers | `control.spawn_computer` + `gps_host.lua` | tower positions |
| Ender chest under each dock | `block_data` + rcon `setblock` with NBT | a helper that copies bay 1's |
| Build the bays | rcon `fill` / `setblock` | a builder from `waypoints.lua` |
| Keep areas loaded | rcon `forceload` (used by W3) | the full area list |

## 5. Everything goes wrong

The user's words: "Everything. I want everything that can go wrong." Faults fire **at random times from a seeded
schedule**, so any failure can be replayed exactly. The schedule is written to the run folder before the run
starts, and every fault that fires is listed under INTERVENTIONS in the report.

| Fault | How (existing tool where there is one) |
|---|---|
| Central server computer crashes and comes back, including back to back | `control.shutdown` / `turn_on` on its id |
| The whole Minecraft server restarts, including up-then-straight-down and **5 in a row** | `control.server_crash` / `restart_after_crash` / `world_restart` |
| ATC computer crashes and comes back | `shutdown` / `turn_on` on its id |
| Warehouse computer crashes | `shutdown` / `turn_on` |
| Bridge down, or slow | stop and start the T2 bridge process; a delay proxy for slow |
| Server disk fills or nearly fills | write a filler file into the server computer's disk folder, then remove it |
| Radio loss and delay, in bursts | `control.radio_loss` / `radio_latency` |
| GPS towers silent: one, several, or all | `control.gps_down` / `gps_up` |
| Chunks unloading under working turtles | `control.chunk_unload(area=...)` |
| Storage stalls or goes offline | `control.rs_stall` / `rs_offline` / `peripheral_stall` |
| Game lag | `control.tps_drop` |
| Storage full for a while | `rs_offline`, or filling the warehouse's storage, then clearing it |
| **One turtle** rebooted, or switched off and on, in the middle of an action (a dig, a move, a refuel, a dump) | `shutdown` / `turn_on` on one id; `turtle_reboot` in the sim |
| One turtle picked up and put back turned | `control.turtle_move` with a new facing |
| One turtle low on fuel, or with a full inventory | `control.set_fuel` / `set_slot` |
| One turtle missing an item it needs (its loader, an ender chest) | `control.clear_slot` |

The user asked for "everything", so faults to single turtles are included. A turtle with a **missing item**
cannot fix that alone. For it, the check is that it asks clearly for hands, holds safely, and blocks nobody.
It is counted as **expected hands**, separate from decommissioned.
| **A crash during recovery** from the last one | the schedule places some faults inside the recovery window of the previous one |

Each fault type fires at least several times over the run, and the 5-in-a-row restart burst fires at least
once. Exact rates are the builder's call, stated in the schedule file.

**What "replayed" means (spec owner's call):**
- On the test server the seed reproduces the **schedule**, not the outcome, because real Minecraft timing varies.
- The schedule uses the **simulator's fault names**, so the same schedule also runs in the simulator, which is
  deterministic. A finding gets its seed and schedule on its card, and the engineer can try it in both.
- Reproducing a test-server failure exactly in the simulator is welcome, but not required.

**The watchdog knows the schedule.** `watch_run.py` marks a run VOID when the fleet goes quiet. The scheduled
bridge-down faults and restart bursts go quiet on purpose, so the schedule is passed to it and expected silences
are excused. A silence that is NOT on the schedule still voids the run. Its time limit is raised to cover 24 hours.

## 6. Speed and length

- **Length: 24 real hours, no matter what** (the user). At about 3x that is about 3 game days.
- **Speed: the highest steady speed the server holds** with all 160 turtles working. It is found by a ramp
  before the run (for example 1x, 2x, 3x, 4x, each held long enough to settle). Pick the fastest speed whose
  mean tick time stays under 80% of its budget. At 3x the budget is 16.7 ms a tick.
  Measured today: about 4–8 ms a tick with 16 turtles at 1x, so 160 turtles may not hold 3x.
  **If even 1x does not hold with 160 turtles, stop and tell the user.** Do not quietly shrink the fleet.
- Host: sleep on mains power is "never" (2026-11-03), and the user holds Windows Update off for the run.
  `watch_run.py` runs throughout.

## 7. The report

Statistics, built for finding and fixing problems (the user's list):

- **Turtles that got stuck or failed:** how many, which, and why. The why is quoted from log lines, never guessed.
- **Traffic jams:** how many, and whether each one cleared, with how long it took.
- **Jobs completed,** by type.
- **Server downs:** every fault fired, by type.
- **Turtles decommissioned:** how many, and why.

The spec owner adds:

- **Every problem found becomes a board card,** with its log lines and its replay seed.
- **The first 6 hours against the last 6 hours** (real time, whatever the speed): the same counts side by side,
  per hour and per fault fired, so drift shows. **Judged, it fails** if anything that should stay flat grows
  steadily: server disk used, Lua memory on any computer, the queue of waiting jobs, the time a recovery takes.
  Ordinary rates (jams, stuck turtles, jobs done) are **reported, not judged**, because random faults make them
  noisy.
- **Every verdict states its evidence count.** A jam count of 0 next to "jam detector fired 0 times on the
  known-jamming control run" is not a pass.

## 8. Before the run: prerequisites, in order

1. **W5 (baton since 2026-11-09):** the bridge slow-push card. The run is about 10 times today's bridge traffic.
2. **W1:** after a restart, turtles resume the job where they stand. The shakeout restarts everything
   constantly, so it should test the behaviour we keep, not the fly-home behaviour that is being replaced.
3. **W3:** per-bay turtle types (4.1), through both layers.
4. **SANDBOX:** the test kit (4.2), the fault scheduler (5), the speed ramp (6) and the report (7). That
   includes the proof runs:
   - the jam detector fires on master without the ATC;
   - two loaders placed far apart both hold their chunks;
   - one fault of every type, fired once, shows up in the report.
5. **Optional dress rehearsal in the simulator:** 160 turtles and the same fault schedule, for a simulated week.
   It is cheap, and it shakes out the kit before the 24 hours.
6. **The 1x side test,** then **the 24-hour run.**

Any known issue still open at run time goes into the report as EXPECTED, so it does not drown out new findings.

## 9. Left to the builder

- Exact fault rates and the schedule format.
- GPS tower positions (spread, height, how many beyond 4).
- How long each ramp step lasts.
- How a "traffic jam" is detected: turtles off their docks and not moving for more than a stated time, in or
  near the base.
- How bays 2–5 are built, as long as the rules in 4.2 hold.
- The report's file format.
