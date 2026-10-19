# The sandbox — a fast, local copy of the server for testing

- **Owner:** Spec owner / head engineer (design and plan). **Built by:** a
  separate Sonnet instance, from the plan that follows this document.
- **Date:** 2026-10-18
- **Status:** Draft for the user's approval.

---

## 1. Why

Every card on the board closes only after a real mining job of about **six
hours** on the live server. A failed test costs another six. The board has been
open about a month, and most of that month was waiting.

The sandbox lets engineers run those tests on this PC **in minutes**. The user's
target: **a week of testing in about 30 minutes** — roughly 300× real time. The
real server stays the final check, and should only ever turn up small,
granular issues.

## 2. Goals, non-goals, anti-goals

**Goals**

1. **Run the real fleet programs, unchanged.** The same `central_server.lua`,
   `turtle_base.lua`, `ore_turtle.lua`, `warehouse.lua` and the rest — the files
   in an engineer's worktree, not rewritten copies. A test of a fix is a test of
   the fix.
2. **≥300× real time** on a two-miner mining job (§9 sets the bar).
3. **Built from a copy of the real server world**: terrain, ores, the base, the
   fleet's positions and inventories, every computer's disk, and the Refined
   Storage contents.
4. **Faults on demand** ("pull a string"): server crash and restart, world
   restart, lag, lost radio messages, GPS down, the storage system stalling,
   turtle reboots mid-action, disk full, and the rest in §7.
5. **Reproducible.** The same scenario with the same seed gives the same run,
   step for step, so a failure can be replayed until it is fixed.
6. **The existing tools work on it.** `tools/gate_check.py` and
   `tools/ack_loss.py` read sandbox runs the same way they read the live server,
   through the same HTTP endpoints (`/state`, `/logs`, `/logs/<date>`), with one
   change: an option to point them at a different bridge address (section 10.7).
7. **A live view for the user**: the real dashboard page (`public/`), served
   from the sandbox's stand-in bridge, in a browser.

**Non-goals**

- Rendering, players, mobs, crafting, redstone, anything the fleet never
  touches.
- Being a Minecraft server. It runs no Java and loads no mods.
- Replacing the real server as the final check.

**Anti-goals — it fails if any of these happen, however well the rest works**

- **It touches the real server or real data.** No path from the sandbox may
  reach the live bridge, the live Minecraft server, RCON, the cloud store, or
  the GitHub repo's write side. §10.
- **It passes things the real server would fail, quietly.** A fault the
  sandbox does not model must be listed as not modelled in every report (§11).
  Silent optimism is worse than no sandbox — it is the "check that cannot fail"
  this project keeps paying for.
- **The fleet code grows sandbox-only branches.** No `if SANDBOX then` in fleet
  files. The sandbox adapts to the code, never the reverse.
- **Its results cannot be reproduced.** A failure seen once and never again is
  a lead, not a test.

## 3. Shape — the decisions already made

These were settled with the user or are the spec owner's calls, marked as such.

| Decision | Who decided |
|---|---|
| The fast part is a **simulator**, not a real Minecraft server: real Minecraft with this modpack cannot run anywhere near 300× | Spec owner; user agreed |
| A slower real-Minecraft test copy may come later for things a simulator cannot fake (mod behaviour, chunk tickets). Not in this build | Spec owner |
| It is built from a copy of the server world, sent over SSH by the server PC engineer | User |
| Everything that matters about being on a server is modelled: downtime, crashes and recovery, lag, lost messages | User |
| The storage system, the dispatch server and the warehouse computer are all in it | User |
| The dashboard is not on this PC, so a **stand-in bridge** receives what the server sends | User asked for a stand-in |
| The stand-in is **not** the real `server.js`. It reimplements the bridge's contract on simulated time (4.1) | Spec owner — `server.js` runs on the real clock and cannot follow a 300x simulated one |
| A live view would be nice, "not necessary" | User |
| **Cards can close on sandbox results**, into a new board column, **"Done — not yet seen on the real server"** | User |
| The spec owner writes design and plan; **a Sonnet instance builds it** | User |
| What is off limits is the spec owner's call | User — see §10 |

