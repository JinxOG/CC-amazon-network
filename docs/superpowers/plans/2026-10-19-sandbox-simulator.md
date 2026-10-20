# Sandbox Simulator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local simulator that runs the real Turtle OS fleet files, unchanged, against a copy of the server world on a virtual clock at ≥300× real time, with faults and full control on demand, so cards close on minutes of testing instead of six-hour live jobs.

**Architecture:** One Lua process hosts every in-game computer as a coroutine with its own environment and disk folder. A discrete-event scheduler drives a virtual clock that jumps over idle time. CC's APIs, the turtle API, the radio, peripherals, chunk loading and the dashboard bridge are reimplemented in Lua against a sparse world model. A tiny read-only Node server exposes run output to the existing analysis tools and the dashboard page.

**Tech Stack:** a CC-compatible Lua interpreter chosen in Task 1 (Lua 5.2.4 with a fixed hash seed, or LuaJIT 2.1); Python 3.14 + `nbtlib` for the world importer; Node 24 for the file server; Bash for the `sandbox/sim` launcher.

**Spec:** `docs/superpowers/specs/2026-10-18-sandbox-simulator-design.md` — read it in full before Task 1. This plan argues from it; where they seem to disagree, the spec wins and you mail the spec owner.

## Global Constraints

- **No fleet file is edited** to make the sandbox work (spec §2 anti-goals, §13). Fleet files: every `.lua` at the repo root. If one cannot run unchanged, stop and mail the spec owner (`python tools/mail.py new --to SPEC-OWNER --from SANDBOX --kind request ...`).
- **No CC:Tweaked ROM code is copied** — it is CCPL and barred from non-mod projects (spec §5). Reimplement from https://tweaked.cc documentation.
- **CC:Tweaked version to match: 1.120.2** (Minecraft 1.20.1, Forge).
- **Network closed by default** (spec §10): only `127.0.0.1:3000/*` (to the run's stand-in) and `raw.githubusercontent.com/...` (served from the code under test) are answered; everything else is refused and logged. Forbidden hosts, refused at startup if present in any config or argument: `192.168.86.35`, `100.103.179.74`, and any non-loopback address.
- **Nothing under `sandbox/` ships to the fleet**; all sandbox data lives under `$SANDBOX_DATA`, outside the repo; `sandbox/worlds/` and `sandbox/run/` are git-ignored anyway as a safety net.
- **All sandbox data lives on the Game Drive** (user's instruction, 2026-10-19): `SANDBOX_DATA`, default **`G:\TurtleOS-Sandbox`** (in Bash: `/g/TurtleOS-Sandbox`). World copies in `$SANDBOX_DATA/worlds/`, runs and snapshots in `$SANDBOX_DATA/run/`, the interpreter in `$SANDBOX_DATA/interpreter/`, saved storage lists in `$SANDBOX_DATA/storage/`. **Never in the repo**: it sits in OneDrive and would sync gigabytes to the cloud. The code stays in the repo under `sandbox/`. `sandbox/sim` reads `SANDBOX_DATA` and falls back to the default.
- **The world copy is already here, unpacked** (2026-10-19): `$SANDBOX_DATA/worlds/unpacked/2026-10-18_1700/world_live/` — the FTB Backups 2 zip from 2026-10-18 17:00, pulled from the server's `/mnt/backup/ftb/` by the user. Verified: the size matches the server's, all 2,377 files unpacked, `level.dat` reads, 176 overworld region files, 159 folders under `computercraft/computer/`. The untouched zip is `$SANDBOX_DATA/worlds/incoming/latest-backup.zip` with its file list beside it. **Treat both as read-only master copies**: the importer reads them and writes elsewhere; if a copy gets damaged, unpack the zip again into a new folder. Task 22 starts from it.
- **No saved storage list exists yet** (`$SANDBOX_DATA/storage/` is empty). Task 22 needs one; see Task 22 Step 1.
- **Every computer's disk quota defaults to 1,000,000 bytes** (measured `computer_space_limit`).
- **Event queue cap: 256 per computer**; overflow drops the new event and logs it.
- **Speed bar: a six-hour two-miner job in ≤72 s wall clock**, whole fleet booted (spec §9, §13).
- **Every report contains NOT MODELLED, ASSUMPTIONS and INTERVENTIONS sections; NOT MODELLED is never empty** (spec §11, §7.1).
- **Same scenario + same seed ⇒ byte-identical `trace.log`** (spec §2 goal 5).
- **Ownership:** you own `sandbox/`. The only files outside it you change are `.gitignore`, `tools/gate_check.py` and `tools/ack_loss.py` (Task 15, by spec owner ruling, spec §10.7). Never `git add -A`; always explicit paths. Push with `git push origin HEAD:master`, then verify with `git merge-base --is-ancestor <sha> origin/master` (protocol §8).
- **Work in your own git worktree** under `.claude/worktrees/sandbox`, on a named branch — never in the primary checkout, never on `master` directly (protocol §8.1).

## Review Focus

1. **A fleet file calls a CC function the sandbox lacks.** Expect a loud error naming the function and the computer, never a silent `nil`. Pinned in Task 4 (`unimplemented API raises with its name`).
2. **A message table is mutated by the receiver after sending.** CC copies messages between computers; a shared reference would let one turtle change another's data. Pinned in Task 9 (`transmit deep-copies the message`).
3. **Two computers write the same disk path.** Each computer's disk is its own folder; `fs` must refuse `..` escapes. Pinned in Task 5 (`fs cannot escape the computer's disk`).
4. **A run is interrupted (Ctrl+C, crash) mid-way.** Expect a partial report marked `INCOMPLETE`, not a missing or misleading one. Pinned in Task 18 (`a crashed run still writes an INCOMPLETE report`).
5. **The fleet pushes faster than the live view can absorb at `--speed max`.** Expect the file server to serve the latest state without growing memory or lagging the simulator. Pinned in Task 14 (`state.json is overwritten, not appended`).

---

## Phase 0 — Foundations

### Task 1: Interpreter, layout and the safety tests that never go away

**Files:**
- Create: `sandbox/README.md` (stub; finished in Task 26), `sandbox/sim` (bash launcher), `sandbox/interp.txt`, `sandbox/tests/run.lua`, `sandbox/tests/helpers.lua`, `sandbox/tests/test_safety_static.lua`, `sandbox/tools/check_interp.lua`
- Modify: `.gitignore` (append two lines)

**Interfaces:**
- Produces: `sandbox/sim test [pattern]` runs every `sandbox/tests/test_*.lua` under the chosen interpreter. Each test file returns `{ ["name"] = function(t) ... end }`. `helpers.lua` gives `t.eq(actual, expected, msg)`, `t.ok(v, msg)`, `t.raises(fn, lua_pattern)`, `t.near(a, b, tol, msg)`. The runner prints `PASS name` / `FAIL name: msg` and exits non-zero on any failure.
- Produces: `sandbox/interp.txt` — one line, the absolute path of the chosen interpreter, installed under `$SANDBOX_DATA/interpreter/`. `sandbox/sim` reads it.

- [ ] **Step 1: Get the user's OK, then install an interpreter.** Nothing suitable is on this PC (only Lua 5.4, no C compiler). Ask the user in your session before downloading anything. Preferred: install Zig (`winget install zig.zig`) and build Lua 5.2.4 from the official lua.org tarball with `-D'luai_makeseed()=0'` (or the equivalent edit in `lstate.c`) so string hashing is fixed. Fallback: an official LuaJIT 2.1 build.
- [ ] **Step 2: Write `sandbox/tools/check_interp.lua`.** It must print three verdicts:
  - `PARSE ok|FAIL <file>` — `loadfile` every root `*.lua` (it must parse the one `goto` in `central_server.lua`);
  - `NUMBER ok|FAIL` — `tostring(3/1) == "3"` and `tostring(10/4) == "2.5"`;
  - `ORDER <hex digest>` — insert 1,000 string keys (`"k"..i`) into a table, concatenate `pairs` order, print a short checksum.
- [ ] **Step 3: Run it five times as separate processes.** All five must print `PARSE ok`, `NUMBER ok`, and the **same** `ORDER` digest. If no candidate passes, stop and mail the spec owner with the output — do not continue.
- [ ] **Step 4: Write `sandbox/tests/test_safety_static.lua`** with these tests:
  - `gitignore lists sandbox/worlds and sandbox/run` — reads `.gitignore`, asserts both lines `sandbox/worlds/` and `sandbox/run/` present (a safety net in case anyone points `SANDBOX_DATA` inside the repo).
  - `nothing under sandbox ships to the fleet` — reads `install.lua` and `updater.lua`, asserts neither contains the string `sandbox/`.
  - `no file under sandbox names a forbidden host` — scans every file under `sandbox/` except `sandbox/tests/` for `192.168.86.35` and `100.103.179.74`; asserts zero hits.
- [ ] **Step 5: Run `sandbox/sim test`** — expect the gitignore test to FAIL. Append `sandbox/worlds/` and `sandbox/run/` to `.gitignore`. Re-run: all PASS.
- [ ] **Step 6: Commit** `.gitignore sandbox/` (explicit paths) — `feat(sandbox): interpreter check, test runner, static safety tests`.

---

## Phase 1 — The core: clock, scheduler, computers, CC APIs

### Task 2: Seeded randomness, virtual clock and the event heap

**Files:** Create `sandbox/core/rng.lua`, `sandbox/core/clock.lua`, `sandbox/core/heap.lua`; Test `sandbox/tests/test_core_time.lua`

**Interfaces:**
- Produces: `Rng.new(seed:number) -> rng`; `rng:next() -> number in [0,1)`; `rng:int(lo, hi) -> integer`; `rng:fork(label:string) -> Rng` (deterministic sub-stream from parent seed + label). Algorithm: xorshift64* or splitmix64 implemented in pure Lua arithmetic that works without integer types (use two 32-bit halves); **never `math.random`**.
- Produces: `Clock.new(start_ms) -> clock`; `clock:now() -> integer ms`; `clock:set(ms)` (errors if `ms < now`).
- Produces: `Heap.new() -> heap`; `heap:push(t_ms, item)`; `heap:pop() -> t_ms, item`; `heap:peek_time() -> t_ms|nil`; ties broken by insertion order (a monotonically increasing sequence number) so ordering is deterministic.
- Default start time: **`1790000000000` ms** (a fixed instant), overridable per scenario.

- [ ] **Step 1: Write failing tests:** `same seed same sequence`, `different labels fork different sequences`, `int stays in range over 10000 draws`, `clock refuses to go backwards`, `heap pops in time order`, `heap breaks ties by insertion order`.
- [ ] **Step 2: Run** `sandbox/sim test core_time` — FAIL (modules missing).
- [ ] **Step 3: Implement** the three modules.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): seeded rng, virtual clock, deterministic event heap`.

### Task 3: Computers — environments, event queues, filters, boot and reboot

**Files:** Create `sandbox/core/computer.lua`, `sandbox/core/scheduler.lua`; Test `sandbox/tests/test_computer.lua`

**Interfaces:**
- Produces: `Computer.new{ id=number, label=string|nil, kind="computer"|"turtle"|"gps_host", disk=abs_path, sched=Scheduler, pos={x,y,z,facing}|nil } -> comp`. (`gps_host` computers run native behaviour from Task 10, not a `startup.lua`.)
  - `comp:boot()` — builds a fresh environment via `CCEnv.build(comp)` (Task 4) and runs `startup.lua` from its disk in a coroutine.
  - `comp:shutdown()`, `comp:reboot()` (= shutdown, then boot at the same virtual instant + `TIMINGS.reboot_ms`).
  - `comp:queue_event(ev_table) -> boolean` — false (and logged as `queue_overflow`) when the queue already holds `QUEUE_MAX = 256` events or the computer is off.
  - `comp.state` — `"off" | "running" | "waiting" | "busy"`; `comp.filter` — the string it is waiting for, or nil.
  - `comp.output` — array of printed lines, each `{t=ms, text=string}`.
  - `comp.cost_ms` — accumulated virtual time owed for computation (Task 4 adds the instruction hook).
- Produces: `Scheduler.new{ clock=, rng=, trace=path|nil } -> sched`; `sched:add(comp)`; `sched:post(t_ms, comp, ev_table)`; `sched:after(delay_ms, fn)`; `sched:run{ until_ms=, max_events=, stop=fn } -> reason_string`; `sched:trace(line)` appends to `trace.log`.
- **Delivery rule (CC's, spec §5):** a waiting computer is resumed with the head of its queue **only if** `filter == nil` or `filter == ev[1]` or `ev[1] == "terminate"`; otherwise **that event is discarded**. Every delivered or discarded event writes one trace line: `<t> <computer> <deliver|discard|overflow> <event-name>`.
- **Busy rule:** a resume runs until the coroutine yields; the computer is then unavailable until `now + cost_ms` (its accumulated cost, reset after charging). Events arriving meanwhile are queued, not discarded.

- [ ] **Step 1: Write failing tests** using tiny inline `startup.lua` programs written to a temp disk:
  - `a filtered wait discards non-matching events` — program waits for `"b"`; post `"a"` then `"b"`; assert the program saw only `"b"` and the trace shows `discard a`.
  - `an unfiltered wait receives everything in order`.
  - `terminate is delivered even through a filter`.
  - `the 257th queued event is dropped and logged as overflow`.
  - `events arriving while busy are queued, not lost`.
  - `reboot restarts from startup and keeps the disk` — program writes a file, reboots; second boot reads it.
  - `memory does not survive reboot` — a global set before reboot is nil after.
  - `output captures print with virtual timestamps`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `Computer` and `Scheduler`. The scheduler's loop pops the earliest heap item, sets the clock, and either runs a callback or delivers to a computer.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): computers with CC event-queue and filter semantics`.

### Task 4: The CC environment — `os`, time, timers, `sleep`, `print`, computation cost

**Files:** Create `sandbox/cc/env.lua`, `sandbox/cc/os.lua`, `sandbox/cc/term.lua`, `sandbox/timings.lua`; Test `sandbox/tests/test_cc_os.lua`

**Interfaces:**
- Consumes: `Computer`, `Scheduler`, `Clock`, `Rng` (Tasks 2–3).
- Produces: `CCEnv.build(comp) -> env` — a table used as the computer's `_ENV`/function environment, containing **only** whitelisted Lua standard functions plus the CC APIs. `math.random`/`math.randomseed` are replaced by a per-computer `Rng` stream (`randomseed(n)` reseeds it deterministically). Any access to a missing CC global or method raises `"sandbox: <api>.<name> is not implemented (computer <id>)"` — use a metatable on each API table.
- Produces in `env.os`: `epoch(kind)` for `"utc"|"local"|"ingame"` (ms); `clock()` (seconds since boot); `time()`, `day()` (in-game, 20-minute days); `date(fmt, t)`; `startTimer(s) -> id`; `cancelTimer(id)`; `pullEventRaw(filter)` (= `coroutine.yield(filter)`); `pullEvent(filter)` (raises `"Terminated"` on terminate); `queueEvent(...)`; `getComputerID()`; `getComputerLabel()`; `setComputerLabel(s)`; `reboot()`; `shutdown()`. Plus global `sleep(s)` (timer + filtered wait, exactly as CC does it, so it eats other events) and `print`/`write` into `comp.output`.
- Produces: `TIMINGS` table in `sandbox/timings.lua`. **Initial values, each marked `unverified` until Task 25 calibrates them:**

| Key | Initial | Source |
|---|---|---|
| `tick_ms` | 50 | Minecraft 20 TPS |
| `move_ms`, `turn_ms`, `up_ms`, `down_ms` | 400 | CC:T turtle animation, unverified |
| `dig_ms`, `place_ms`, `attack_ms` | 400 | unverified |
| `turtle_cmd_ms` (select-free commands: detect, inspect, suck, drop, transferTo, refuel, equip) | 50 | one tick, unverified |
| `scan_ms` (geo scanner) | 1000 | unverified |
| `rs_list_ms` (rsBridge.listItems) | 267 | measured idle `rsPollMs`, 2026-09 |
| `kv_call_ms` | 50 | unverified |
| `http_reply_ms` | 3 | measured bridge 1–3 ms |
| `radio_latency_ms` | 0 | delivered next scheduler step |
| `reboot_ms` | 1000 | unverified |
| `ns_per_instr` | 50 | unverified; calibrated from `pushBuildMs` in Task 25 |
| `instr_hook_every` | 1000 | instructions between cost charges |

- **Computation cost:** every coroutine created inside a computer (wrap `coroutine.create`/`coroutine.wrap` in the env) gets `debug.sethook(co, hook, "", TIMINGS.instr_hook_every)`; the hook adds `instr_hook_every * ns_per_instr / 1e6` ms to `comp.cost_ms`.

- [ ] **Step 1: Write failing tests:** `epoch reads the virtual clock`, `startTimer fires a timer event with its id at the right virtual time`, `cancelTimer prevents the event`, `sleep discards a modem_message that arrives during it` (the yields-eat-events row), `pullEvent raises Terminated on terminate`, `randomseed makes math.random deterministic per computer`, `unimplemented API raises with its name`, `a busy loop of N instructions costs N*ns_per_instr`, `os.clock counts from this computer's boot`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): CC os, timers, sleep and computation cost on the virtual clock`.

### Task 5: `fs`, `textutils`, `shell`, `settings` — disks and serialisation

**Files:** Create `sandbox/cc/fs.lua`, `sandbox/cc/textutils.lua`, `sandbox/cc/shell.lua`, `sandbox/cc/settings.lua`; Test `sandbox/tests/test_cc_fs_textutils.lua`

**Interfaces:**
- Produces `env.fs`: `open(path, mode)` returning CC-style handles (`readAll`, `readLine`, `read`, `write`, `writeLine`, `flush`, `close`; binary modes `rb`/`wb`), `exists`, `isDir`, `list`, `delete`, `move`, `copy`, `makeDir`, `getSize`, `getFreeSpace`, `combine`, `getName`, `getDir`. Paths are rooted at the computer's disk; `..` past the root is clamped to the root as CC does; quota per computer (default 1,000,000 bytes) makes writes fail like CC's "Out of space" when exceeded.
- Produces `env.textutils`: `serialise`/`serialize(t, opts)`, `unserialise`/`unserialize(s)`, `serialiseJSON`/`serializeJSON(t, opts)`, `unserialiseJSON`/`unserializeJSON(s, opts)`. Output must match CC:Tweaked 1.120.2 byte for byte for the shapes the fleet writes (nested tables, string keys, number arrays, `compact` option). Golden fidelity tests on real CC files come in Task 22.
- Produces `env.shell.run(path, ...)` (runs a program from the disk in the same computer, used by `startup.lua` and the updater), `env.shell.getRunningProgram()`; `env.settings` minimal get/set/save/load.

- [ ] **Step 1: Write failing tests:** `fs cannot escape the computer's disk`, `writes past the quota fail and leave the old file intact`, `getFreeSpace reflects quota minus usage`, `serialise round-trips nested tables`, `serialise output matches the CC examples on tweaked.cc` (copy the documented example outputs as expected strings), `serialiseJSON writes integers without .0`, `unserialiseJSON handles nested arrays and null`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): CC fs with quotas, textutils with CC formats`.

### Task 6: `parallel`, `peripheral` and the §5 fidelity table

**Files:** Create `sandbox/cc/parallel.lua`, `sandbox/cc/peripheral.lua`; Test `sandbox/tests/test_cc_fidelity.lua`

**Interfaces:**
- Produces `env.parallel.waitForAny(...)`, `waitForAll(...)` — each function becomes a coroutine; **every event is offered to every coroutine**, each applying its own filter; `terminate` reaches all.
- Produces `env.peripheral`: `find(type, filterFn)`, `wrap(sideOrName)`, `getType(name)`, `getNames()`, `getName(p)`, `call(name, method, ...)`, `isPresent(name)`. Peripherals are registered per computer by later tasks via `comp:attach(side_or_name, type, methods_table)`.
- Produces a helper for later tasks: `CCEnv.main_thread_call(comp, duration_ms, fn) -> results` — performs a **yielding** peripheral call: posts `task_complete` with a fresh id after `duration_ms`, waits for it with a filter (so other events arriving meanwhile are discarded, as in CC), then returns `fn()`'s results.

- [ ] **Step 1: Write one failing test per row of spec §5's table** that Tasks 3–6 cover: `queue cap 256`, `filtered wait discards`, `waitForAny gives every coroutine every event` (two coroutines filtering different events both receive theirs), `doubled delivery when two coroutines both accept the same event` (both see one `modem_message` — the 1.9.108 mechanism), `a yielding peripheral call makes the computer deaf to other events`, `os.reboot keeps disk loses memory`, `timer events carry their id`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): parallel and peripheral with CC event fan-out`.

---

## Phase 2 — World, turtles, radio, peripherals

### Task 7: The world model and a synthetic world

**Files:** Create `sandbox/world/world.lua`, `sandbox/tools/synth_world.lua`; Test `sandbox/tests/test_world.lua`

**Interfaces:**
- Produces: `World.open(dir) -> world` (lazy-loads chunks from `dir/chunks/`); `World.new_empty() -> world`; `world:get(x,y,z) -> block_name|nil` (nil = air); `world:set(x,y,z,name|nil)`; `world:chunk_of(x,z) -> cx, cz` (floor division by 16); `world:save(dir)`; `world:meta()` — the world's metadata table (`base_loaded = {{x1,z1,x2,z2},...}`, `dock`, `spawn`, etc.). On-disk chunk format is your call (spec §14).
- Produces: `lua sandbox/tools/synth_world.lua <out_dir> [--seed N]` — a small deterministic world: bedrock at y=-64, stone to y=60, grass above; a 48×48 base footprint around (0,64,0) marked `base_loaded`; a depot; three 64×64 mining areas east of the base with ore veins (`minecraft:iron_ore`, `minecraft:coal_ore`, `minecraft:diamond_ore`, `create:zinc_ore`) placed by the seeded rng; GPS host positions at y=255 at four corners.

- [ ] **Step 1: Failing tests:** `unset blocks are air`, `set then get`, `chunk_of floors negatives` (`chunk_of(-1, -17) == -1, -2`), `save then open round-trips`, `synth world is identical for the same seed`, `synth world has ore in each mining area`.
- [ ] **Step 2–4:** run FAIL, implement, run PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): sparse world model and deterministic synthetic world`.

### Task 8: The turtle API

**Files:** Create `sandbox/cc/turtle.lua`, `sandbox/vendor/stub_cc_copy.lua` (copy of `tests/stub_cc.lua` with a header line `-- copied from tests/stub_cc.lua at commit <sha>; adapted for many computers`); Test `sandbox/tests/test_turtle.lua`

**Interfaces:**
- Consumes: `World`, `CCEnv.main_thread_call`-style yielding, `TIMINGS`.
- Produces `env.turtle` for computers of kind `turtle`: every function the fleet calls (spec §5 API list; at minimum: `forward back up down turnLeft turnRight dig digUp digDown place placeUp placeDown detect detectUp detectDown inspect inspectUp inspectDown select getSelectedSlot getItemCount getItemSpace getItemDetail transferTo drop dropUp dropDown suck suckUp suckDown refuel getFuelLevel getFuelLimit equipLeft equipRight getEquippedLeft getEquippedRight attack compareTo`).
- **Actions that take time yield** for a `turtle_response` with a fresh id, posted after the action's `TIMINGS` duration, so events during a move are discarded exactly as in CC. Inventory reads (`select`, `getItemCount`, `getItemDetail`) are immediate.
- **Reuse the copied stub's inventory, equip, fuel and container semantics** — its comments record each CC fidelity fix; keep them.
- A turtle refuses to move into a non-air block, out of fuel, or into another turtle's position (returns `false, "Movement obstructed"` — the CC message).
- Digging removes the block and puts its drop in the inventory (block name = drop, except a small table: `minecraft:stone → minecraft:cobblestone`, `minecraft:grass_block → minecraft:dirt`, ores drop themselves — the fleet's ore handling only needs names).

- [ ] **Step 1: Failing tests:** `forward costs move_ms and changes position`, `a modem message during forward is discarded`, `cannot move into stone`, `cannot move into another turtle`, `no fuel means no move`, `dig puts the block in the inventory`, `getItemDetail matches the stub's shape`, `equip swaps the slot item with the equipped upgrade`.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): turtle API on the world with CC timing and refusals`.

### Task 9: Radio and modems

**Files:** Create `sandbox/net/radio.lua`, `sandbox/periph/modem.lua`; Test `sandbox/tests/test_radio.lua`

**Interfaces:**
- Produces: `Radio.new{ sched=, rng= } -> radio`; `radio:transmit(from_comp, side, channel, reply, msg)`; `radio:add_rule{ channel=, from=, to=, type=, drop_rate=0..1, latency_ms=, from_ms=, until_ms= } -> rule_id`; `radio:remove_rule(id)`.
- Produces modem peripheral type `"modem"` (methods `open close isOpen closeAll transmit isWireless`), attached to computers whose equipment includes `computercraft:wireless_modem_advanced` (turtles) or that have one placed (stationary computers — from world data or scenario).
- Delivery: to every **on, loaded** computer with `channel` open, including other modems on the sender (not the sending modem itself), event `{"modem_message", side, channel, reply, copy, distance}`. `copy` is a **deep copy**; functions in the message raise as CC does. Ender (advanced) modems: unlimited range; `distance` = Euclidean distance between positions.
- Every transmit writes a trace line `<t> radio <from> -> <to> ch=<n> type=<msg.type or ?> <delivered|dropped>`.

- [ ] **Step 1: Failing tests:** `only computers with the channel open receive`, `transmit deep-copies the message`, `a function in a message raises`, `drop_rate 1 drops everything on that channel`, `latency delays delivery by latency_ms`, `rules expire at until_ms`, `the sender's own modem does not hear itself`.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): radio network with copies, loss and latency rules`.

### Task 10: GPS

**Files:** Create `sandbox/cc/gps.lua`, `sandbox/periph/gps_host.lua`; Test `sandbox/tests/test_gps.lua`

**Interfaces:**
- Produces `env.gps.locate(timeout, debug)` behaving as CC documents: transmit on channel `65534` (`gps.CHANNEL_GPS`), collect replies until `timeout` (default 2 s), trilaterate from ≥3 non-coplanar fixes plus a 4th to disambiguate; return `x, y, z` or `nil`. It runs through the radio, so radio rules and GPS faults apply.
- Produces a GPS host: a computer kind `"gps_host"` at a fixed position whose behaviour answers locate requests (implemented natively, not by running CC's `gps host` program). `gps_host:set_on(bool)`.

- [ ] **Step 1: Failing tests:** `locate returns the turtle's true position with four hosts up`, `locate returns nil with fewer than three hosts`, `locate fails while all hosts are off`, `radio loss on 65534 makes locate fail`.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): GPS hosts and gps.locate over the simulated radio`.

