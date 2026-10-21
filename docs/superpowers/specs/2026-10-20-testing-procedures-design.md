# Testing procedures: three layers and a watcher

- **Status:** design. Written 2026-10-20 by the spec owner and revised the same day to the user's three-layer
  procedure.
- **Not in force yet** (user, 2026-10-20): no card moves on simulator evidence until all three layers exist.
  Until then the simulator is used to investigate and is made more accurate (the fidelity-gaps card), and
  layer 2 is built next. Cards keep moving as they do today.
- **Origin:** the user, 2026-10-20.
  1. An engineer tests the change and the simulator proves it.
  2. A sped-up local test server proves it in real Minecraft, and the card moves to
     **"Done - not server validated"**.
  3. A **watcher** reads the live server's logs on a loop and validates each such card against conditions
     the engineer wrote on it. If it worked, the card goes to Done. If not, it goes back to the engineer, who
     works out with the simulator builder why layers 1 and 2 let it through.
- **User decisions, 2026-10-20:**
  - The local test server is a dedicated server; single player is only for watching.
  - Code under test reaches it as a pinned GitHub commit.
  - The modpack is the user's Modrinth instance, `SakuraPack 1.0.0`. It is kept identical to the server's
    (mods, data packs, resources) by the sync program, so no pack download is needed.
  - The 2026-10-18 world backup is current, because nobody has played since.
- **Builds on:** `2026-10-18-sandbox-simulator-design.md` (the simulator, **T1**) and
  `2026-10-20-sandbox-calibration.md` (T1 against the live fleet: within 1% on job time and ore on a live
  three-sector job).

## 1. Why

The live server is the bottleneck. One mining job takes hours, there is one fleet, and deploys need it idle.
T1 runs a six-hour job in about a minute, but it only knows the Minecraft rules someone wrote into it. A real
Minecraft copy (**T2**) finds mechanics bugs, but runs only a few times faster than real time. And only the
live server (**T3**) is the truth.

So a change climbs the layers. Its final validation comes from the live logs, read by a watcher, against
conditions written down before the change shipped.

## 2. The layers

| Layer | Where | Who runs it | Speed | Repeatable? | Proves |
|---|---|---|---|---|---|
| **1. Engineer + simulator (T1)** | `sandbox/` on this PC | the engineer who made the change | ~200-400x | yes, same seed gives the same trace | logic, messages, timing, dispatch, recovery, faults on demand, updates, long soaks |
| **2. Local test server (T2)** | a dedicated copy of the live server on this PC (section 6) | the same engineer | measured first (6.8) | comparable when started fresh (6.3) | real Minecraft and mod mechanics, real peripherals, real `server.js`, real update path |
| **3. Live validation (T3)** | the live server's logs | the **watcher** (section 5) | real time | no | that the fix worked where it matters |

## 3. What each layer must show

A change is classified by **what could go wrong**, not by which file it touches. If it fits several rows,
the strictest applies.

| Kind of change | Layer 1 | Layer 2 |
|---|---|---|
| Messaging, timing, dispatch, job lifecycle, crash/restart/reboot recovery, GPS handling, update/install logic | full proof, including the faults | a smoke run: boots, works in real Minecraft |
| A fix whose only trigger is a fault T2 cannot stage (radio loss or latency, 6.6) | full proof, fault scenario attached | smoke run; the card names the fault left to T1 |
| Mining, digging, ore, inventory, fuel, item transfer, chests, ender chests | optional, if it helps | **full proof** |
| Movement through real terrain, pathing, flight lanes, chunk loading | optional | **full proof** |
| Peripherals: Refined Storage bridge, geo scanner, cloud store, chunk loader | optional | **full proof** |
| Performance or speed claims | indicative only | **measurement** (or a live measurement) |
| Bridge or dashboard (`server.js`, `public/`) | contract tests | **full proof** with the real `server.js` (6.5); UI changes also need a person to look |
| The simulator itself (`sandbox/`) | its tests and determinism check | a T2 comparison when it changes a modelled mechanic |
| Docs, tools that never touch the fleet | none | none |
| **Emergency** (fleet stranded, data at risk) | **with the user's OK**, straight to live; layers 1 and 2 added afterwards, and the card says so | |