## 4. How it works, in one picture

```
 sandbox/run/<run-id>/
 ┌────────────────────────────────────────────────────────────┐
 │  sim.lua  (one Lua 5.4 process)                            │
 │                                                            │
 │   virtual clock ── scheduler ── fault engine (scenario)    │
 │        │               │                                   │
 │   ┌────┴──────┬────────┴────┬───────────┬──────────┐       │
 │   computer    computer      computer    computer    ...    │
 │   (server)    (warehouse)   (turtle 138)(GPS host)         │
 │   own _ENV    own _ENV      own _ENV    own _ENV           │
 │   own disk    own disk      own disk    own disk           │
 │        │           │             │                         │
 │   world model ── radio ── peripherals (scanner, RS, KV,    │
 │   (blocks)     (channels)  ender chests, chunk loading)    │
 └──────┬──────────────────────────────────────────────────────┘
        │ http.request to 127.0.0.1:3000/*  (intercepted, in-process)
        ▼
  stand-in bridge (Lua, inside sim.lua, on simulated time)
        │ writes state.json and logs/<sim-day>.txt in the bridge's formats
        ▼
  sandbox/run/<run-id>/   <── tiny read-only Node file server, port 31xx:
                              /state  /logs  /logs/<date>  + public/ page
                              <── gate_check.py, ack_loss.py, browser view
```

**One process, many computers.** Each in-game computer (dispatch server,
warehouse, every turtle, every loader, the GPS hosts) becomes a Lua coroutine
with its **own global environment** and its **own disk folder**. Each boots its
own `startup.lua`, exactly as in game.

**A virtual clock.** Every time source the fleet reads — `os.epoch`,
`os.clock`, `os.time`, `os.date`, `os.startTimer`, `sleep` — reads the virtual
clock. When every computer is waiting, the scheduler jumps the clock straight to
the next thing that will happen. A six-hour job is mostly waiting, which is what
makes 300× possible.

**Turtle actions cost virtual time**, from a calibrated table (§8): a move, a
dig, a scan each advance that turtle's clock by what they take in game.

**So does computation (spec owner's call).** The fleet's own Lua work costs
virtual time, counted by a per-computer instruction-count hook
(`debug.sethook` with a count) at a calibrated rate of instructions per
simulated second. Counting instructions is repeatable; measuring real CPU time
is not. Without it the sandbox would pass the whole class of bug where a
computer is too busy to listen, which is what the payload deafness and the
storage-poll deafness both were. `server_lag(factor)` multiplies this cost. The
hook's overhead is measured against the §9 speed bar; if it threatens 300x, the
count interval is widened, never the hook removed.

### 4.1 The stand-in bridge (spec owner's call)

The real bridge (`server.js`) runs on the real wall clock: it names log files by
the real day, treats 20 real seconds of silence as a server restart, and stamps
`/state.serverTime` with real time. At 300x none of that lines up with a
simulated clock, and runs would stop being reproducible. So the sandbox does not
run `server.js`. Instead:

- **Inside the simulator, in Lua, on simulated time,** a stand-in implements the
  bridge's contract as the fleet and the tools see it: `POST /update` (the
  server's state push and its log lines), `POST /storage` (the warehouse),
  `GET /state` (with `serverTime` = simulated time), and the log store behind
  `/logs` and `/logs/<date>`: files named by **simulated** day, lines in the
  bridge's exact JSON format. Scenario files dispatch jobs through it the way
  `POST /command` with `ORDER_MINE` does.
- **A small read-only Node file server** serves those files and the real
  dashboard page over HTTP, for the tools and for the browser. It has no timers
  and no logic of its own.
- **Contract tests** pin the stand-in to `server.js`: the same requests produce
  responses of the same shape, field names and types, checked against
  `server.js`'s code and recorded live responses. When `server.js` changes its
  contract, these tests are what notice.
- **Bridge behaviour itself is a stated gap** in every report: the sandbox
  models the bridge's edges (`bridge_down`, `bridge_slow`, push timeouts as the
  server sees them), not `server.js`'s internals.

