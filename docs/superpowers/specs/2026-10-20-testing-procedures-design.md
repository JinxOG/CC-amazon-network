# Testing procedures: simulator, local test server, live server

- **Status:** design, written 2026-10-20 by the spec owner at the user's direction.
- **Origin:** the user's proposal, 2026-10-20. Prove a change in the simulator first. Then prove it on a sped-up
  test server on this PC, a real Minecraft copy of the live server. Only then does its card move to
  "Done - not yet seen on the real server", and the live server has the final word.
- **Builds on:** `2026-10-18-sandbox-simulator-design.md` (the simulator, called **T1** here) and
  `2026-10-20-sandbox-calibration.md` (how far T1 matches the live fleet).

## 1. Why

The live server is the bottleneck. One mining job takes hours, there is one fleet, and deploys need it idle.
T1 cut a six-hour job to about a minute and matched a live three-sector job to within 1% on job time and ore.
But T1 only knows the Minecraft rules someone wrote into it. It cannot find a bug that lives in a mechanic
it does not model: drops, full inventories, liquids, falling blocks, item entities, mod peripherals.
A real Minecraft server finds those, but runs only a few times faster than real time.

So there are three tiers. Each proves what it is good at, and a card cannot skip a tier that its kind of
change needs.

## 2. The three tiers

| Tier | What it is | Speed | Same result every run? | Good at | Blind to |
|---|---|---|---|---|---|
| **T1 Simulator** | `sandbox/`: the real fleet files on a simulated world and clock | ~200-400x | Yes (same seed, same trace) | Messages, timing, dispatch, recovery, faults on demand, updates, long soaks, replaying incidents | Everything in its report's NOT MODELLED list |
| **T2 Local test server** | A copy of the live modded server, running on this PC from a world backup | Unknown: measure first (section 6.8); expected a few times real time | No; comparable only by starting fresh each run (6.3) | Real Minecraft and mod mechanics, real peripherals, real `server.js`, real OTA install | Faults Minecraft cannot stage (6.6); real players; the server PC's own hardware and load |
| **T3 Live server** | The real server and fleet | 1x | No | The truth | Nothing, but every test costs real hours and the fleet |

## 3. Which tier proves what

A card's change is classified by **what could go wrong**, not by which file it touches. If it fits several rows,
the strictest row applies.

| Kind of change | Minimum proof before "Done - not yet seen on the real server" | Notes |
|---|---|---|
| Messaging, timing, dispatch, job lifecycle, recovery after crash/restart/reboot, GPS handling, update/install logic | **T1 pass, then a T2 smoke run** | The T2 run proves it boots and works in real Minecraft. The faults themselves are proven in T1 |
| A fix whose only trigger is a fault T2 cannot stage (radio loss, radio latency, see 6.6) | **T1 alone**, with the fault scenario in the evidence | The card says which fault and why T2 cannot stage it |
| Mining, digging, ore handling, inventory, fuel, item transfer, chests, ender chests | **T2 pass** (T1 first if useful) | T1 guesses here; see its ASSUMPTIONS |
| Movement through real terrain, pathing, flight lanes, chunk loading | **T2 pass** | |
| Peripherals: Refined Storage bridge, geo scanner, cloud store, chunk loader mod | **T2 pass** | |
| Performance or speed claims ("faster", "less CPU") | **T2 or T3 measurement** | T1's cost model is calibrated in total, not per function |
| Bridge or dashboard (`server.js`, `public/`) | **T2 pass**: the real `server.js` runs locally against T2 (6.5) | UI changes also need a person to look at the page |
| The simulator itself (`sandbox/`) | Its own tests + determinism check | Plus a T2 comparison when it changes a modelled mechanic |
| Docs, tools that never touch the fleet | None | |
| **Emergency** (fleet stranded, data at risk) | T3 directly, **with the user's OK** | The T1/T2 evidence is added afterwards, and the card says so |

**A T1 pass alone never moves a card past In progress**, except for the fault-only row above.

## 4. Card flow

```
To do -> In progress -> (T1 pass) -> (T2 pass) -> Done - not yet seen on the real server -> (T3 seen) -> Done
                         \_ T1 fail or T2 fail: back to In progress; a T1/T2 disagreement also opens a simulator card (section 7)
```

- **Needs measuring** stays for work waiting on live evidence that T2 cannot give, such as live ack-loss
  regimes or long-run behaviour of the real server PC.