**Only layer 2 moves a card to "Done - not server validated".**

## 4. The card

### 4.1 Flow

```
To do -> In progress -> layer 1 -> layer 2 -> Done - not server validated -> (watcher: VALIDATED) -> Done
                                                    |
                                                    +-- (watcher: FAILED) -> In progress, back to the engineer,
                                                         who mails SANDBOX: why did layers 1 and 2 pass it? (section 7)
```

**Needs measuring** keeps its meaning (fixed, waiting for a live measurement). Those cards get the same
validation block (4.2) when their owner next touches them, and from then on the watcher validates them too.

### 4.2 The validation block: written by the engineer, before the card leaves layer 2

The card body ends with this block. Without it, the card cannot enter "Done - not server validated".

```
VALIDATION
Code:        <release / commit sha the fix shipped in>
Layer 1:     <scenario + seed, report path, one-line result>
Layer 2:     <run folder, report path, one-line result>
Situation:   <what must happen live for a verdict, e.g. "a miner reboots mid-flight">
Worked if:   <log lines or measurement that prove it worked, exact text or pattern, and the count needed>
Failed if:   <log lines or measurement that prove it did not>
Not before:  <the deploy time; older logs do not count>
Wait up to:  <days, default 7>
```

**Worked if** and **Failed if** must be checkable from the bridge's `/logs` and `/state` (or a tool in `tools/`
that reads them), and must be able to disagree. A condition whose pass looks like "no matching lines" is not
allowed on its own; it needs a positive count of the situation occurring
(`feedback-checks-must-be-able-to-fail`).

## 5. The watcher

### 5.1 What it is

A Sonnet instance run on a schedule, **every 6 hours**. Mail name `WATCHER`. It reads, judges and reports. It
changes nothing on the server or in the code.

### 5.2 Each run

1. List the cards in **Done - not server validated** (and **Needs measuring** cards that have a validation
   block).
2. For each card:
   - read its validation block;
   - fetch the live logs from **Not before** to now (`/logs/<date>` per day; see the two traps in
     `reference-system-access`);
   - count the **Situation**, **Worked if** and **Failed if** matches.
3. Give one verdict per card:
   - **VALIDATED.** The situation occurred at least the required number of times, every occurrence matched
     *Worked if*, and none matched *Failed if*. Move the card to **Done**. Mail the engineer with the counts and
     two example log lines.
   - **FAILED.** Any *Failed if* match. Move the card to **In progress**. Mail the engineer and SPEC-OWNER with
     the matching lines, their times and the node.
   - **NOT YET.** The situation has not occurred often enough. Append a dated line with the counts to the card;
     no move.
   - **TIMED OUT.** *Wait up to* has passed with no verdict. Mail the engineer and SPEC-OWNER. The engineer
     arranges a deliberate live test, and with the fleet involved, that goes through the user.
   - **CAN'T JUDGE.** The block is missing, or a condition cannot be checked from the logs. Mail the engineer;
     no move.
4. Append a one-line summary of the run to `docs/watcher/LOG.md`, with the number of cards per verdict.

### 5.3 Rules

- **Read-only on the live system.** It uses `GET /logs`, `GET /logs/<date>` and `GET /state` only. It never
  sends a `/command`, never deploys, and never touches the server PC.
- **Every verdict carries its evidence count.** "0 failures" means nothing without "situation seen N times".
- **It does not interpret causes.** On FAILED, it reports the lines; the engineer works out why
  (`feedback-ask-dont-guess`).
- **It moves cards only** between "Done - not server validated", "Needs measuring", "In progress" and "Done",
  and only as above. Card bodies are drafts, edited through their draft-issue id (`reference-project-board`).
- **It runs on this PC and reaches the bridge on the LAN,** as the engineers' tools already do.
- **Cost:** one short run every 6 hours; nothing to do means a one-line log entry and stop.

### 5.4 When a fix fails live

The engineer owns the fix and the follow-up:
1. fix the code, and climb the layers again;
2. mail SANDBOX with the failing live lines and ask why layers 1 and 2 passed it. The answer becomes either a
   simulator or test-server fidelity card, or a better layer-2 scenario. Either way the gap is written down, so
   the next change of the same kind is caught before it ships.

