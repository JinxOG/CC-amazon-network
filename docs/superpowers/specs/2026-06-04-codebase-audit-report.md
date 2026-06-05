# CC Amazon Network — Codebase Audit Report
Date: 2026-06-04
Version audited: v1.3.37

Severity tags:
- [CRITICAL] — will crash or corrupt state at runtime
- [BUG]      — incorrect behavior, won't crash
- [PROTOCOL] — message sent but never handled, or handler with no sender
- [OVERSIGHT]— missing edge case, silent failure
- [PERF]     — blocking call, unbounded growth, unnecessary work
- [OPT]      — minor non-breaking improvement

---

## Layer 1: Turtle Runtime

### protocol.lua

- [BUG] `proto.send` — Hardcodes `proto.CH_SERVER` (1) as the reply channel for every transmit, regardless of the actual sender. This is correct for turtle→server traffic but wrong for server→turtle (CH_BROADCAST/CH_PRIVATE), warehouse (CH_WAREHOUSE), and turtle↔turtle (CH_LOCAL) messages: their `replyChannel` metadata falsely advertises channel 1. Currently latent because `proto.receive` discards the reply channel (`repCh` is captured but never used), so no code replies on it — but any future code that relies on `replyChannel` to route a response would send it to the server instead of the real sender. Should pass the sender's own listen channel as the reply channel.
- [OVERSIGHT] `proto.send` — Calls `textutils.serialise(msg)` on every send, while `proto.receive` accepts BOTH a raw table (`type(raw) == "table"`) and a serialised string. The send path never transmits a raw table, so the table branch in receive is dead unless some other (non-proto) sender transmits raw tables. Asymmetry is harmless but worth noting; serialise also throws on payloads containing functions/recursive tables, which would crash the sender rather than fail gracefully.
- [OVERSIGHT] `proto.receive` — `textutils.unserialise(raw)` returns `nil` on malformed input; the code guards with `local ok = msg ~= nil` and skips, so a corrupt/garbage modem message is silently dropped with no log. Acceptable, but failures are invisible for debugging.
- [OPT] `proto.receive` timer event — The destructure `local event, side, ch, repCh, raw = os.pullEvent()` reuses modem-message field names for the timer case, where the 2nd return is actually the timer ID. The check `event == "timer" and side == timer` is CORRECT (for a timer event `side` holds the timer ID), but the variable name `side` is misleading and invites future bugs. No functional issue. Naming it `p1`/`arg2` or handling timer with its own pull would be clearer.
- [OVERSIGHT] `proto.MSG` orphan-from-name scan — Most types map cleanly to a sender/handler. Two stand out by name: `ITEM_REQUEST`/`ITEM_READY` (older warehouse handshake) appear superseded by the newer `DELIVERY_ARRIVED`/`CHESTS_READY`/`ITEMS_READY`/`BATCH_DONE`/`ITEMS_DONE` handshake added below — possible dead/duplicate protocol pair to verify against actual senders/handlers. `TURTLE_QUERY`/`TURTLE_INFO` are documented as used by support turtles but the newer CH_LOCAL follow signals (`POSITION_UPDATE`, `ASCENDING`, `DESCENDED`) may make the server-mediated query path redundant. Flagged for cross-file confirmation in later tasks (handler/sender presence not verified here).
- No issue with the timer-ID check (Check 1), `proto.decode` MSG lookup (Check 4 — every `proto.MSG` entry has key == value, so `proto.MSG[msg.type]` validation succeeds for all valid types), terminate handling (Check 5 — `proto.receive` uses `os.pullEvent()`, the filtering form that re-throws `terminate` as an error, so Ctrl-T shutdown is NOT swallowed; `os.pullEventRaw` would have been the bug), or channel separation (Check 7 — channel is an explicit caller argument to `proto.send`, so CH_LOCAL messages are not auto-routed to CH_SERVER; only the reply-channel metadata is wrong, per the [BUG] above).

### waypoints.lua