- **"T3 seen"** means the change ran on the live fleet in the situation it is about, and the engineer quotes the
  live log lines or the measurement. "Deployed and nothing broke" is not "seen".

## 5. Evidence: what every tier's proof contains

Attached to the card (comment or mail linked from it). Without it, the tier does not count.

1. **Tier, code and date:** commit sha of the fleet code under test; for T1 also the sandbox commit.
2. **Starting point:** T1 scenario file and seed; T2 world copy name (6.3) and the run folder.
3. **What was checked,** stated so it can fail: the expected result *and* what a failure would have looked
   like (see `feedback-checks-must-be-able-to-fail`). A check whose pass looks like "no data" does not count.
4. **The report:** T1 `report.md`; T2 run report (6.9). Both carry **INTERVENTIONS**. A run with an
   intervention is not proof unless the intervention is the test.
5. **NOT MODELLED / not stageable:** for T1, confirm the change does not depend on anything in that list; for
   T2, name any fault that had to be left to T1.

## 6. T2, the local test server

### 6.1 Form

A **dedicated Minecraft server** (no game window) running the live server's exact modpack, on this PC.
It runs without anyone at the keyboard, can be started and stopped by a tool, and leaves the gaming PC usable.
**Single player** is kept only as a *watch mode*: the user opens a T2 world copy in their own game to look at
something. It is never the proof run.

### 6.2 Where it lives

`G:\TurtleOS-Sandbox\testserver\`:
- `pack\` is the server files: Forge, mods and configs, matching the live server's mod list exactly;
- `worlds\` holds world copies, read-only;
- `runs\<run-id>\` holds one disposable working copy per run, plus logs and the report.

Nothing goes in the repo; the code that drives T2 lives in the repo under `sandbox/t2/`.

### 6.3 Every run starts fresh

Each run unpacks a named, read-only world copy into a new run folder. Today that copy is
`worlds\unpacked\2026-10-18_1700`. Real Minecraft does not repeat itself, so comparability comes from the
same world, same code and same scenario. A timing claim needs at least two runs, and the report gives both.

### 6.4 Safety: cannot touch the live server, by construction

- **The run's `computercraft-server.toml` HTTP rules are rewritten before first start.** Allow
  `127.0.0.1:3000` (the local bridge, 6.5) and the code source (6.7); **deny everything else, including `$private`**.
  The live copy allows all private addresses today, so this rewrite is mandatory. The T2 tool refuses to
  start a run whose rules do not match.
- **The fleet code itself never names the live server.** The server pushes to `http://127.0.0.1:3000/update`,
  same machine, and `updater.lua` fetches from GitHub. Checked 2026-10-20 (`central_server.lua:96`). The
  rule above still applies, because turtles carry other files on their disks.
- **Own ports, own RCON password**, local-only. T2 never runs `/self-update`, `/command` or anything else
  against the live bridge or server.
- **Server-side mods with outside connections** (for example Dynmap, the CloudSolutions store) run in local
  mode or are switched off, and the run report lists which.

### 6.5 The bridge and dashboard

The **real `server.js`** runs locally on `127.0.0.1:3000`, with its logs going to the run folder, so the
fleet's pushes arrive exactly as live. The dashboard opens at `http://127.0.0.1:3000/`.
`tools/gate_check.py` and `tools/ack_loss.py` read it through `BRIDGE_URL`. Dynmap works if the pack
includes it; it does not need to for a run to count.

### 6.6 Control: the same verbs as T1 where Minecraft allows

Test scripts use one vocabulary (T1 design section 7.1) and run against either tier. Where T2 cannot do a
verb, it says so loudly. It never fakes the verb.