## 6. Layer 2, the local test server

### 6.1 Form

A **dedicated Minecraft server** (no game window) running the live modpack on this PC, started and stopped by
a tool. **Single player** is a watch mode only: the user opens a run's world copy in their own game to look.

### 6.2 Where it lives

`G:\TurtleOS-Sandbox\testserver\` holds three folders:
- `server\` is the Forge 1.20.1 dedicated server, with mods, configs, KubeJS scripts and data packs copied from
  the instance `C:\Users\shama\AppData\Roaming\ModrinthApp\profiles\SakuraPack 1.0.0`, read-only;
- `worlds\` holds read-only world copies;
- `runs\<run-id>\` holds a disposable working copy, logs and a report per run.

The code that drives it lives in the repo under `sandbox/t2/`. **The user's instance is never written to.**
A client instance may hold client-only mods (sounds, shaders, minimaps) that a dedicated server refuses. Phase 0
lists any it has to leave out of `server\`, and the report names them.

### 6.3 Every run starts fresh

Each run unpacks a named world copy into a new run folder. Today that copy is
`worlds\unpacked\2026-10-18_1700`, the current world per the user. Comparability comes from the same world,
same code and same scenario. A timing claim needs at least two runs, and the report gives both.

### 6.4 Safety: cannot touch the live server, by construction

- **Each run's `computercraft-server.toml` HTTP rules are rewritten before first start.** Allow `127.0.0.1:3000`
  (the local bridge) and `raw.githubusercontent.com` (the code, 6.7); **deny everything else, including
  `$private`**. The live copy allows all private addresses today. The tool refuses to start a run whose rules
  differ.
- **The fleet code itself never names the live server.** The server pushes to `http://127.0.0.1:3000/update`
  (`central_server.lua:96`), and `updater.lua` fetches from GitHub. The rule still applies, because turtles
  carry other files.
- **Own ports, own RCON password**, local only. Server-side mods with outside connections run locally or are
  off, and the report lists which.

### 6.5 The bridge and dashboard

The **real `server.js`** runs on `127.0.0.1:3000` with logs in the run folder, so pushes arrive exactly as live.
The dashboard is at `http://127.0.0.1:3000/`. `tools/gate_check.py` and `tools/ack_loss.py` use `BRIDGE_URL`.

### 6.6 Control: the same verbs as T1 where Minecraft allows

| Verb | T1 | T2 (exact commands proven in phase 2) |
|---|---|---|
| `snapshot` / `restore` | yes | restore = a fresh run from a world copy |
| `teleport`, `spawn` a turtle, set inventory / fuel | yes | proven 2026-10-20 except spawn: `/clone ... replace move` teleports **without a reboot** (the turtle then acts on its old position until its next GPS fix); fuel and slots set by NBT |
| `server_crash`, `world_restart` | yes | yes: stop or kill the process, start again |
| `server_lag`, `tps_drop` | yes | yes: tick-rate control |
| `gps_down` | yes | yes: shut the GPS hosts down |
| chunk unload | yes | **no without the test mod**: loader turtles hold Advanced Peripherals chunk tickets that no console command removes (phase 2, 2026-10-20) |
| `radio_loss`, `radio_latency` | yes | **no**, T1 only |

A verb T2 lacks raises a clear error. It is never faked.

**More control, added 2026-10-20 at the user's request:**
- **Reading any computer's disk during a run.** The disks are plain folders under the run's world, read
  without disturbing the computer.
- **Mid-run save points.** `save-all`, a copy of the world folder and the run folder, and a restore later from
  that copy.
- **Single-turtle save and restore:** position, inventory, fuel, upgrades and its disk folder.
- **A radio listener computer** at the base, logging fleet traffic on the channels it can open, until the test
  mod (6.10) replaces it.

### 6.10 The test-only mod (planned; spec to be written later)