## 5. The CC behaviour it must reproduce exactly

These are not niceties. Each one has caused a real fleet bug, and a sandbox that
smooths them over would pass the very code that failed in the world.

| Behaviour | Why it matters here |
|---|---|
| **One event queue per computer, capped at 256.** Overflow drops events | Mailbox overload was months of disconnects |
| **A filtered `os.pullEvent("x")` discards every other event that arrives while it waits** | "Yields eat events" — the root of several outages |
| **`parallel.waitForAny` hands every event to every coroutine**, each applying its own filter | The doubled first order (21 of 22 jobs) came from exactly this |
| **`modem_message` carries** `side, channel, replyChannel, message, distance`, and only reaches computers with that channel **open** | The per-turtle channel fix depends on it |
| **Peripheral calls that yield** (`rsBridge.listItems`, `geo_scanner.scan`, `kv_storage` calls) take virtual time, during which the calling computer is deaf to everything except the result | The 29-second server deafness |
| **`http.request` is asynchronous** and answers with `http_success` / `http_failure` | The bridge push timeouts |
| **`os.reboot()` restarts the computer from `startup.lua`; files on disk survive; memory does not** | Every restart-recovery card |
| **Timers fire as `timer` events with their id; `os.cancelTimer` cancels** | The guaranteed-wakeup fix |
| **A turtle refuses to act when it lacks fuel, when the block is protected, or when another turtle is in the way** | The 120-second mutual block |
| **Computers in unloaded chunks do not run.** Time passes; they are frozen | Lost miners; the chunk-loading invariant |

**Method for faithfulness — the builder's call, within one rule.** The
`parallel` API and `os.pullEvent` should be the real CC:Tweaked implementations
if their licence allows them to be copied into the repo; otherwise reimplemented
to match their documented behaviour, with a test per row of the table above. The
existing `tests/stub_cc.lua` encodes a long list of hard-won turtle-inventory
fidelity fixes (display names, `drop()` onto nothing, `inspectUp`, real fuel
values). **Reuse it, don't re-derive it.**

**API surface.** Measured on master, 2026-10-18 — the fleet uses about 70 CC
functions. The heaviest: `os.epoch` (167 calls), `turtle.select`,
`turtle.getItemDetail`, `fs.open`/`exists`, `turtle.getItemCount`,
`os.startTimer`, `turtle.getFuelLevel`, `textutils.serialise`. Peripherals
found by type: `modem`, `rsBridge`, `kv_storage`; wrapped by side:
the geo scanner, the chunky turtle's peripheral, ender chests. **Anything the
fleet calls that the sandbox does not implement must raise a clear error naming
the function** — never return a plausible default.

## 6. The world

**Source: a finished backup, never the live world.** Answered by the server PC
engineer, 2026-10-18: copying `world_live/` while the server runs gives a torn
snapshot — region files written mid-copy, corrupt in ways that surface later.
Finished backups already exist and are consistent: the `mc-sync` pre-deploy
tarballs in `~/sakura/backups/` (5.7 GB on Oct 4), the hourly and daily backup
timers, and FTB Backups 2. **The sandbox imports from the latest backup.** A
current world instead needs a `save-off` / `save-all flush` / copy / `save-on`
cycle on the server, scheduled by the server engineer; it is never required.

Plan for **5-6 GB compressed** per copy. It lands in `sandbox/worlds/<date>/` on
this PC. **That folder is git-ignored**: it is the user's world, it is large,
and the repo is public.

**The transfer is done by a person, not by the sandbox.** The server accepts SSH
with a password; the sandbox and its tooling never hold, request or store SSH
credentials. The server engineer pushes the file, or the user pulls it.

**Import** — a Python tool, `sandbox/tools/import_world.py`, reads the copy and
writes a compact sandbox world into `sandbox/worlds/<date>/sim/`:

| What | From | Notes |
|---|---|---|
| Blocks | the region files (`region/*.mca`) | Only the chunks that matter: the base, the depot, and every mining zone, plus a margin. Stored per chunk so the simulator loads chunks lazily |
| Computer and turtle disks | `computercraft/computer/<id>/` | Every computer boots from its real files: `startup.lua`, `jobs.dat`, zone files, ledgers |
| Turtles: position, facing, fuel, inventory, upgrades, label | the turtles' block entities in the region files | So the fleet starts where it really is |
| Placed loaders, GPS hosts, the server and warehouse computers | block entities | |
| Refined Storage contents | the live bridge's `/state` → `storage` at import time | The RS data files are internal to the mod; the list the bridge already publishes is the real contents |
| Cloud KV contents | an export of the CloudSolutions store; otherwise seeded from the live `/state` → `mineZones` | See below. `cloudstore.lua` warns that an empty store can read as total zone loss at boot, so the sandbox **never** starts with an empty store unless a scenario asks for exactly that |

**The cloud store, as far as it is known (2026-10-18).** It is the
CloudSolutions mod (`cloudsolutions-forge-1.20.1-0.3.4.jar`), running inside
the Minecraft server and storing **locally on the server PC**, despite the name.
It bundles `sqlite-jdbc`, so it is probably a SQLite file; its location is
unconfirmed. If it is SQLite, the safe live export is `sqlite3 <db> ".backup
<file>"`, which is consistent while the server runs. The importer's cloud-store
step is built once the export and its schema are in hand; until then the
`/state` seed stands in.

Which Minecraft data formats to parse, and with which library, is the builder's
call — `nbtlib` or a small hand-written Anvil reader. Paths above are standard
CC:Tweaked and Minecraft 1.20.1 layout **to be verified on the real copy**; the
first task of the plan is to inspect it.

**World model in the simulator.** Blocks in a sparse per-chunk table. Digging
removes a block and puts its drop in the turtle; placing puts one back. Ores are
what the world says they are. The geo scanner returns what is really within its
radius.

**Chunk loading.** A chunk is loaded when it is inside the base's always-loaded
area, inside a placed loader's ticket, or holds a turtle with the chunky upgrade
equipped. Computers in unloaded chunks are frozen. Which chunks the base keeps
loaded comes from the world copy if it can be read, otherwise from a config the
user confirms once.

**Ender chests.** Modelled by frequency: the fuel chest is an endless coal
source; the ore chest is a sink whose contents arrive in Refined Storage after a
configurable delay.

## 7. Faults — "pull a string"

A **scenario** is a Lua file describing a run: the world to start from, the jobs
to dispatch, and a timeline of faults. Each fault below is one call. Every one
names the real incident it reproduces, and the sandbox's own tests prove each
one actually changes behaviour.

| Fault | Reproduces |
|---|---|
| `server_crash(t, down_for)` — the dispatch computer stops, then reboots from disk | Server crash loops; restart recovery |
| `world_restart(t, {gps_delay=})` — every computer reboots; GPS hosts can come back late | 10-05: four miners lost to a missing fix |
| `server_lag(t, dur, factor)` — the server's work costs `factor` × more time | Server deafness |
| `tps_drop(t, dur, tps)` — every turtle action slows | Lag under load |
| `radio_loss(t, dur, rate, {channel=})` — messages dropped at a rate, optionally per channel | Disconnect clusters |
| `radio_latency(t, dur, ms)` | Late acks |
| `gps_down(t, dur, {hosts=})` | 09-17 GPS outage |
| `rs_stall(t, dur, seconds)` — `listItems` takes this long | The 29-second deafness |
| `rs_offline(t, dur)` | Storage outages |
| `turtle_reboot(t, node, {at_action=})` — reboot mid-action, including mid-refuel and mid-dump | The ledger and chest-recovery cards |
| `chunk_unload(t, area)` | Frozen miners |
| `disk_full(t, node, bytes_free)` | 09-09: the server disk filled |
| `bridge_down(t, dur)` / `bridge_slow(t, dur, ms)` | Push timeouts |
| `remove_item(t, node, slot)` | node_118 losing its ore chest |
| `event_queue_flood(t, node, n)` | Mailbox overflow |