| Verb | T1 | T2 (via server console / RCON / ComputerCraft's own commands; exact commands confirmed in phase 2) |
|---|---|---|
| `snapshot` / `restore` | yes | restore = start a fresh run from a world copy; mid-run snapshot not offered |
| `teleport` a turtle, `spawn` a turtle, set inventory / fuel | yes | via block and NBT commands; to be proven per verb |
| `server_crash`, `world_restart` | yes | yes: kill or stop the server process, start it again |
| `server_lag`, `tps_drop` | yes | yes: tick-rate control (6.8) |
| `gps_down` | yes | yes: shut down the GPS host computers |
| chunk unload | yes | yes: remove the force-load |
| `radio_loss`, `radio_latency` | yes | **no**; T1 only (section 3, fault-only row) |
| `eval` on a computer | yes | limited; via the computer's own shell if needed |

### 6.7 Which code runs

Default: the real OTA path. The code under test is pushed to GitHub on a branch, and each computer is pinned to
that commit through `update_ref.txt` (`updater.lua` already supports a pinned 40-character sha). This also
tests the installer for free. Open decision 10.2 is whether to also allow serving a local worktree without pushing.

### 6.8 Speed: measured before anyone relies on it

Phase 0 (section 9) measures **how long one server tick takes** with the base and the fleet's chunks loaded,
and nobody logged in. The ceiling is roughly 50 ms divided by that figure. A Forge 1.20.1 tick-rate mod is then
added and the speed actually reached is measured. Candidates: Madgique's Tickrate Changer, OverClocked:
Clockworks, Tick Changer. Pick by measurement, not description.

**Clock risk to check in phase 0:** some fleet timing uses the real wall clock (`os.epoch`) rather than game
ticks. At high speed-ups those timeouts stretch relative to game time. Phase 0 lists every wall-clock use and
states the highest speed at which fleet behaviour is unchanged. The run report records the speed used.

### 6.9 The T2 run report

The same headings as T1's: what ran (code sha, world copy, speed), CHECKS, INTERVENTIONS, the tools' output,
jobs, ore, problems. It adds **NOT STAGED** in place of NOT MODELLED: faults left to T1, mods switched off.

## 7. T1 and T2 keep each other honest

- Every T2 proof run of a T1-tested change also runs the same scenario in T1 and compares the headline figures.
  Those are job time, ore, batches, problems and ack loss.
- **A disagreement beyond a stated tolerance opens a simulator card** for the sandbox builder.
  The starting tolerance is ±10% on job time and ore, and any behaviour present in one tier and absent in the
  other. The change under test is then judged on T2.
- Every T1 assumption marked "unverified - needs the local test server" gets a T2 check when T2 exists. The
  result goes back into the sandbox. That is the second half of the open fidelity-gaps card.

## 8. T3, the live server

Unchanged rules: deploy only with the fleet idle (`feedback-ask-before-self-update`), wait for GitHub's cache
(`feedback-wait-after-push`), verify the deploy landed (`feedback-verify-deploy-landed`). What changes is that
a change reaches T3 already proven in T1 and T2, so a live run confirms rather than discovers.

## 9. Building T2: phases

0. **Measure.** Get the live pack (10.3). Start it once on this PC, with safe HTTP rules (6.4), on the world
   copy, nobody logged in. Record tick time, memory and start-up time. Try the tick-rate mods; record the speed
   each reaches. List the wall-clock uses (6.8). **Stop here and report to the user before building anything
   else**: if T2 is under about 2x, the plan is re-weighed.
1. **A safe run.** A tool creates a run folder from a world copy, rewrites the HTTP rules, starts the local
   `server.js` and the server, pins the code (6.7), and stops it all cleanly. Test: the tool refuses a run whose
   rules allow `$private`.
2. **Control verbs.** Each verb in 6.6, proven one by one; the unavailable ones raise a clear error.
3. **Scenarios and reports.** A T1 scenario file runs on T2 unchanged where its verbs exist; the report as 6.9.
4. **First real proof.** One open card goes T1, then T2, then "Done - not yet seen", following this document;
   the user picks which. Then the T1-assumption checks (7).

Owner: the sandbox builder (mail `SANDBOX`), under the same rules as `sandbox/`. That means no fleet file edits,
data on the Game Drive, and asking the user before installing anything.

## 10. Open decisions

1. **Dedicated server vs single player:** recommended dedicated (6.1); the user has not ruled.
2. **Code delivery:** pinned GitHub commit only (recommended, it is the real path), or also local serving.
3. **Where the pack comes from.** The server's `/mnt/backup/archive/pre-deploy-tar/` holds a 5.6 GB pack
   tarball from 2026-10-04, which may predate later mod changes. The safest source is a fresh copy of the
   live server's `mods/` and `config/`, fetched the same way as the world (the user runs a script; nothing
   here holds the password). The server PC engineer confirms the current mod list.
4. **Tolerance** for T1/T2 disagreements (7), starting at ±10%: tune after the first few comparisons.
