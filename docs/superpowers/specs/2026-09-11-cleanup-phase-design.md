# Turtle OS — the cleanup phase

- **Owner:** Spec owner / head engineer
- **Date:** 2026-09-11
- **Status:** Approved by the user, section by section, 2026-09-11
- **Applies to:** every engineer. **Overrides the roadmap order in
  `2026-08-18-system-integration-design.md` §16 until the exit gate in §7 passes.**

---

## 1. Why

The user's direction: *focus on what is here, feature- and architecture-wise, and
get it near perfect before adding anything else.*

The system works — a complete mining job ran on 2026-09-09 — but it carries dead
code, oversized programs, 17 open cards, one unexplained fleet-wide fault, two
design flaws deferred since June, and paperwork that no longer matches the
system. Every new feature built on that inherits all of it.

## 2. The three decisions

| Question | Decision |
|---|---|
| How deep? | **Tidy and fix first; decide on redesign with evidence.** The two known design flaws (§8) are not touched in this phase. They are measured during it. |
| When is it finished? | **The board is clear, then one unbroken 48-hour run passes** (§7). |
| How is it run? | **In waves, safest first** — remove (§4), repair (§5), slim (§6) — with one fleet update in flight at a time. |

## 3. The freeze

### 3.1 The rule — remove, repair, or measure

During this phase a change is allowed only if it:

- **Removes** something — dead code, stale files, stale paperwork; or
- **Repairs** something *shown* broken — by a measurement or a log line, not a
  hunch; or
- **Measures** something the §7 gate needs.

Everything else waits, however good. If a change cannot be described by one of
those three words, it is frozen.

### 3.2 Frozen until the exit gate passes

- The planner (W2), the builder (W4), the road generator and `.litematic` parser (W5)
- Mod probes — Turtlematic, Peripheralium Hub, Recipe Registry
- The §11.7 stock-and-craft interface (`STOCK_QUERY` / `CRAFT_REQUEST` / `CRAFT_STATUS`)
- The §15 hooks — `owner`, `priority`, `capabilities[]`, placement sets
- Anything from the scaling-to-150 spec
- New turtle types; **retiring SUPPORT** (design-flaw-2 territory — §8)
- Turtle logs to KV; `mineZones` deltas (tidy, but nothing measured says they hurt)

### 3.3 Work already in flight

| Work | Continues? | Why |
|---|---|---|
| Move the RS storage poll off the dispatch server (W6) | **Yes** | Measured cause of every server stall under load |
| W5's `POST /storage` route for it | **Yes** | Part of the same move |
| Stop the zone file regrowing (W6) | **Yes** | It filled the server disk on 2026-09-09 |
| Payload trimming not tied to a measured fault | **Waits** | — |

### 3.4 Staffing

W2 and W4 have nothing to build. They take cleanup work (§4) rather than sit
idle. The spec's ceiling of **two to three engineers changing code at once** still
applies — one working tree, no branch isolation.

## 4. Wave 1 — remove dead weight

No fleet behaviour changes.

### 4.1 Code and files

| What | Action | Owner |
|---|---|---|
| `android_base.lua`, `android_main.lua`, `android_update.lua` | Drop from `install.lua`, `updater.lua`, and `server.js`'s `/lua/` file list. **Leave the files in git history** — the builder work may want the API reference | W4; W5 for `server.js` |
| `stress_test.lua` | Stop shipping it to the server (`updater.lua` file list) | W3 |
| `warehouse_test.lua` | Stop installing it on the warehouse computer; move to `tests/inworld/` | W6 |
| `test_turtle.lua` | Move to `tests/inworld/` — nothing references it | W3 |
| Stale files already on in-game disks | Removed **by hand**, one-line commands from the spec owner. **No automatic deletion** — a cleanup routine on a CC computer that picks the wrong file destroys job or zone state | User |
| `dash.bundle`, `.superpowers/brainstorm/` | Delete the bundle (already applied); gitignore the brainstorm scraps | Spec owner |

**Do not remove `gps_host.lua`.** Nothing in the repo references it, and it is
not dead: it is hand-installed as `startup.lua` on the four GPS host computers at
Y=255 that every turtle locates itself by. The spec owner adds a header comment
saying so.

### 4.2 Paperwork