**Randomness.** Every random choice — fault timing jitter, message loss, the
fleet's own `math.random` — comes from one seeded generator. The seed is printed
in every report. Same seed, same run.

## 8. Calibration — how close is close enough

The sandbox earns trust by matching the real server on things that have already
happened, and says how close it gets.

1. **Timings table.** How long a move, dig, place, scan, refuel and peripheral
   call take, in game ticks — measured from real fleet logs where possible,
   CC:Tweaked's documented values otherwise. Each entry says which.
2. **Forward calibration (spec owner's call).** A past job cannot be replayed
   from today's world copy: its zone is already dug out. Instead, pick an
   **unmined** zone in the copy, run a job on it in the sandbox, then run the
   same job on the real server, and compare: duration, ore mined, sectors,
   messages sent, ack loss. The report states the differences. A large gap is a
   finding about the sandbox, not about the fleet. (If the server keeps older
   world backups, a true replay becomes possible later; it is not required.)
3. **Faults can fail: the bar.** Every §7 fault has a test that fails when the
   fault is disabled or its effect is broken (mutation-style, like the existing
   `tests/mutate_*.py`). **In addition, two real incidents must reproduce on the
   code that had them and not on the fix:**
   - the **doubled first order**: 1.9.108 doubles it, 1.9.109 does not;
   - the **late-GPS world restart**: code before 1.9.132 loses miners, 1.9.132
     does not.
   Both have clear signatures and live in git history. Further incidents are
   welcome but not required.

## 9. Speed

- **Bar: a six-hour two-miner job in ≤ 72 seconds of wall-clock time** on this
  PC (Ryzen 7 5800X3D, 32 GB). That is 300×. A week in 30 minutes is about 336×.
- **Every report states the achieved ratio.** If a run is below 300×, the report
  says so and names the slowest computer and step.
- **A speed knob for watching:** `--speed max` for tests; `--speed 20` (or any
  number) to slow it down for the live view.
- **Parallel runs:** independent scenarios may run as separate processes at once
  (16 hardware threads). Each gets its own run folder, bridge port and logs.

## 10. Safety — what is off limits

The spec owner's rules, which the builder must enforce in code, not just
document:

1. **Network is closed by default.** The simulator intercepts every
   `http.request` and `http.get`:
   - `http://127.0.0.1:3000/*` (the fleet's bridge URL) goes to **that run's
     local bridge** on its own port;
   - `raw.githubusercontent.com/...` (the updater) is served **from the local
     worktree under test**, so a "deploy" in the sandbox installs the engineer's
     branch;
   - **everything else is refused** and logged.
2. **The local bridge runs with no RCON password** and refuses to start if one
   is set in its environment. It cannot reach the Minecraft server.
3. **The simulator refuses to start** if any configured URL or address points at
   the live server PC (`192.168.86.35`, or its Tailscale address
   `100.103.179.74`), the public server address, or any non-local host. It
   never opens a connection to the server PC for any reason, SSH included.
4. **The world copy and sandbox runs are git-ignored.** No world data, computer
   disks or run logs in the public repo.
5. **The sandbox never writes to the real cloud store**, the real repo's remote,
   or anything outside `sandbox/`.
6. **The sandbox is not part of the fleet.** Nothing under `sandbox/` appears in
   `install.lua` or `updater.lua`; a test enforces it.
7. **The analysis tools take a bridge address.** `tools/gate_check.py` and
   `tools/ack_loss.py` hard-code the live bridge (`http://192.168.86.35:3000`).
   They gain one option: an environment variable `BRIDGE_URL`, defaulting to
   the live address so nothing changes for engineers. The sandbox runner always
   sets it to its own file server, and **refuses to run either tool if the
   resolved address is not local**. Both files are W3's; the change is limited
   to reading that variable, and W3 is told in mail. Spec owner's ruling.

## 11. What a run produces

`sandbox/run/<run-id>/report.md` and `report.json`, with:

- scenario, seed, code version (git commit of the worktree), world copy date;
- **speed achieved**;
- every fault injected, and when;
- jobs dispatched, their outcomes, ore mined;
- the output of `gate_check.py` and `ack_loss.py` run against the local bridge;
- **NOT MODELLED** — the list of real-server behaviours this run could not
  exercise (mod-level chunk tickets, Forge registry sync, real TPS curves, RS
  internals beyond `listItems` timing, anything else the builder identifies).
  Always present. Never empty.

## 12. How engineers use it

- `sandbox/sim run <scenario> [--seed N] [--speed max|N] [--code <worktree>]`
- Scenarios live in `sandbox/scenarios/`. The first set, written as part of the
  build, covers: a normal two-miner job; server crash mid-job; world restart
  with GPS late; RS stall during a job; a turtle reboot mid-refuel; radio loss
  at 5% and 20%.
- A card closes on sandbox evidence by attaching the report. It moves to
  **"Done — not yet seen on the real server"**, a new board column. It moves to
  plain **Done** only when the real server has shown the behaviour, or when the
  user says so.
- If something breaks on the real server, engineers check cards in that column
  first.

## 13. Constraints

- **The simulator runs on Lua 5.2 (spec owner's call).** CC runs a Lua
  5.2-flavoured VM with no integer subtype: in CC `3/1` prints as `3`; in Lua
  5.4 it prints as `3.0`. Those numbers go into files, radio messages and
  coordinate keys, so 5.4 would make the sandbox disagree with the world in ways
  no fleet change could fix. **First task of the build:** install a Lua 5.2
  interpreter and run `luac -p` over every fleet file. If any fleet file uses
  syntax 5.2 cannot parse, stop and report it to the spec owner before
  continuing. (The existing test suite stays on 5.4; it is separate.)
- **Python 3.14** for the world importer; **Node 24** runs the local bridge.
- No changes to fleet files to make the sandbox work. If the fleet code truly
  cannot run in the sandbox without a change, that is a mail to the file's
  owner, not an edit.
- **`tests/stub_cc.lua` is copied, not changed (spec owner's call).** The
  sandbox vendors a copy under `sandbox/` and adapts it to many computers. The
  copy's header records the commit it came from, so the two can be compared
  when either changes. `tests/` belongs to the existing suite and its engineers.
- **The whole fleet runs by default (spec owner's call).** Every computer in the
  world copy boots, idle turtles included: idle turtles on the radio are exactly
  the regime the disconnect work found worst. A `--only <nodes>` option may boot
  a subset for quick iteration; reports say which was used. The §9 speed bar is
  measured on the whole fleet.
- **A synthetic world comes first.** The simulator core is built and tested on a
  small generated world (a base, a depot, a few hundred blocks of mixed ore), so
  the build is not blocked waiting for the real copy. The importer and the
  real-world runs follow when the copy arrives.
- **Ownership.** `sandbox/` is a new workstream held by the building instance.
  Its row goes in the roster.

## 14. Left to the builder

- Internal module layout of the simulator.
- Chunk storage format on disk.
- Whether `parallel`/`os.pullEvent` are vendored or reimplemented (§5's rule
  applies either way).
- The scenario file's exact syntax, within §7's call shapes.
- How the live view is throttled at `--speed max` (the bridge must not be
  flooded; a deliberate, stated deviation is acceptable).

## 15. Done means

1. A two-miner job from the real world copy runs end to end in the sandbox,
   using the real fleet files, and reaches ≥300×.
2. Every §7 fault exists, is tested, and its test can fail.
3. The forward calibration (§8.2) has been run on one unmined zone, in the
   sandbox and on the real server, and the differences are in a report. The two
   named incidents (§8.3) reproduce on the old code and not on the fix.
4. `gate_check.py` and `ack_loss.py` run against a sandbox run, changed only
   by the bridge-address option (§10.7).
5. The §10 safety rules are each enforced by a test.
6. The new board column exists.
7. A short `sandbox/README.md` tells an engineer how to run a scenario in under
   five minutes.