A small server-side Forge mod, installed **only** in `testserver\server\mods\` and never in the user's
instance or on the live server. The T2 tool refuses to start if the mod's jar is found anywhere else. It gives
T2 the control real Minecraft lacks:
- every radio message logged;
- radio loss and latency on demand;
- every event each computer receives, logged;
- chunk unload under a loader turtle;
- single-turtle save and restore;
- peripheral stalls on demand;
- pause and single-step;
- all of it driven by script, with the same verbs as T1.

Running Lua on a computer mid-run is a stretch goal. Exact replay stays impossible.

**Spec: `2026-10-20-t2-control-mod-design.md`** (written 2026-10-20 at the user's direction). It is built in phases
M0-M7 there, each reported before the next.

### 6.7 Which code runs

The code under test is pushed to GitHub on a branch, and each computer is pinned to that commit through
`update_ref.txt`. `updater.lua` already supports a pinned 40-character sha, so the real update path is
tested too.

### 6.8 Speed: measured before anyone relies on it

Phase 0 measures one server tick's time with the base and fleet chunks loaded and nobody logged in. The
ceiling is about 50 ms divided by that. It then tries Forge 1.20.1 tick-rate mods (Madgique's Tickrate
Changer, OverClocked: Clockworks, Tick Changer) **on the T2 copy only, never the live server or the user's
instance**, and records the speed reached. It also lists the fleet's real-clock (`os.epoch`) timing and states
the highest speed at which fleet behaviour is unchanged.

**Measured 2026-10-20 (phase 0 report).** CC:Tweaked 1.120.2 timers (`os.startTimer`, `sleep`) count server
ticks, while `os.epoch` reads real time, and the fleet times most deadlines with `os.epoch`. So at N times speed,
a deadline of D real seconds spans N x D game-seconds. **Timeouts become more lenient, and timeout bugs can hide.**

Rule: **T2 at speed proves mechanics, not timeout behaviour.** A change whose risk is a timeout, a heartbeat
or a deadline is proven in T1, or in T2 at 1x.

### 6.9 The run report

The same sections as T1's report: code sha, world copy, speed, CHECKS, INTERVENTIONS, tool output, jobs, ore
and problems. **NOT STAGED** takes the place of NOT MODELLED, and lists the faults left to T1 and the mods
left out.

## 7. The layers keep each other honest

- A layer-2 proof of a change that layer 1 also tested includes the same scenario's T1 headline figures (job
  time, ore, batches, problems, ack loss) beside T2's. A gap beyond **±10%**, or a behaviour present in one and
  absent in the other, opens a simulator fidelity card. The change itself is judged on T2.
- Every T1 assumption marked "unverified - needs the local test server" gets a T2 check once T2 exists.
- A live FAILED (5.4) is the strongest signal of all. It always produces a written-down gap.

## 8. Live deploys

Unchanged:
- deploy only with the fleet idle (`feedback-ask-before-self-update`);
- wait for GitHub's cache (`feedback-wait-after-push`);
- verify the deploy landed (`feedback-verify-deploy-landed`).

## 9. Building it: phases

Owner: the sandbox builder (mail `SANDBOX`), under the `sandbox/` rules: no fleet file edits, data on the Game
Drive, and ask the user before installing anything.

0. **Measure T2.** Build `server\` from the instance (6.2), start it once with safe HTTP rules on the world copy,
   and record tick time, memory and start-up. Try the tick-rate mods, list the real-clock uses (6.8), and
   **report to the user before building further**. If T2 cannot reach about 2x, the plan is re-weighed.
1. **A safe run tool.** Run folder from a world copy, HTTP rules rewritten, local `server.js`, pinned code, clean
   stop. Test: it refuses rules that allow `$private`.
2. **Control verbs**, proven one by one (6.6).
3. **Scenarios and reports** (6.9); T1 scenarios run unchanged where their verbs exist.
3b. **The test-only mod** (6.10): its spec is written once phases 0-1 and the fidelity gaps are done; then built,
   and the `radio_loss` / `radio_latency` rows of 6.6 become available on T2.
4. **The watcher** (section 5). It needs no T2, so it can start in parallel with phase 0:
   `docs/watcher/LOG.md`, the scheduled task, and a dry run against today's board. The spec owner sets up the
   schedule with the user's OK.
5. **First full climb.** One open card goes through all three layers; the user picks which.

## 10. Remaining open points

1. Tolerance for T1/T2 disagreements (7), starting at ±10%; tune after the first comparisons.
2. Whether the watcher also chases the 23 **Needs measuring** cards from day one, or only as their owners add
   validation blocks (4.1). Default: only with blocks.