| What | Action | Owner |
|---|---|---|
| 82 files in `docs/superpowers/specs/` | Move every engineer-to-engineer memo dated before 2026-09-01 into `docs/superpowers/archive/` with `git mv`; later memos follow once the card they concern is *Done*, so no live thread is moved out from under its engineers. **Stay:** the integration spec, the scaling spec, this document, `2026-09-09-outstanding-must-do.md`, `2026-09-08-reading-the-fleet-log.md`, and every design doc (`*-design.md`) | W2 |
| Integration spec §16 | Rewrite around this phase; point here | Spec owner |
| Shared memory notes | Correct or delete stale ones — `project_overview.md` still says version 1.3.5, and the Android notes describe a class that no longer exists. Every engineer reads these at startup | Spec owner |

## 5. Wave 2 — repair the open cards

### 5.1 One fleet update at a time

**Only one update to the in-game computers may be in flight.** It must run
through **at least one complete mining job with no new fault** — no job ends
FAILED and no kind of error line appears that was not there before — before the
next goes out. When something breaks, exactly one change is suspect.

- **Exempt:** bridge and dashboard changes (`server.js`, `public/`). They deploy
  on the server PC, not through the fleet updater, so W5 works in parallel.
- **Waves overlap in development, not in release.** Engineers may build ahead;
  releases leave the queue in order.
- **Merge order is release order**, because a deploy ships `master`. A commit
  that changes fleet code — including `install.lua` and `updater.lua` — lands on
  `master` only when the release before it has passed. Build ahead on a local
  branch. Docs, tests, `server.js` and `public/` are not in the queue.
- **Deploying is the user's action.** No engineer triggers `UPDATE_ALL` or
  `/self-update`.

**Release order — amended 2026-09-11 on W3's evidence**
(`2026-09-11-spec-owner-to-W3-release-order-and-crash-sign-off.md`):

| Release | Contents |
|---|---|
| R1 | `master` as merged — 1.9.98 (`fd29d34`) and 1.9.99 (`459a2bf`). Two changes, accepted once: different areas, separate signals, both measured faults |
| R2 | Wave 1 removals only |
| R3 | Bridge push timeout witness — **measure**; gate check 7 depends on it |
| R4 onward | The highest-priority **ready** card in §5.2 order. An unbuilt card does not hold the queue |

### 5.2 Order

| # | Card | Owner | Why here |
|---|---|---|---|
| — | **Fleet-wide disconnect clusters** | **W1 investigates; W3 fixes** | The largest threat to §7. Runs as an investigation throughout; its fix jumps the queue. W1 found it and holds the log tooling, and W1's feature work is frozen |
| 1 | Move the RS storage poll off the dispatch server | W6 | Measured cause of every server stall; removing it also cleans the signal for the investigation above |
| 2 | Stop the zone file regrowing on the server disk | W6 | Filled the disk on 2026-09-09 |
| 3 | Warn about low server disk while there is still room | W3 | So the next one is a warning, not a crisis |
| 4 | Stop the server re-sending a stale sector order after a reconnect | W3 | Half of why node_139 mined a quarter of its share |
| 5 | Crash handlers flush their last log lines before rebooting — **and delivery gets a crash handler at all**: today a control-loop crash leaves it at the shell prompt | W1 (`ore_turtle.lua`); W3 (`delivery_turtle.lua`, `support_turtle.lua` — **signed off 2026-09-11**) | §7 requires zero missing log lines; a crash guarantees some today |
| 6 | Let the install check see a module the warehouse loads optionally | W3 | Stops a false "all installed" |
| 7 | **Bridge push timeouts** — ~83/day while the bridge answers in 1–3 ms | W3 | A lost-event fault of its own, never carded. **New card** |
| Any | Sort the log viewer by time; reconcile the dashboard service file | W5 | Dashboard side — not in the fleet queue |
| Any | Firewall rule, systemd install, **rotate the RCON password** | Server PC engineer, via the user | Security waits for nothing |

**Leaves the board:** *Warehouse and admin computers send no logs* — the
warehouse half is built and sits in Needs measuring; the admin half waits until
after this phase, because the admin screen cannot fail the fleet.
*Retire the Android file from the installer* moves to Wave 1.

### 5.3 Invariant H during this phase

A repair to `delivery_turtle.lua` or `support_turtle.lua` is allowed when **the
card is on the board and the spec owner has signed it off in the card body**
(`Signed off: spec owner, <date>`). Scope is the card's text and nothing else.
This replaces the memo-per-change ruling for this phase only. H is otherwise
unchanged and reverts in full when §7 passes.

### 5.4 Needs measuring

Every card in *Needs measuring* must reach *Done* — with its measurement in the
card body — before a §7 run may start.

## 6. Wave 3 — slim the big programs