- [OVERSIGHT] Hole coordinate literals duplicated across definitions — The X/Z literals `143`/`-2813` appear in `DISPATCH_HOLE`, `DISPATCH_STAGING` (x only), and `WORLD_EXIT`; `228`/`-2782` appear in both `ARRIVALS_HOLE` and `WORLD_ENTRY`. `WORLD_EXIT`/`WORLD_ENTRY` are by definition "below the dispatch/arrivals hole," yet they restate the raw coords instead of referencing `W.DISPATCH_HOLE.x/.z` and `W.ARRIVALS_HOLE.x/.z`. A single layout move of either hole requires editing the coordinate in two-to-three places, and forgetting one would put the underground entry/exit out of vertical alignment with its hole (turtle ascends/descends into a wall). Derive `WORLD_EXIT`/`WORLD_ENTRY` from the hole tables (only Y differs).
- [OVERSIGHT] Route builders deref `dock` fields with no internal nil guard — `internalReturnRouteFrom`, `returnAisleZ`, `dockFacing`, `departureRoute`, `supportDepartureRoute`, `returnRoute`, and `aisleZ` all access `dock.z` / `dock.x` / `dock.junction.x` without checking `dock` (or its fields) for nil inside the helper itself. All current callers are in `turtle_base.lua` and each guards at the call site with `if not _self.dock then return true end`, so no unguarded call path exists today — this is latent. Any future caller added without that guard would hit "attempt to index a nil value" with no clear error message pointing back to the missing dock assignment.

Checks that passed (no issue): single-axis waypoint rule in `internalReturnRouteFrom` (all 5 steps change exactly one of X/Z relative to the prior step, starting from `fromX,fromZ`); the `internalReturnRoute` compatibility wrapper (calls `internalReturnRouteFrom(dock, dock.junction.x, W.RED_Z)` — argument order matches the spec; its only quirk is a harmless duplicate first waypoint when `fromX==junction.x` and `fromZ==RED_Z`); `returnAisleZ` does not index by `dock.row` at all (it derives from `dock.z`), so an out-of-range/nil `row` is irrelevant to it; `dockFacing` returns only `2` or `0`, both valid {0,1,2,3}; and `CFG.FLOOR_Y` is referenced via the config constant everywhere inside this file (the raw `67` literal lives in `turtle_base.lua:622`, out of scope for this task).

### turtle_base.lua

Scope note: Checks 2 and 10 (`pushToBridge` / HTTP body read order) and Check 8 (`base.waitForMessage`) target functions that **do not exist in `turtle_base.lua`**. The bridge push and its `resp.readAll()`/`resp.close()` ordering live in `server.js`/`central_server.lua` (server side); the receive-with-timeout primitive lives in `protocol.lua` (`proto.receive`). They are flagged here as N/A for this file and deferred to the server/protocol audits.

- [OVERSIGHT] Internal GPS resync ignores failure silently — `applyMove` (line 172-174) calls `gpsSync()` every `GPS_RESYNC_INTERVAL` (50) moves but discards the return value. When `gps.locate()` returns nil (no satellite signal), `gpsSync` returns false and leaves `_self.pos` untouched (line 84-88), so the turtle keeps dead-reckoning with **no warning logged**. The same silent-fail pattern repeats at every bare `gpsSync()` call: `depart` (432), `returnToDock` (557, 575), `returnToDockInternal` (602, 618), and `base.init` (1063). The public `base.gpsSync` (line 92) does log a warning, but none of the internal callers use it. Not a crash (good — no nil index), but drift accumulates invisibly. Recommend logging a WARN on internal resync failure, at least on the precision-critical resyncs before bay navigation.