### Task 11: Chunk loading

**Files:** Create `sandbox/world/chunks_loaded.lua`; Test `sandbox/tests/test_chunk_loading.lua`

**Interfaces:**
- Produces: `Loading.new{ world=, sched= } -> loading`; `loading:is_loaded(cx, cz) -> bool`; `loading:add_ticket(owner_id, cx, cz, radius)`; `loading:remove_tickets(owner_id)`; `loading:recompute()`.
- Rules (spec §6): loaded if inside `world:meta().base_loaded`, inside a placed loader turtle's ticket (Advanced Peripherals Chunky Turtle, **radius 1 → 3×3 chunks**, unverified — Task 25), or the chunk holds a turtle with the chunky upgrade equipped. **Copied turtles share one chunk identity** (memory: copied loaders keep their chunky UUID; only the last-placed holds) — model tickets keyed by that identity, not by computer id.
- On a chunk becoming unloaded, every computer in it is **shut down**; on reload, every computer that was on **boots** from `startup.lua` (spec §5).

- [ ] **Step 1: Failing tests:** `base area is always loaded`, `a chunky turtle loads its own chunk`, `a placed loader loads 3x3 around it`, `leaving loaded ground shuts a computer down`, `reloading boots it from startup`, `two copies of one loader hold only one ticket`.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): chunk loading with shutdown and reboot on unload`.

### Task 12: Peripherals — geo scanner, Refined Storage bridge, cloud store, ender chests

**Files:** Create `sandbox/periph/storage.lua`, `sandbox/periph/geo_scanner.lua`, `sandbox/periph/rs_bridge.lua`, `sandbox/periph/kv_storage.lua`, `sandbox/periph/ender.lua`; Test `sandbox/tests/test_peripherals.lua`

**Interfaces:**
- `geo_scanner`: `scan(radius) -> list` of `{name=, tags=, x=, y=, z=}` **relative** to the scanner, from the world; yielding, `scan_ms`. Fields the fleet reads: `name tags x y z`.
- `Storage` (`sandbox/periph/storage.lua`): `Storage.new(items) -> storage` where `items` is a list of `{name=, amount=, displayName=}`; `storage:list()`; `storage:add(name, n)`; `storage:remove(name, n) -> removed`. One instance per run, seeded by the scenario (synthetic) or from the importer's `storage.json` (Task 22).
- `rsBridge` (type `"rsBridge"`): `listItems() -> list` of `{name=, amount=, count=, displayName=}` (the fleet reads all four), `listCraftableItems()`, `craftItem(spec)`, `getItem(spec)`; yielding, `rs_list_ms`; contents from the run's `Storage`.
- `kv_storage` (type `"kv_storage"`): `get(key)`, `put(key, value)`, `delete(key)`, `list(prefix)` — read `cloudstore.lua` for the exact argument and return shapes it expects and match them; yielding, `kv_call_ms`; backed by `KV.new(path) -> kv` (in `kv_storage.lua`), which persists to `$SANDBOX_DATA/run/<id>/kv.json`, survives every reboot within a run, and starts empty unless a scenario loads a saved file (spec §6).
- Ender chests: inventories keyed by frequency (`{colors}` triple). Frequency config per scenario: the fuel chest is an endless coal source; the ore chest drains into `Storage` after `ore_chest_delay_ms` (default 5000).

- [ ] **Step 1: Failing tests:** `scan returns relative positions within radius`, `scan yields for scan_ms`, `listItems returns the storage contents with all four fields`, `kv survives a server reboot`, `kv list returns only matching keys`, `fuel ender chest never runs out`, `ore dropped in the ore chest arrives in storage after the delay`.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): geo scanner, RS bridge, cloud store and ender chests`.