| Program | Size | Owner |
|---|---|---|
| `central_server.lua` | 235 KB — on a 1 MB disk shared with job and zone state | W3 |
| `turtle_base.lua` | 126 KB — on every turtle | W3 |
| `ore_turtle.lua` | 118 KB — ~350 KB of program per miner with its modules | W1 |
| `public/index.html` | 160 KB — not disk-bound, but the hardest file to navigate | W5 |

**Slimming means** removing code nothing calls, fallback paths kept "just in
case", and helpers duplicated elsewhere. It does not mean making code terser.

**Rules:**

1. **Behaviour identical.** A slimming release contains removals only — no fixes,
   no improvements.
2. **Every automated test stays green**, including the mutation harnesses where
   they exist.
3. **Each slimming release takes its turn** in the §5.1 queue.
4. **A program is slimmed only after its Wave 2 cards are closed** — slimming a
   file while someone repairs it is a collision.

**Splitting** needs a demonstrated collision between owners. The only one today
is the RS poll inside W3's server, and Wave 2 card 1 removes it. No other split
is planned.

**Reported as** bytes removed per program, with tests green. There is no size
target.

## 7. The exit gate — one unbroken 48-hour run

### 7.1 Preconditions

- Every Wave 2 card is *Done*, or has left the board under §5.2.
- Every *Needs measuring* card is *Done* (§5.4).
- Wave 3 is complete.

### 7.2 A pass requires all of these, over one continuous 48 hours

| # | Check | Measured by |
|---|---|---|
| 1 | **Real load.** At least one mining job in progress for **at least 36 of the 48 hours**, and **zero jobs end FAILED** | Job records. An idle fleet cannot fail, so it cannot pass |
| 2 | **No server restart or crash** | `bootId` unchanged for the full window; `crash.log` unchanged |
| 3 | **No group disconnect** — never **3 or more distinct turtles** logging `Server unreachable` within **30 seconds** | Fleet log |
| 4 | **Every single-turtle disconnect explained** — the turtle's witness verdict names a cause (radio off, comms gap, loop paused). **"Radio on and loop turning" is an unexplained lost message and fails the run** | Witness lines, 1.9.96+ |
| 5 | **No missing log lines** | Log audit `verdict=clean` across the full window |
| 6 | **Server disk never below 300 KB free** | `diskFree`, with Wave 2 card 3's warning |
| 7 | **No unexplained bridge push timeouts** | The server's push-timeout log lines |

### 7.3 Rules of the run

- **Nothing deploys to the fleet during a run.** An update restarts the clock.
- **Any failed check becomes a card**, is repaired under §5, and the 48 hours
  restart from zero.
- **The report is written by W1**, and must state its evidence counts — jobs,
  turtles, hours of log audited, lines audited — so that an empty log cannot read
  as a clean one. The spec owner checks it; the user gets it in plain language.

## 8. The redesign decision

Two design flaws are deferred, not forgotten:

- **Flaw 1 — dual state tracking.** The server keeps its own copy of every
  turtle's state; after a crash the copies diverge, and ~250 lines exist to
  reconcile them (`checkGhosts`, `reSendJob`, `reSendSector`, re-registration).
- **Flaw 2 — two state machines over radio.** Miner and support each decide when
  and how to come home, over four return paths, and can disagree about phase.

**Across every run, failed ones included, count each flaw's footprint:**

- Flaw 1: re-registrations that restore mid-job state, `checkGhosts` hits,
  `reSendJob` and `reSendSector` calls.
- Flaw 2: failed or solo returns, support timeouts, phase-stuck detections.

If a counter has no log line today, adding one is allowed as **measure** (§3.1).

**Decision rule:**

- **A run fails because of a flaw** → redesign that flaw, and only that one. It
  gets its own cleanup round and its own §7 run afterwards.
- **A run passes** → both flaws stay deferred, the freeze lifts, and the roadmap
  resumes at Stage 1 minus whatever this phase already delivered.

The spec owner brings the evidence; **the user decides.**

## 9. How this is tracked

- **The board** (`https://github.com/users/JinxOG/projects/1`) is the at-a-glance
  view; every card has an owner and a column. Engineers move their own cards in
  the same session their work changes.
- **The must-do list** stays the evidence record. If the two disagree, the list
  is right and the card is fixed.
- **Unassigned cards** are held by the spec owner until the user assigns them.
- **The roster** is `project_workstream_assignment.md` in shared memory, written
  as a roster — never as "this instance is Wx".