- [OVERSIGHT] `bypassForward` floor gate uses raw literal `66` instead of `CFG.FLOOR_Y` — Line 303 `if _self.pos.y < 66 then` guards the vertical (dig) bypass so the turtle never digs inside the surface depot. But the actual depot floor is `CFG.FLOOR_Y = 67` (waypoints.lua:11). A turtle standing on the floor is at y=67, so `67 < 66` is false → vertical bypass correctly skipped at the floor. However the threshold is off-by-one in intent: the comment says "Inside the surface depot (y >= 66) never dig", yet only y>=66 blocks it, meaning a turtle at **y=66** (one block below floor, e.g. mid-descent into a hole) is also treated as "depot" and refused a vertical bypass, while everything strictly below 66 (underground travel at y=60) is allowed. The threshold happens to work for the two real cases (floor=67 blocked, underground=60 allowed) but it is a hardcoded magic number that should be `_self.pos.y < W.DISPATCH_HOLE.y` or `< CFG.FLOOR_Y`. See also the duplicate-literal finding below.

- [OVERSIGHT] Hardcoded floor-Y literals `66`/`67` scattered instead of `CFG.FLOOR_Y` — Raw Y constants appear at: line 303 (`66`, bypass gate), 515 (`local FLOOR_Y = 67`, returnToDock), 622 (`move.to(..., 67, ...)`, returnToDockInternal drift correction), 1065 (`p.y >= 66`, init inside-building test), and 1133 (`_self.pos.y >= 67`, RECALL inside-building test). `waypoints.lua` exports `W.FLOOR_Y`/`CFG.FLOOR_Y = 67`, and `returnToDock` even defines its own local `FLOOR_Y = 67` rather than importing it. The init test uses 66 while the RECALL test uses 67 for the *same* "inside building" predicate (lines 1065 vs 1133) — an inconsistency: a turtle at exactly y=66 is "inside" for init homing but "outside" for RECALL, so RECALL would route it via the full underground `returnToDock` instead of the internal taxiway. Any floor-height change requires editing five places and they currently disagree.

- [OVERSIGHT] Building-bounds box duplicated and divergent — The "inside building" bounding box `x in [143,228], z in [-2817,-2782]` is hardcoded twice (init lines 1066-1067, RECALL lines 1134-1135) with the only difference being the Y test (66 vs 67, above). These magic coordinates duplicate `W.DISPATCH_HOLE`/`W.ARRIVALS_HOLE` extents from waypoints and would silently break if the depot footprint moves. Extract a single `W.isInsideBuilding(pos)` helper.

- [BUG] `returnToDockInternal` route failure leaves status stuck at RETURNING — Lines 614-616: if `move.followRoute(route)` fails partway (e.g. permanently blocked aisle), the function returns `false, "internal return failed: ..."` having already set `proto.STATUS.RETURNING` at line 609. Nothing resets the status or notifies the server, so the turtle reports RETURNING indefinitely while physically stuck mid-aisle. Same shape in `returnToDock` (lines 531, 572) and `depart` (443, 482) — all return false on route failure with status left mid-transition and no `sendFailed`/recovery. The caller (delivery/support job handler) must handle the false return; if it doesn't, the turtle is wedged. Flagged for cross-check against the role handlers.

- [OVERSIGHT] No fuel reserve sized for the return trip — `fuel.isCritical()` triggers at a flat `FUEL_CRITICAL = 200` (line 14, 645). There is no calculation reserving enough fuel to reach the dock from the current position; 200 is a fixed floor regardless of how far away the turtle is. If a job takes the turtle far enough that it drops below 200 only after passing the point of no return, `ensureFuel` (859) will deploy the entangled chest mid-journey to recover — which works *only* if the chest has coal. If the chest is empty, `ensureFuel` enters an unbounded `while fuel.isCritical()` loop (line 860) that blocks the turtle forever (sending ERROR heartbeats every ~30s), never aborting the job or returning. Mid-job fuel exhaustion is therefore a soft-hang, not a clean failure. Acceptable as a deliberate "wait for human to refill chest" design, but worth confirming that's intended; otherwise it's an [OVERSIGHT] (no give-up path).