---

## Phase 3 — HTTP, the stand-in bridge, the file server

### Task 13: HTTP interception and the network safety rules

**Files:** Create `sandbox/cc/http.lua`, `sandbox/core/safety.lua`; Test `sandbox/tests/test_http_safety.lua`

**Interfaces:**
- Produces `env.http.request(url, body, headers, binary)` (async: posts `http_success` / `http_failure` after `http_reply_ms`) and `env.http.get(url, headers, binary)` (sync form, as CC provides) with responses exposing `readAll`, `readLine`, `getResponseCode`, `getResponseHeaders`, `close`.
- Routing: `http://127.0.0.1:3000/<path>` → `Standin:handle(method, path, body)` (Task 14). `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<file>` → the file from the **code directory under test** (ignore `<ref>`; report it in the trace). Anything else → `http_failure` with `"sandbox: network closed"` and a `blocked` trace line.
- Produces `Safety.check_config(tbl_or_string)` — raises on any of `192.168.86.35`, `100.103.179.74`, or any URL/host that is not `127.0.0.1`, `localhost`, `::1` or `raw.githubusercontent.com`. Called at startup on the scenario, CLI args and environment.

- [ ] **Step 1: Failing tests:** `bridge URL reaches the stand-in`, `github raw is served from the code dir`, `any other host is refused and logged`, `startup refuses a scenario naming 192.168.86.35`, `startup refuses the Tailscale address`, `request is async and fires http_success`.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): closed network with stand-in and code-dir routing`.

### Task 14: The stand-in bridge (Lua, simulated time)

**Files:** Create `sandbox/bridge/standin.lua`; Test `sandbox/tests/test_standin_contract.lua`, fixtures `sandbox/tests/fixtures/bridge/*.json`

**Interfaces:**
- Consumes: `server.js` as the contract source (read it; do not run it).
- Produces: `Standin.new{ run_dir=, sched= } -> standin`; `standin:handle(method, path, body) -> status, headers, body_string`; `standin:dispatch(cmd_table)` (the same effect as `POST /command`, used by scenarios — at least `ORDER_MINE`, `CANCEL_JOB`, `RECALL_ALL`).
- Behaviour, all on **simulated** time: `POST /update` stores the server's state and appends its log lines; `POST /storage` stores the warehouse snapshot (newest `storageTs` wins); `GET /state` returns the merged state with `serverTime` = simulated now; log lines go to `run_dir/logs/<YYYY-MM-DD of simulated time>.txt` in the exact line format `server.js` writes; `run_dir/state.json` is **overwritten** on each update.
- **Contract tests:** for each route the fleet or the tools use, a fixture of a real request/response captured from `server.js`'s code (field names and types). Tests compare the stand-in's response shape (keys, types, nesting) to the fixture.

- [ ] **Step 1: Failing tests:** `update then state returns serverTime as simulated now`, `log lines land in the simulated day's file`, `log line format matches server.js`, `storage keeps the newest storageTs`, `state.json is overwritten, not appended`, one `contract: <route>` test per fixture.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): stand-in bridge pinned to the server.js contract`.

### Task 15: The file server and the tools' bridge option

**Files:** Create `sandbox/bridge/fileserver.js`; Modify `tools/gate_check.py`, `tools/ack_loss.py` (one variable each); Test `sandbox/tests/test_fileserver.sh`

**Interfaces:**
- Produces: `node sandbox/bridge/fileserver.js <run_dir> <port>` — binds **127.0.0.1 only**; serves `GET /state` (from `state.json`), `GET /logs`, `GET /logs/<date>` with the same query parameters `server.js` supports and the tools use (`since`, `contains`, `limit`, `order`; check the tools for any others), `GET /` and assets from the repo's `public/`. No other routes, no writes, no timers.
- Tools: replace the hard-coded `B = "http://192.168.86.35:3000"` with `B = os.environ.get("BRIDGE_URL", "http://192.168.86.35:3000")`. Nothing else changes. Mail W3 that you made this change, citing spec §10.7: `python tools/mail.py new --to W3 --from SANDBOX --kind info --subject "BRIDGE_URL option added to gate_check and ack_loss (spec owner ruling)"`.
- `sandbox/sim` refuses to invoke either tool unless `BRIDGE_URL` resolves to `127.0.0.1`.

- [ ] **Step 1: Failing test script:** start the file server on a fixture run dir; `curl 127.0.0.1:<port>/state` returns the fixture; `curl /logs/<date>?contains=X` filters; a request from a non-loopback bind is impossible (assert the listening address with `netstat`); `BRIDGE_URL=http://127.0.0.1:<port> python tools/gate_check.py <since>` completes against the fixture.
- [ ] **Step 2–4:** FAIL, implement, PASS. Also run the existing tool once **without** `BRIDGE_URL` set and confirm the default address is unchanged (read the variable, do not query the live bridge).
- [ ] **Step 5: Commit** `sandbox/bridge/fileserver.js sandbox/tests/test_fileserver.sh tools/gate_check.py tools/ack_loss.py` — `feat(sandbox): read-only file server; tools take BRIDGE_URL`.

---

## Phase 4 — Running the real fleet

### Task 16: Provisioning and the first end-to-end job on the synthetic world

**Files:** Create `sandbox/core/fleet.lua`, `sandbox/core/code_dir.lua`, `sandbox/scenarios/smoke_two_miners.lua`; Test `sandbox/tests/test_end_to_end.lua`

**Interfaces:**
- Produces: `CodeDir.prepare(spec) -> abs_path` — `spec` is `"worktree:<path>"` (use files as they are) or `"rev:<git-rev>"` (materialise with `git archive <rev> | tar -x` into `$SANDBOX_DATA/run/<id>/code/`; never touches `HEAD`).
- Produces: `Fleet.provision(world, code_dir, layout) -> {computers}` — `layout` lists `{id=, kind=, role=, pos=}`; each computer's disk is created by **running the real `install.lua <role>`** inside that computer with `http.get` served from `code_dir` (roles from `install.lua`: `server`, `miner`, `delivery`, `support`, `loader`, plus `warehouse` and `admin` — read its `PROFILES`).
- The synthetic layout: dispatch server, warehouse, 2 miners with loaders, 2 delivery, 2 support, 4 GPS hosts, plus idle turtles to reach 15 workers (spec §13: whole fleet by default).
- `smoke_two_miners.lua` dispatches `ORDER_MINE` on one synthetic mining area through `standin:dispatch` and runs until both jobs are COMPLETE or 8 simulated hours pass.

- [ ] **Step 1: Failing test** `a two-miner job completes on the synthetic world using the real fleet files` — asserts both jobs reach `COMPLETE`, ore appears in `Storage`, and `trace.log` contains no `sandbox: ... not implemented`.
- [ ] **Step 2: Run** — expect failures from missing APIs; fix each in the module that owns it (never in fleet files). If a fleet file genuinely cannot run, stop and mail the spec owner.
- [ ] **Step 3: Run** — PASS.
- [ ] **Step 4: Commit** — `feat(sandbox): provision with the real installer; first end-to-end job`.

### Task 17: Scenarios, runs and determinism

**Files:** Create `sandbox/scenario/runner.lua`, `sandbox/sim.lua` (CLI entry); Modify `sandbox/sim`; Test `sandbox/tests/test_determinism.lua`

**Interfaces:**
- Produces the CLI: `sandbox/sim run <scenario.lua> [--seed N] [--speed max|N] [--code worktree:<p>|rev:<r>] [--only <nodes>] [--world <dir>] [--port N]`. Each run gets `$SANDBOX_DATA/run/<YYYYMMDD-HHMMSS>-<scenario>-<seed>/` containing `trace.log`, `state.json`, `logs/`, `kv.json`, `report.md`, `report.json`.
- Scenario file shape (syntax your call, spec §14): returns a table with `world`, `layout` (optional), `seed` (optional), `start_ms` (optional), `steps = function(sim) ... end` where `sim` exposes the fault API (Task 19) and the control API (Task 20), plus `sim:dispatch(cmd)`, `sim:run_for(ms)`, `sim:run_until(cond, timeout_ms)`, `sim:expect(cond, message)`.
- `--speed N` paces the scheduler so simulated time advances at most N× wall time; `max` does not pace.

- [ ] **Step 1: Failing test** `same scenario and seed produce byte-identical trace.log` (run `smoke_two_miners` twice with seed 42, compare files) and `different seeds produce different traces`.
- [ ] **Step 2–4:** FAIL, implement, PASS. If the traces differ, find the nondeterminism (table iteration, time, unseeded randomness) and remove it — do not weaken the test.
- [ ] **Step 5: Commit** — `feat(sandbox): CLI runs with reproducible traces`.

### Task 18: Reports

**Files:** Create `sandbox/report/report.lua`; Test `sandbox/tests/test_report.lua`

**Interfaces:**
- Produces `Report.write(run)` → `report.md` and `report.json` with, in order: scenario, seed, code (`worktree:<path>@<sha>` or `rev:<sha>`), world, started/finished wall time, **speed achieved** (simulated ms ÷ wall ms), whole-fleet or `--only`; faults injected with times; **INTERVENTIONS** (Task 20); jobs and outcomes, ore mined; the output of `gate_check.py` and `ack_loss.py` run with `BRIDGE_URL` pointing at the run's file server; **ASSUMPTIONS** (every `TIMINGS` entry still `unverified`, the chunk-unload model); **NOT MODELLED** (fixed list: mod-level chunk tickets beyond the model, Forge registry sync, real TPS curves, Refined Storage internals beyond `listItems` timing, `server.js` internals, rendering/players/mobs, plus anything you add); `trace.log` line count.
- If speed < 300× the report names the computer with the most `cost_ms` and the scheduler step that took the longest wall time.
- A run that ends by error or Ctrl+C still writes a report headed `INCOMPLETE` with the reason.

- [ ] **Step 1: Failing tests:** `NOT MODELLED is never empty`, `speed is reported`, `below 300x names the slowest computer`, `a crashed run still writes an INCOMPLETE report`, `gate_check output is embedded`.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): reports with speed, assumptions, not-modelled and interventions`.

### Task 19: Faults — every row of spec §7

**Files:** Create `sandbox/faults/faults.lua`, `sandbox/scenarios/{server_crash,world_restart_gps_late,rs_stall,reboot_mid_refuel,radio_loss_5,radio_loss_20}.lua`; Test `sandbox/tests/test_faults.lua`

**Interfaces:**
- Produces, on the scenario's `sim`: `server_crash(t, down_for)`, `world_restart(t, {gps_delay=})`, `server_lag(t, dur, factor)` (multiplies the server computer's `cost_ms`), `tps_drop(t, dur, tps)` (scales every `TIMINGS` action duration by `20/tps`), `radio_loss(t, dur, rate, {channel=})`, `radio_latency(t, dur, ms)`, `gps_down(t, dur, {hosts=})`, `rs_stall(t, dur, seconds)`, `rs_offline(t, dur)`, `turtle_reboot(t, node, {at_action=})` (reboot when the named turtle next starts that action, e.g. `"refuel"`, `"drop"`), `chunk_unload(t, area)`, `disk_full(t, node, bytes_free)`, `bridge_down(t, dur)`, `bridge_slow(t, dur, ms)`, `remove_item(t, node, slot)`, `event_queue_flood(t, node, n)`. Each records itself for the report.
- Each fault's test runs a minimal setup **with and without** the fault and asserts the observable difference (e.g. `rs_stall` makes the server's longest gap between deliveries ≥ the stall). A fault whose test still passes when the fault is a no-op is a failed task — prove it by temporarily stubbing the fault to a no-op and watching the test fail; note in the commit message that you did.

- [ ] **Step 1: Failing tests:** one `fault <name> changes behaviour` test per fault above.
- [ ] **Step 2–4:** FAIL, implement, PASS; then the no-op check for each.
- [ ] **Step 5:** Write the six named scenarios (spec §12). Run each once; each must produce a report.
- [ ] **Step 6: Commit** — `feat(sandbox): fault engine, every spec 7 fault tested both ways`.

### Task 20: The control API and interactive mode — every row of spec §7.1

**Files:** Create `sandbox/control/control.lua`, `sandbox/control/repl.lua`; Test `sandbox/tests/test_control.lua`

**Interfaces:**
- Produces, on the scenario's `sim` and in interactive mode, every action in spec §7.1 with those names: `pause resume step run_until set_speed snapshot restore fork teleport recover set_slot clear_slot give set_fuel equip spawn_turtle spawn_computer remove reboot shutdown start read_file write_file delete_file eval output queue get_block set_block fill load_chunks unload_chunks send_radio drop_radio storage_set storage_add storage_remove kv_get kv_set kv_clear ender_set gps_host place_gps_host watch trace_radio status`.
- `snapshot(name)` serialises the whole sandbox (world deltas, every computer's disk, inventories, positions, equipment, fuel, storage, KV, clock, every rng state, the scheduler heap) to `$SANDBOX_DATA/run/<id>/snapshots/<name>/`. **Coroutines cannot be serialised**, so `restore` reboots every computer that was on, from its restored disk — document this in the README and in the report's ASSUMPTIONS when a restore happened.
- **Interventions** (spec §7.1): every action that changes the world or a computer (`teleport recover set_slot clear_slot give set_fuel equip spawn_* remove reboot shutdown start write_file delete_file set_block fill load_chunks unload_chunks send_radio drop_radio storage_* kv_set kv_clear ender_set gps_host place_gps_host`, and `eval` whose code assigns) is appended to the run's intervention list with time and arguments. Reads, `pause`, `step`, `snapshot`, `watch`, `status` are not.
- Interactive mode: `sandbox/sim repl <scenario.lua|snapshot-dir>` starts paused and reads one command per line from stdin (`status`, `step 100`, `teleport node_138 10 64 5 north`, `eval node_138 return _self.busy`, `run_until 3600000`, `quit`), printing results as plain text. It must work when driven by a script piping commands in (`printf 'status\nquit\n' | sandbox/sim repl ...`).

- [ ] **Step 1: Failing tests:** one `control <action>` test per action (assert its effect), plus `snapshot then restore returns the world and disks exactly`, `eval runs inside the computer's environment`, `interventions are recorded and reads are not`, `repl works from piped input`.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** — `feat(sandbox): full control API, snapshots and interactive mode`.

### Task 21: Speed — meet 300×

**Files:** Modify whichever `sandbox/` modules the profile names; Create `sandbox/scenarios/six_hour_two_miners.lua`, `sandbox/tests/test_speed.lua`

**Interfaces:**
- `six_hour_two_miners.lua`: whole fleet, one two-miner job, run for 6 simulated hours.

- [ ] **Step 1: Failing test** `six simulated hours take at most 72 wall seconds` (run the scenario at `--speed max`, read `report.json`).
- [ ] **Step 2: Profile.** Report time per computer (`cost_ms` vs wall time spent resuming it) and per scheduler step type.
- [ ] **Step 3: Optimise sandbox code only** — chunk lookups, event heap, trace writing (buffered), JSON. Never skip fleet work or weaken the instruction hook below `instr_hook_every = 1000` without measuring its overhead first; if the hook is the bottleneck, raise the interval and record it in ASSUMPTIONS.
- [ ] **Step 4: Run** — PASS, or if the fleet's own computation alone exceeds the budget, stop and report the measured breakdown to the spec owner rather than cutting fidelity.
- [ ] **Step 5: Commit** — `perf(sandbox): six-hour job in under 72 seconds`.

---

## Phase 5 — The real world

### Task 22: The world importer

**Files:** Create `sandbox/tools/import_world.py`, `sandbox/tools/requirements.txt` (`nbtlib==<pinned>`); Test `sandbox/tests/test_import_world.py`

**Interfaces:**
- Produces: `python sandbox/tools/import_world.py <unpacked_world_dir> --storage <state.json> --out $SANDBOX_DATA/worlds/<date>/sim [--area x1,z1,x2,z2 ...]`.
  - Reads region files for the base (`base_loaded` areas from the server's config or `--area`), the depot and every area given; writes the World format from Task 7.
  - Copies `computercraft/computer/<id>/` disks into `out/disks/<id>/`.
  - Reads CC turtle and computer block entities: id, label, position, facing, fuel, inventory, left/right upgrades; writes `out/fleet.json` (the layout `Fleet.provision` accepts, but with `disk = existing` instead of running the installer).
  - Reads `storage` from the given `state.json` (an engineer fetched it with `curl`); writes `out/storage.json`.
  - **Makes no network call of any kind.**
- First run on the real copy: **inspect before parsing** — list the folder, find where CC stores computers and how turtle block entities are laid out in NBT, and record what you found at the top of the script as comments. Paths in spec §6 are to be verified, not assumed.

- [ ] **Step 1:** The world copy is already unpacked at `$SANDBOX_DATA/worlds/unpacked/2026-10-18_1700/world_live/` (see Global Constraints) — read it, never write into it; the importer's `--out` is `$SANDBOX_DATA/worlds/2026-10-18_1700/sim`. Never use SSH yourself; a newer copy is the user's to fetch with `G:\TurtleOS-Sandbox\get-backup.cmd`. For `--storage`: if `$SANDBOX_DATA/storage/` already holds a `state-<date>.json`, use the newest. Otherwise ask the user, in your session, for OK to read the live bridge's `/state` **once** (`curl -s http://192.168.86.35:3000/state`, a read with no side effects, run by you outside `sandbox/` — the sandbox itself still never names that host) and save it to `$SANDBOX_DATA/storage/state-<date>.json`. If the user says no, seed storage synthetically and record that in ASSUMPTIONS.
- [ ] **Step 2: Failing tests** against a small fixture you cut from the real copy (one region, one computer folder, git-ignored or synthetic if the real cut is too large): `importer finds every turtle`, `importer copies every computer disk`, `importer reads a turtle's inventory and upgrades`, `importer makes no network call` (run it with networking disabled via an env flag that makes any socket raise).
- [ ] **Step 3–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** `sandbox/tools/import_world.py sandbox/tools/requirements.txt sandbox/tests/test_import_world.py` — `feat(sandbox): world importer from a server backup`.

### Task 23: Golden fidelity from real CC files, and the first real-world run

**Files:** Create `sandbox/tests/test_golden_textutils.lua`, `sandbox/scenarios/real_world_smoke.lua`

- [ ] **Step 1: Golden test** `textutils.serialise reproduces every CC-written file byte for byte` — for each file in the imported disks that `unserialise` parses, `serialise(unserialise(text))` must equal `text`. Fix `textutils` until it does (never edit the files).
- [ ] **Step 2:** `real_world_smoke.lua` boots the imported fleet from its real disks, waits for every turtle to register with the server, then dispatches one two-miner job on an unmined area the user or W1 names. Run it. The first boot may trip `cloudstore.lua`'s empty-store warning (spec §6): if it does, record it in the report and mail W3 and W6 as a finding — do not change the store or the fleet to hide it.
- [ ] **Step 3: Commit** — `test(sandbox): golden serialisation on real disks; first real-world run`.

### Task 24: Two real incidents reproduce on the old code

**Files:** Create `sandbox/scenarios/incident_doubled_first_order.lua`, `sandbox/scenarios/incident_gps_late_restart.lua`; Test `sandbox/tests/test_incidents.lua`

**Interfaces:**
- Consumes `CodeDir.prepare("rev:<sha>")`.
- Doubled first order: code **`8dc699c^`** (1.9.108) must show a miner's first sector reported done twice in a row; **`8dc699c`** (1.9.109) must not. Signature: two consecutive `SECTOR_DONE` for the same sector by the same miner at the start of the job.
- Late-GPS world restart: code **`390cb52^`** must lose a miner (it moves on a guessed position after `world_restart(t, {gps_delay=600000})` while mid-job); **`390cb52`** (1.9.132) must log `No GPS fix -- NOT moving until one arrives` and recover.
- Old code boots on freshly provisioned disks (Task 16) on the synthetic world — today's real disks may not match old formats.

- [ ] **Step 1: Failing tests** `doubled first order on 1.9.108 and not on 1.9.109`, `late GPS loses a miner before 1.9.132 and not after`.
- [ ] **Step 2–4:** FAIL, then make the sandbox faithful enough that both pass. If an incident will not reproduce, that is a fidelity gap: find which §5 behaviour is missing; do not tune the scenario until it "happens to" fail.
- [ ] **Step 5: Commit** — `test(sandbox): two real incidents reproduce on their old code`.

### Task 25: Calibration

**Files:** Modify `sandbox/timings.lua`; Create `sandbox/tools/calibrate.py`, `docs/superpowers/specs/<date>-sandbox-calibration.md`

- [ ] **Step 1: Calibrate from existing live logs** (read-only, through `tools/` with the default bridge — ask the user before querying the live bridge; or use saved logs an engineer provides): mining throughput per miner (≈33 ores/min on a rich level, 25-ore batch lines ≈45 s apart, measured 2026-09-17), sector durations (≈2.5–3 h per 4,000-ore sector), `pushBuildMs` (11–21 ms) to set `ns_per_instr`. Update `TIMINGS`, marking each value `measured <date> from <source>` or keeping `unverified`.
- [ ] **Step 2: Forward calibration** (spec §8.2): agree an unmined zone with the user; run the job in the sandbox; the **user** runs the same job on the real server; compare duration, ore mined, sectors, messages sent, ack loss. Write the calibration doc with both sets of numbers and the differences.
- [ ] **Step 3: Commit** — `docs(sandbox): calibration against the live fleet`.

### Task 26: README, roster, hand-over

**Files:** Modify `sandbox/README.md`; Modify the shared roster memory file (`project_workstream_assignment.md`) via a row edit; mail.

- [ ] **Step 1:** `sandbox/README.md` — run a scenario in under five minutes: install check, `sandbox/sim test`, `sandbox/sim run sandbox/scenarios/smoke_two_miners.lua`, open the live view (`node sandbox/bridge/fileserver.js <run_dir> 3101` then `http://127.0.0.1:3101/`), use `repl`, how to close a card on sandbox evidence (attach the report; card moves to **"Done — not yet seen on the real server"**; never on a run with interventions unless the intervention is the test).
- [ ] **Step 2:** Add a roster row: `Sandbox — sandbox/ — the building instance`.
- [ ] **Step 3:** Mail every engineer (`--to W1,W3,W5,W6`, `--kind info`) that the sandbox exists, with the README path.
- [ ] **Step 4: Commit** — `docs(sandbox): README and hand-over`.

---

**Done when** spec §15's seven items hold. The board column "Done — not yet seen on the real server" is created by the spec owner, not by this plan.