- [OVERSIGHT] `ensureFuel` infinite block on empty chest — (detail of the above) Lines 860-881: the outer `while fuel.isCritical()` only exits when fuel is no longer critical. If `refuelFromChest` returns false (empty/unreachable chest), the inner loop sleeps 30s sending heartbeats then re-loops the outer `while` forever. There is no max-retry / escalate-and-park path. Turtle stays "alive" to the server (heartbeats with STATUS.ERROR) but never progresses.

- [OVERSIGHT] `requestItems` uses the legacy `ITEM_REQUEST`/`ITEM_READY` pair — Lines 1001-1012 still send `proto.MSG.ITEM_REQUEST` and await `proto.MSG.ITEM_READY`, the older warehouse handshake flagged as possibly superseded in the protocol.lua audit. Confirm whether any current job handler calls `base.requestItems`; if the live path uses the newer `DELIVERY_ARRIVED`/`CHESTS_READY`/`ITEMS_READY` handshake, this is dead code. [PROTOCOL] pending sender/handler confirmation.

- [OVERSIGHT] `_self.facing` persists across jobs and is never re-validated by GPS — Module-level `_self` (lines 24-39) holds `pos`, `facing`, `status`, `jobId`, `partnerId`, `busy`, `recalled`, `moveCount` for the whole process lifetime. `gpsSync` corrects `pos` but **never re-derives `facing`** (only the boot-time `detectFacing` does, line 104). If a chunk-unload/reload or a physical bump rotates the turtle without going through `move.turnLeft/Right`, `facing` silently desyncs from reality and every subsequent `applyMove` mistracks position until the next 50-move GPS resync masks it (position only, not heading). `move.to`'s per-step facing recalc partially self-heals X/Z drift, but a wrong heading still produces one wrong move per axis before correction. Re-running `detectFacing` after a GPS resync, or on job start, would harden this.

- Checks that passed (no issue):
  - Check 4 (move.to facing recalc) — CONFIRMED COMPLETE. The X phase (lines 395-399) and Z phase (lines 401-405) each call `move.face(...)` *inside* the while loop before every `move.forward()`, so a bypass overshoot self-corrects. The Y phase (lines 384-391) uses `move.up()/move.down()` which need no facing, so the "recalc each step" rule is N/A there — correct. The v1.3.31 fix is fully present.
  - Check 3a (bypass position tracking) — `bypassForward`'s `tryStrafe` and `tryVertical` call `applyMove(...)` after every successful `turtle.forward/up/down`, and `tryMove` deliberately does NOT call `applyMove` again when `bypassForward` returns true (line 334-336 returns immediately). Position accounting is consistent. Turns use `move.turnLeft/Right` which update `_self.facing`, and each strafe/vertical path restores its original facing via the paired `turnRtn()`/return-move before returning, so facing is restored (Check 3b OK).
  - Check 6a (returnToDockInternal nil dock) — guarded: line 600 `if not _self.dock then return true end`. Also handles already-at-dock (604-608).
  - Terminate/parallel structure — `base.run` uses `os.pullEvent()` (filtering form) so Ctrl-T terminate is honored; control loop and job runner share events via `parallel.waitForAny` correctly; RECALL on a busy turtle sets `_self.recalled` and lets the job coroutine do its own navigation rather than fighting over movement (lines 1121-1130) — correct separation.
  - `sendComplete`/`sendFailed` reset `status/jobId/partnerId/busy` (lines 976-994), so per-job state does not leak forward on the normal and failure paths; `_self.recalled` is cleared in `jobRunner` after every job (line 1179). `bypassAttempted`/`turtleWaits` are locals inside `tryMove`, no leak.

### delivery_turtle.lua

*(findings go here)*

### support_turtle.lua

*(findings go here)*

---

## Layer 2: Server Layer

### central_server.lua

*(findings go here)*

### warehouse.lua

*(findings go here)*

---

## Layer 3: Dashboard / Bridge

### server.js

*(findings go here)*

### public/index.html

*(findings go here)*

---

## Summary Table

| # | Severity | File | Description |
|---|----------|------|-------------|
